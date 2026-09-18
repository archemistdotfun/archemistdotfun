// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { TransientStateLibrary } from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import { FeeRecipient } from "./ArchemistV4Types.sol";
import { IArchemistHolderRewards } from "./interfaces/IArchemistHolderRewards.sol";
import { ArchemistUpgradeable } from "./upgradeability/ArchemistUpgradeable.sol";

interface IERC20Locker {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IArchemistV4LauncherView {
    function POOL_MANAGER() external view returns (IPoolManager);
    function TREASURY() external view returns (address);
    function BUYBACK_VAULT() external view returns (address);
    function HOLDER_REWARDS() external view returns (address);
    /// @dev "Was this hook ever registered", not "may a new launch pick it" - see `onlyHook`.
    function isKnownHook(address hook) external view returns (bool);
}

/// @notice Holds every launch's LP position, permanently, and is the single place fees are credited and
/// claimed. The position is never removable: there is no function on this contract, reachable by anyone
/// including the owner, that decreases `positionInfo.liquidity` or transfers the position out. That is
/// the whole promise of the contract, and `test_lockerHasNoWithdrawalPathForLiquidity` enumerates the
/// ABI to prove it stays true.
///
/// **Two properties of this contract.**
///
/// *Hooks are plural.* `onlyHook` used to compare `msg.sender` against the launcher's single `HOOK()`.
/// It now asks `launcher.isKnownHook(msg.sender)` - "was this hook ever registered" - deliberately NOT
/// "is it currently enabled". A pool's hook is part of its `PoolKey` and so of its identity; disabling a
/// hook stops new launches picking it and must never stop an existing pool's fees being recorded, or
/// those pools would silently stop paying their creators. What keeps that safe is unchanged and is the
/// only boundary that matters here: `recordHookFee` verifies the ERC-6909 claim balance actually backs
/// the fee being credited, so a hook that calls in without minting gets `UnexpectedDelta` and nothing else.
///
/// **The cost of that, stated rather than discovered.** `onlyHook` now reads launcher *proxy* storage on
/// every fee-bearing swap, so a launcher upgrade that broke `isKnownHook` would revert trading on every
/// pool at once - the blast radius of a launcher upgrade now reaches the swap path, which it did not
/// when the hook address was an immutable. This is accepted, not overlooked, and the reasons are:
/// upgrades are timelocked 48 hours and public throughout; `test_namespaceStructsAreAppendOnly` refuses
/// any implementation that would move this field; and the alternative - mirroring known hooks into this
/// contract at `registerHook` time - trades one failure mode for a worse one, a silent desync between
/// two copies of the same set, where fees stop being creditable for a hook everybody believes is
/// registered. One source of truth that can be upgraded carefully beats two that can disagree. Worth
/// revisiting if the launcher ever starts being upgraded often; today it is not.
///
/// *This contract is upgradeable* (UUPS, owner = a 48-hour TimelockController). That is strictly more
/// power than any single administrative function - an upgrade can do anything - and the honest
/// framing is that it trades "trustless" for "transparent and time-delayed": every upgrade is a public
/// timelock operation, visible on chain at least 48 hours before it can execute. See
/// `docs/UPGRADE_POLICY.md` for the published policy.
contract ArchemistV4Locker is ArchemistUpgradeable, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int128;
    using SafeCast for uint128;

    uint16 public constant BPS = 10_000;
    /// @dev The 12.5% "ecosystem" slice of every fee. Which of these two it is depends only on the
    /// direction of the swap that produced it: a BUY funds the ARCH buyback, a SELL funds rewards for
    /// the holders of the token being sold. Same size either way - the direction picks the destination,
    /// never the amount - so the creator's and the protocol's shares are identical in both directions.
    uint16 public constant BUYBACK_FEE_SHARE_BPS = 1_250;
    uint16 public constant HOLDER_FEE_SHARE_BPS = 1_250;
    // Hard bounds mirrored from ArchemistPairRegistry.CREATOR_SHARE_MIN/MAX. The launcher already
    // checks creatorShareBps against the pair's own [minCreatorBps, maxCreatorBps] band; this is a
    // second, independent check so the locker never depends on the registry having validated correctly.
    uint16 public constant CREATOR_SHARE_MIN_BPS = 5_000;
    uint16 public constant CREATOR_SHARE_MAX_BPS = 8_000;
    uint8 public constant MAX_RECIPIENTS = 4;
    uint256 public constant MAX_TOKEN_DUST = 1e12;
    bytes32 private constant POSITION_SALT = keccak256("ARCHEMIST_V4_LOCKED_POSITION");

    enum CallbackAction {
        None,
        Seed,
        Collect,
        Redeem
    }

    struct PositionInfo {
        address token;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint16 creatorShareBps;
        bool exists;
    }

    /// @custom:storage-location erc7201:archemist.storage.Locker
    struct LockerStorage {
        address launcher;
        mapping(PoolId => PositionInfo) positionInfo;
        mapping(PoolId => PoolKey) poolKey;
        mapping(PoolId => FeeRecipient[]) recipients;
        mapping(address => mapping(address => uint256)) claimable;
        mapping(address => uint256) totalLiability;
        mapping(address => mapping(address => uint256)) erc6909Claimable;
        mapping(address => uint256) totalClaimLiability;
        mapping(PoolId => mapping(uint256 => address)) pendingRecipientAdmin;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("archemist.storage.Locker")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LOCKER_STORAGE = 0x5c5807cf979554ded7e2333bb96537bdaaba8e3c42b08ea68baed3700da5a100;

    /// @dev Per-call scratch for whichever unlock frame is currently open. Transient (EIP-1153): cleared
    /// automatically at the end of the transaction, occupies no storage slot, and therefore cannot
    /// collide with the namespace struct above no matter how it grows.
    bytes32 private constant CB_ACTION_SLOT = keccak256("archemist.transient.Locker.action");
    bytes32 private constant CB_POOL_ID_SLOT = keccak256("archemist.transient.Locker.poolId");
    bytes32 private constant CB_CURRENCY_SLOT = keccak256("archemist.transient.Locker.currency");
    bytes32 private constant CB_AMOUNT_SLOT = keccak256("archemist.transient.Locker.amount");

    IPoolManager public immutable POOL_MANAGER;
    uint256 public immutable EXPECTED_CHAIN_ID;

    event PositionSeeded(
        PoolId indexed poolId,
        address indexed token,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 tokenUsed
    );
    event FeesCollected(PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 protocol0, uint256 protocol1);
    event HookFeeRecorded(PoolId indexed poolId, address indexed asset, uint256 amount, bool isBuy);
    /// @param acceptedByRewards False when the token had no eligible supply to distribute to and the
    ///        slice was routed to the treasury instead.
    event HolderRewardCredited(
        PoolId indexed poolId, address indexed token, address indexed asset, uint256 amount, bool acceptedByRewards
    );
    event FeesClaimed(address indexed beneficiary, address indexed asset, address indexed to, uint256 amount);
    event RecipientPayoutUpdated(PoolId indexed poolId, uint256 indexed index, address oldPayout, address newPayout);
    event RecipientAdminTransferStarted(
        PoolId indexed poolId, uint256 indexed index, address oldAdmin, address newAdmin
    );
    event RecipientAdminTransferred(PoolId indexed poolId, uint256 indexed index, address oldAdmin, address newAdmin);

    error InvalidAddress();
    error InvalidChain(uint256 actual, uint256 expected);
    error InvalidInfrastructure();
    error InvalidPool();
    error InvalidPosition();
    error InvalidFeeSplit();
    error AlreadyConfigured();
    error NotAuthorized();
    error NoClaimableBalance();
    error TransferFailed();
    error UnexpectedDelta();

    modifier onlyLauncher() {
        if (msg.sender != _s().launcher) revert NotAuthorized();
        _;
    }

    /// @dev "Ever registered", not "currently enabled" - see the contract note. A pool bound to a
    /// since-disabled hook must keep recording its fees forever.
    modifier onlyHook() {
        if (!IArchemistV4LauncherView(_s().launcher).isKnownHook(msg.sender)) revert NotAuthorized();
        _;
    }

    constructor(IPoolManager poolManager_, uint256 expectedChainId_) {
        POOL_MANAGER = poolManager_;
        EXPECTED_CHAIN_ID = expectedChainId_;
    }

    function initialize(address owner_, address launcher_) external initializer {
        if (block.chainid != EXPECTED_CHAIN_ID) revert InvalidChain(block.chainid, EXPECTED_CHAIN_ID);
        if (address(POOL_MANAGER) == address(0) || launcher_ == address(0)) revert InvalidAddress();
        if (address(POOL_MANAGER).code.length == 0 || launcher_.code.length == 0) revert InvalidInfrastructure();
        __ArchemistUpgradeable_init(owner_);
        _s().launcher = launcher_;
    }

    function LAUNCHER() public view returns (address) {
        return _s().launcher;
    }

    function positionInfo(PoolId poolId) external view returns (PositionInfo memory) {
        return _s().positionInfo[poolId];
    }

    function claimable(address beneficiary, address asset) external view returns (uint256) {
        return _s().claimable[beneficiary][asset];
    }

    function totalLiability(address asset) external view returns (uint256) {
        return _s().totalLiability[asset];
    }

    function erc6909Claimable(address beneficiary, address asset) external view returns (uint256) {
        return _s().erc6909Claimable[beneficiary][asset];
    }

    function totalClaimLiability(address asset) external view returns (uint256) {
        return _s().totalClaimLiability[asset];
    }

    function pendingRecipientAdmin(PoolId poolId, uint256 index) external view returns (address) {
        return _s().pendingRecipientAdmin[poolId][index];
    }

    function seedPosition(
        address token,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint16 creatorShareBps,
        FeeRecipient[] calldata recipients
    ) external nonReentrant onlyLauncher returns (PoolId poolId, uint128 liquidity, uint256 tokenUsed) {
        LockerStorage storage $ = _s();
        if (token == address(0) || token.code.length == 0) revert InvalidAddress();
        // Every launch is hooked, and the hook must be one this system knows. address(0) is never
        // a known hook, so this single check also enforces "no hookless launches" at the locker layer.
        if (!IArchemistV4LauncherView($.launcher).isKnownHook(address(key.hooks))) revert InvalidPool();
        if (address(IArchemistV4LauncherView($.launcher).POOL_MANAGER()) != address(POOL_MANAGER)) {
            revert InvalidInfrastructure();
        }
        if (tickLower >= tickUpper || tickLower % key.tickSpacing != 0 || tickUpper % key.tickSpacing != 0) {
            revert InvalidPosition();
        }
        if (creatorShareBps < CREATOR_SHARE_MIN_BPS || creatorShareBps > CREATOR_SHARE_MAX_BPS) {
            revert InvalidFeeSplit();
        }
        if (recipients.length == 0 || recipients.length > MAX_RECIPIENTS) {
            revert InvalidFeeSplit();
        }

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        if (!tokenIsCurrency0 && Currency.unwrap(key.currency1) != token) revert InvalidPool();

        uint256 sumBps = 0;
        address previousPayout = address(0);
        for (uint256 i; i < recipients.length; ++i) {
            FeeRecipient calldata recipient = recipients[i];
            if (
                recipient.admin == address(0) || recipient.payout == address(0) || recipient.bps == 0
                    || recipient.payout <= previousPayout
            ) revert InvalidFeeSplit();
            previousPayout = recipient.payout;
            sumBps += recipient.bps;
        }
        if (sumBps != BPS) revert InvalidFeeSplit();

        poolId = key.toId();
        if ($.positionInfo[poolId].exists) revert AlreadyConfigured();

        uint256 tokenBalanceBefore = IERC20Locker(token).balanceOf(address(this));
        if (tokenBalanceBefore == 0) revert InvalidPosition();

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        liquidity = tokenIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, tokenBalanceBefore)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, tokenBalanceBefore);
        if (liquidity == 0) revert InvalidPosition();

        $.positionInfo[poolId] = PositionInfo({
            token: token,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            creatorShareBps: creatorShareBps,
            exists: true
        });
        $.poolKey[poolId] = key;
        for (uint256 i; i < recipients.length; ++i) {
            $.recipients[poolId].push(recipients[i]);
        }

        _tstore(CB_ACTION_SLOT, uint256(CallbackAction.Seed));
        _tstore(CB_POOL_ID_SLOT, uint256(PoolId.unwrap(poolId)));
        POOL_MANAGER.unlock(abi.encode(poolId));
        _tstore(CB_ACTION_SLOT, uint256(CallbackAction.None));
        _tstore(CB_POOL_ID_SLOT, 0);

        tokenUsed = tokenBalanceBefore - IERC20Locker(token).balanceOf(address(this));
        if (tokenUsed == 0) revert InvalidPosition();
        if (tokenBalanceBefore - tokenUsed > MAX_TOKEN_DUST) revert InvalidPosition();

        emit PositionSeeded(poolId, token, tickLower, tickUpper, liquidity, tokenUsed);
    }

    function collect(PoolId poolId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        LockerStorage storage $ = _s();
        if (!$.positionInfo[poolId].exists) revert InvalidPool();
        PoolKey memory key = $.poolKey[poolId];

        uint256 balance0Before = _balance(key.currency0);
        uint256 balance1Before = _balance(key.currency1);

        _tstore(CB_ACTION_SLOT, uint256(CallbackAction.Collect));
        _tstore(CB_POOL_ID_SLOT, uint256(PoolId.unwrap(poolId)));
        POOL_MANAGER.unlock(abi.encode(poolId));
        _tstore(CB_ACTION_SLOT, uint256(CallbackAction.None));
        _tstore(CB_POOL_ID_SLOT, 0);

        amount0 = _balance(key.currency0) - balance0Before;
        amount1 = _balance(key.currency1) - balance1Before;
        // LP fees and donations carry no direction of their own, so they follow the buy split.
        (uint256 protocol0, uint256 protocol1) = _creditFees(poolId, key, amount0, amount1, false, true);

        emit FeesCollected(poolId, amount0, amount1, protocol0, protocol1);
    }

    /// @dev The ERC-6909 backing check below is the one boundary that makes an open hook registry safe:
    /// a hook can only have a fee credited that it actually minted to this contract as claims. A rogue
    /// registered hook calling in without minting gets `UnexpectedDelta` and achieves nothing.
    function recordHookFee(PoolId poolId, Currency currency, uint256 amount, bool isBuy) external onlyHook {
        LockerStorage storage $ = _s();
        PositionInfo storage info = $.positionInfo[poolId];
        if (!info.exists || amount == 0) revert InvalidPool();
        PoolKey memory key = $.poolKey[poolId];
        // The fee must come from the hook this pool is actually bound to - not merely from some hook
        // the registry knows. Without this a registered hook could record fees against another hook's
        // pool.
        if (address(key.hooks) != msg.sender) revert NotAuthorized();
        Currency quote = Currency.unwrap(key.currency0) == info.token ? key.currency1 : key.currency0;
        if (Currency.unwrap(currency) != Currency.unwrap(quote)) revert InvalidPool();

        address asset = Currency.unwrap(currency);
        if (POOL_MANAGER.balanceOf(address(this), currency.toId()) < $.totalClaimLiability[asset] + amount) {
            revert UnexpectedDelta();
        }

        if (Currency.unwrap(currency) == Currency.unwrap(key.currency0)) {
            _creditFees(poolId, key, amount, 0, true, isBuy);
        } else {
            _creditFees(poolId, key, 0, amount, true, isBuy);
        }
        emit HookFeeRecorded(poolId, asset, amount, isBuy);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotAuthorized();
        CallbackAction action = CallbackAction(_tload(CB_ACTION_SLOT));
        if (action == CallbackAction.Redeem) {
            (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
            if (
                Currency.unwrap(currency) != address(uint160(_tload(CB_CURRENCY_SLOT)))
                    || amount != _tload(CB_AMOUNT_SLOT)
            ) revert NotAuthorized();
            POOL_MANAGER.burn(address(this), currency.toId(), amount);
            POOL_MANAGER.take(currency, address(this), amount);
            return bytes("");
        }

        PoolId poolId = abi.decode(data, (PoolId));
        if (uint256(PoolId.unwrap(poolId)) != _tload(CB_POOL_ID_SLOT) || action == CallbackAction.None) {
            revert NotAuthorized();
        }

        LockerStorage storage $ = _s();
        PositionInfo memory info = $.positionInfo[poolId];
        PoolKey memory key = $.poolKey[poolId];
        int256 liquidityDelta = action == CallbackAction.Seed ? int256(uint256(info.liquidity)) : int256(0);

        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: info.tickLower,
                tickUpper: info.tickUpper,
                liquidityDelta: liquidityDelta,
                salt: POSITION_SALT
            }),
            bytes("")
        );

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        if (action == CallbackAction.Seed) {
            bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == info.token;
            if (tokenIsCurrency0 ? amount0 >= 0 || amount1 != 0 : amount1 >= 0 || amount0 != 0) {
                revert UnexpectedDelta();
            }
        } else if (amount0 < 0 || amount1 < 0) {
            revert UnexpectedDelta();
        }

        _settleOrTake(key.currency0, amount0);
        _settleOrTake(key.currency1, amount1);
        return abi.encode(delta);
    }

    function claim(address asset, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidAddress();
        LockerStorage storage $ = _s();
        amount = $.claimable[msg.sender][asset];
        if (amount == 0) revert NoClaimableBalance();
        uint256 claimAmount = $.erc6909Claimable[msg.sender][asset];

        $.claimable[msg.sender][asset] = 0;
        $.erc6909Claimable[msg.sender][asset] = 0;
        $.totalLiability[asset] -= amount;
        if (claimAmount != 0) {
            $.totalClaimLiability[asset] -= claimAmount;
            Currency currency = Currency.wrap(asset);
            if (TransientStateLibrary.isUnlocked(POOL_MANAGER)) {
                // Already inside someone else's active unlock frame (e.g. triggered synchronously from
                // ArchemistV4Hook mid-swap, via the buyback vault). PoolManager.unlock() cannot be called
                // again in that case (AlreadyUnlocked()), but burn()/take() only require the manager to
                // currently be unlocked - not that this contract is the one that unlocked it - so redeem
                // inline instead of opening a new callback frame.
                POOL_MANAGER.burn(address(this), currency.toId(), claimAmount);
                POOL_MANAGER.take(currency, address(this), claimAmount);
            } else {
                _redeemClaim(currency, claimAmount);
            }
        }
        _transfer(asset, to, amount);

        emit FeesClaimed(msg.sender, asset, to, amount);
    }

    function updateRecipientPayout(PoolId poolId, uint256 index, address newPayout) external {
        if (newPayout == address(0)) revert InvalidAddress();
        FeeRecipient storage recipient = _s().recipients[poolId][index];
        if (msg.sender != recipient.admin) revert NotAuthorized();
        address oldPayout = recipient.payout;
        recipient.payout = newPayout;
        emit RecipientPayoutUpdated(poolId, index, oldPayout, newPayout);
    }

    function transferRecipientAdmin(PoolId poolId, uint256 index, address newAdmin) external {
        if (newAdmin == address(0)) revert InvalidAddress();
        FeeRecipient storage recipient = _s().recipients[poolId][index];
        if (msg.sender != recipient.admin) revert NotAuthorized();
        _s().pendingRecipientAdmin[poolId][index] = newAdmin;
        emit RecipientAdminTransferStarted(poolId, index, recipient.admin, newAdmin);
    }

    function acceptRecipientAdmin(PoolId poolId, uint256 index) external {
        LockerStorage storage $ = _s();
        if ($.pendingRecipientAdmin[poolId][index] != msg.sender) revert NotAuthorized();
        FeeRecipient storage recipient = $.recipients[poolId][index];
        address oldAdmin = recipient.admin;
        recipient.admin = msg.sender;
        delete $.pendingRecipientAdmin[poolId][index];
        emit RecipientAdminTransferred(poolId, index, oldAdmin, msg.sender);
    }

    function getPoolKey(PoolId poolId) external view returns (PoolKey memory) {
        return _s().poolKey[poolId];
    }

    function getRecipients(PoolId poolId) external view returns (FeeRecipient[] memory) {
        return _s().recipients[poolId];
    }

    function _creditFees(
        PoolId poolId,
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bool claimBacked,
        bool isBuy
    ) private returns (uint256 protocol0, uint256 protocol1) {
        LockerStorage storage $ = _s();
        uint16 creatorShareBps = $.positionInfo[poolId].creatorShareBps;
        uint256 creatorTotal0 = amount0 * creatorShareBps / BPS;
        uint256 creatorTotal1 = amount1 * creatorShareBps / BPS;
        // Identical rate for both destinations, so the arithmetic below is direction-independent; only
        // `_creditEcosystemShare` cares which way the swap went.
        uint256 buyback0 = amount0 * BUYBACK_FEE_SHARE_BPS / BPS;
        uint256 buyback1 = amount1 * BUYBACK_FEE_SHARE_BPS / BPS;
        uint256 credited0 = 0;
        uint256 credited1 = 0;
        FeeRecipient[] storage recipients = $.recipients[poolId];

        for (uint256 i; i < recipients.length; ++i) {
            FeeRecipient storage recipient = recipients[i];
            uint256 share0 = creatorTotal0 * recipient.bps / BPS;
            uint256 share1 = creatorTotal1 * recipient.bps / BPS;
            if (i == 0) {
                share0 += creatorTotal0 - _distributedCreatorAmount(recipients, creatorTotal0, 0);
                share1 += creatorTotal1 - _distributedCreatorAmount(recipients, creatorTotal1, 0);
            }
            credited0 += share0;
            credited1 += share1;
            _credit(recipient.payout, Currency.unwrap(key.currency0), share0, claimBacked);
            _credit(recipient.payout, Currency.unwrap(key.currency1), share1, claimBacked);
        }

        address treasury_ = IArchemistV4LauncherView($.launcher).TREASURY();
        _creditEcosystemShare(poolId, key.currency0, buyback0, claimBacked, isBuy, treasury_);
        _creditEcosystemShare(poolId, key.currency1, buyback1, claimBacked, isBuy, treasury_);

        protocol0 = amount0 - credited0 - buyback0;
        protocol1 = amount1 - credited1 - buyback1;
        _credit(treasury_, Currency.unwrap(key.currency0), protocol0, claimBacked);
        _credit(treasury_, Currency.unwrap(key.currency1), protocol1, claimBacked);
    }

    /// @dev Routes the 12.5% ecosystem slice for one currency. A BUY credits the buyback vault, which
    /// swaps it toward ARCH. A SELL credits the holder rewards contract and tells it how much arrived,
    /// so the token's own per-holder accumulator can be raised.
    ///
    /// `notify` returning false means there is no eligible supply to divide among - the whole float is
    /// still inside the pool. The slice then goes to the treasury rather than being stranded in a
    /// contract that has nobody to pay it to. `notify` is written so it cannot revert on a live pool;
    /// this is inside a trader's swap, and their trade must not depend on reward bookkeeping.
    function _creditEcosystemShare(
        PoolId poolId,
        Currency currency,
        uint256 amount,
        bool claimBacked,
        bool isBuy,
        address treasury_
    ) private {
        if (amount == 0) return;
        LockerStorage storage $ = _s();
        address asset = Currency.unwrap(currency);
        if (isBuy) {
            _credit(IArchemistV4LauncherView($.launcher).BUYBACK_VAULT(), asset, amount, claimBacked);
            return;
        }
        address token = $.positionInfo[poolId].token;
        address rewards = IArchemistV4LauncherView($.launcher).HOLDER_REWARDS();
        bool accepted = IArchemistHolderRewards(rewards).notify(token, asset, amount);
        _credit(accepted ? rewards : treasury_, asset, amount, claimBacked);
        emit HolderRewardCredited(poolId, token, asset, amount, accepted);
    }

    function _distributedCreatorAmount(FeeRecipient[] storage recipients, uint256 creatorTotal, uint256 start)
        private
        view
        returns (uint256 distributed)
    {
        for (uint256 i = start; i < recipients.length; ++i) {
            distributed += creatorTotal * recipients[i].bps / BPS;
        }
    }

    function _credit(address beneficiary, address asset, uint256 amount, bool claimBacked) private {
        if (amount == 0) return;
        LockerStorage storage $ = _s();
        $.claimable[beneficiary][asset] += amount;
        $.totalLiability[asset] += amount;
        if (claimBacked) {
            $.erc6909Claimable[beneficiary][asset] += amount;
            $.totalClaimLiability[asset] += amount;
        }
    }

    function _redeemClaim(Currency currency, uint256 amount) private {
        _tstore(CB_ACTION_SLOT, uint256(CallbackAction.Redeem));
        _tstore(CB_CURRENCY_SLOT, uint256(uint160(Currency.unwrap(currency))));
        _tstore(CB_AMOUNT_SLOT, amount);
        POOL_MANAGER.unlock(abi.encode(currency, amount));
        _tstore(CB_ACTION_SLOT, uint256(CallbackAction.None));
        _tstore(CB_CURRENCY_SLOT, 0);
        _tstore(CB_AMOUNT_SLOT, 0);
    }

    function _settleOrTake(Currency currency, int128 delta) private {
        if (delta > 0) {
            POOL_MANAGER.take(currency, address(this), delta.toUint128());
        } else if (delta < 0) {
            // Safe: `delta` is widened to int256 before negation, so int128.min is representable.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(-int256(delta));
            if (currency.isAddressZero()) {
                if (address(this).balance < amount) revert UnexpectedDelta();
                POOL_MANAGER.settle{ value: amount }();
            } else {
                POOL_MANAGER.sync(currency);
                _transfer(Currency.unwrap(currency), address(POOL_MANAGER), amount);
                POOL_MANAGER.settle();
            }
        }
    }

    function _balance(Currency currency) private view returns (uint256) {
        return currency.isAddressZero()
            ? address(this).balance
            : IERC20Locker(Currency.unwrap(currency)).balanceOf(address(this));
    }

    function _transfer(address asset, address to, uint256 amount) private {
        if (asset == address(0)) {
            (bool sent,) = to.call{ value: amount }("");
            if (!sent) revert TransferFailed();
        } else {
            (bool success, bytes memory result) = asset.call(abi.encodeCall(IERC20Locker.transfer, (to, amount)));
            if (!success || (result.length != 0 && !abi.decode(result, (bool)))) revert TransferFailed();
        }
    }

    /// @inheritdoc ArchemistUpgradeable
    function ARCHEMIST_KIND() public pure override returns (bytes32) {
        return keccak256("archemist.kind.Locker");
    }

    function _checkImplementation(address newImplementation) internal view override {
        ArchemistV4Locker impl = ArchemistV4Locker(payable(newImplementation));
        if (address(impl.POOL_MANAGER()) != address(POOL_MANAGER) || impl.EXPECTED_CHAIN_ID() != EXPECTED_CHAIN_ID) {
            revert ImplementationMismatch();
        }
    }

    function _s() private pure returns (LockerStorage storage $) {
        assembly ("memory-safe") {
            $.slot := LOCKER_STORAGE
        }
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    receive() external payable {
        if (msg.sender != address(POOL_MANAGER)) revert NotAuthorized();
    }
}
