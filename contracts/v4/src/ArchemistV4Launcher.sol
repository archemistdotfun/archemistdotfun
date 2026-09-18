// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ArchemistV4Token } from "./ArchemistV4Token.sol";
import { ArchemistV4Constants, FeeRecipient, PairConfig } from "./ArchemistV4Types.sol";
import { InitialPriceMath } from "./InitialPriceMath.sol";
import { IArchemistHolderRewards } from "./interfaces/IArchemistHolderRewards.sol";
import { IArchemistHook } from "./interfaces/IArchemistHook.sol";
import { IArchemistPairRegistry } from "./interfaces/IArchemistPairRegistry.sol";
import { IArchemistV4Locker } from "./interfaces/IArchemistV4Locker.sol";
import { ArchemistUpgradeable } from "./upgradeability/ArchemistUpgradeable.sol";

interface IErc20QuoteMinimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Deploys launch tokens, initializes their pools and seeds the locked liquidity position; and,
/// keeps the registry of hooks a launch is allowed to pick from.
///
/// **The hook registry is the point of this contract's redesign.** Before, one hook address was written
/// once by `configureSystemOnce` and could never change, and the locker recognised exactly that one hook
/// as a legitimate source of fees. Changing the hook therefore meant redeploying the launcher, the
/// locker, the vault and the rewards contract behind it.
/// Now:
///
///   - any number of hooks can be *registered*; registration is append-only and validates from both
///     ends that the hook is wired to this launcher, this locker and this PoolManager, and that its
///     address bits match the permissions it declares;
///   - each launch names the hook it wants, and must name one (`hook == address(0)` reverts - every
///     Archemist launch is hooked, by design);
///   - `setHookEnabled` controls only which hooks *new* launches may pick. It is curation, never
///     retroactive: a pool's hook is part of its `PoolKey` and therefore of its identity, so an existing
///     pool keeps trading and paying fees through a disabled hook forever. The locker accepts fees from
///     any hook that was *ever* registered (`isKnownHook`) for exactly that reason.
///
/// The one boundary that makes a registry safe is not in this contract: it is the ERC-6909 backing check
/// in `ArchemistV4Locker.recordHookFee`, which refuses to credit a fee the calling hook did not actually
/// mint. A rogue registered hook can therefore waste its own gas, and nothing else.
///
/// **This contract is upgradeable** (UUPS, owner = a 48-hour TimelockController); the tokens and hooks
/// it deploys and points at are not. See `ArchemistUpgradeable` and `docs/UPGRADE_POLICY.md`. Because
/// `address(this)` under delegatecall is the proxy, the CREATE2 deployer of every launch token is the
/// proxy address, so a launcher upgrade that leaves the token's bytecode alone keeps every future token
/// address prediction identical.
contract ArchemistV4Launcher is ArchemistUpgradeable, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint256 public constant INITIAL_SUPPLY = ArchemistV4Constants.INITIAL_SUPPLY;
    uint16 public constant MAX_BPS = ArchemistV4Constants.BPS;

    struct LaunchParams {
        string name;
        string symbol;
        bytes32 salt;
        address quote;
        // Desired fully-diluted value of the whole launch supply, in the QUOTE currency's own raw
        // (smallest-unit) representation - e.g. `5_000e6` for a 5,000 USDC FDV. Never a raw tick: the
        // orientation-correct tick is derived on-chain from this (see InitialPriceMath), so neither the
        // creator nor a frontend can hand the launcher a tick computed for the wrong currency0/currency1
        // orientation.
        uint256 targetFdvQuoteRaw;
        // The hook this pool will be bound to, forever. Must be registered AND currently enabled.
        address hook;
        // Opaque to this contract: passed straight to `hook.lockConfig`, which decodes and bounds-checks
        // it. For ArchemistV4Hook this is an ABI-encoded `AntiSnipeParams`. Keeping the bounds in the
        // hook is what lets a second hook ship a different fee curve with no launcher change.
        bytes hookParams;
        uint16 creatorShareBps;
        FeeRecipient[] recipients;
        // Optional atomic creator buy, executed inside this same transaction right after the position is
        // seeded - so it can never be front-run or back-run the way a separate follow-up buy tx could be.
        // Zero skips it entirely. Exempt from the anti-snipe fee decay and maxBuyBps cap (see
        // ArchemistV4Hook.beforeSwap/afterSwap) since those exist to stop outsiders from sniping, not to
        // restrict the creator's own single, uninterruptible transaction - it still pays the flat base
        // hook fee like any other trade, split the normal three ways.
        uint256 creatorBuyAmount;
        uint256 creatorBuyMinTokensOut;
    }

    struct LaunchInfo {
        address creator;
        PoolId poolId;
        int24 initialTick;
        uint128 liquidity;
        uint256 tokensInPosition;
        address hook;
    }

    struct HookRecord {
        bool known;
        bool enabled;
    }

    /// @custom:storage-location erc7201:archemist.storage.Launcher
    struct LauncherStorage {
        address pairRegistry;
        address treasury;
        uint256 deployFee;
        address locker;
        address buybackVault;
        address holderRewards;
        bool createEnabled;
        bool retired;
        mapping(address hook => HookRecord) hookRecord;
        address[] knownHooks;
        mapping(address token => LaunchInfo) launchInfoForToken;
        address[] allTokens;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("archemist.storage.Launcher")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAUNCHER_STORAGE = 0x689b88330ef928c36efa0226238999b0a3788c71c79c8e51a7e2490244a1ee00;

    /// @dev The creator buy's own parameters travel through `PoolManager.unlock`'s data argument and
    /// come back as calldata, so they need neither storage (which would have to live outside the
    /// namespace struct above, or cost two SSTOREs per launch) nor transient slots. This one transient
    /// flag remains as the "I am the one who opened this frame" guard: it costs no slot, is cleared
    /// automatically at the end of the transaction, and makes an unsolicited callback impossible even if
    /// PoolManager's own dispatch ever changed.
    bytes32 private constant BUY_PENDING_SLOT = keccak256("archemist.transient.Launcher.buyPending");

    /// @dev What `_performCreatorBuy` hands to `unlockCallback` through PoolManager.
    struct CreatorBuy {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minOut;
    }

    IPoolManager public immutable POOL_MANAGER;
    uint256 public immutable EXPECTED_CHAIN_ID;

    event SystemConfigured(address indexed locker, address indexed buybackVault, address indexed holderRewards);
    event HookRegistered(address indexed hook);
    event HookEnabledSet(address indexed hook, bool enabled);
    event CreateEnabled();
    event Retired();
    event DeployFeePaid(address indexed creator, address indexed treasury, uint256 amount);
    event TokenLaunched(
        address indexed token,
        address indexed creator,
        PoolId indexed poolId,
        int24 initialTick,
        uint128 liquidity,
        uint256 tokensInPosition
    );
    event TokenLaunchedWithHook(address indexed token, address indexed hook);

    error InvalidAddress();
    error InvalidChain(uint256 actual, uint256 expected);
    error InvalidInfrastructure();
    error InvalidConfiguration();
    error InvalidPayment();
    error TokenAlreadyDeployed(address token);
    error PoolAlreadyExists(PoolId poolId);
    error CreateDisabled();
    error AlreadyConfigured();
    error NotAuthorized();
    error TransferFailed();
    error PairDisabled(address quote);
    error SlippageExceeded(uint256 tokensOut, uint256 minTokensOut);
    error UnexpectedCallback();
    error NotAContract();
    error HookLauncherMismatch();
    error HookLockerMismatch();
    error HookPoolManagerMismatch();
    error HookAddressMismatch();
    error HookAlreadyKnown();
    error HookDisabled(address hook);
    error Retired_();

    constructor(IPoolManager poolManager_, uint256 expectedChainId_) {
        POOL_MANAGER = poolManager_;
        EXPECTED_CHAIN_ID = expectedChainId_;
    }

    /// @dev Holds everything the old constructor held. Called exactly once, from the proxy's own
    /// constructor, so there is no window in which this contract exists unowned.
    function initialize(address owner_, address pairRegistry_, address treasury_, uint256 deployFee_)
        external
        initializer
    {
        if (block.chainid != EXPECTED_CHAIN_ID) revert InvalidChain(block.chainid, EXPECTED_CHAIN_ID);
        if (address(POOL_MANAGER) == address(0) || pairRegistry_ == address(0) || treasury_ == address(0)) {
            revert InvalidAddress();
        }
        if (address(POOL_MANAGER).code.length == 0 || pairRegistry_.code.length == 0) revert InvalidInfrastructure();
        __ArchemistUpgradeable_init(owner_);

        LauncherStorage storage $ = _s();
        $.pairRegistry = pairRegistry_;
        $.treasury = treasury_;
        $.deployFee = deployFee_;
    }

    // ---------------------------------------------------------------------------------------------
    // Views kept at their historical SCREAMING_CASE names, because the locker, the registry, the
    // indexer and the frontend all read them by those names.
    // ---------------------------------------------------------------------------------------------

    function PAIR_REGISTRY() public view returns (IArchemistPairRegistry) {
        return IArchemistPairRegistry(_s().pairRegistry);
    }

    function TREASURY() public view returns (address) {
        return _s().treasury;
    }

    function DEPLOY_FEE() public view returns (uint256) {
        return _s().deployFee;
    }

    function LOCKER() public view returns (address) {
        return _s().locker;
    }

    function BUYBACK_VAULT() public view returns (address) {
        return _s().buybackVault;
    }

    function HOLDER_REWARDS() public view returns (address) {
        return _s().holderRewards;
    }

    function createEnabled() external view returns (bool) {
        return _s().createEnabled;
    }

    function retired() external view returns (bool) {
        return _s().retired;
    }

    function launchInfoForToken(address token) external view returns (LaunchInfo memory) {
        return _s().launchInfoForToken[token];
    }

    function allTokens(uint256 index) external view returns (address) {
        return _s().allTokens[index];
    }

    function getTotalTokens() external view returns (uint256) {
        return _s().allTokens.length;
    }

    // ---------------------------------------------------------------------------------------------
    // System wiring
    // ---------------------------------------------------------------------------------------------

    /// @notice One-shot wiring to the three other system proxies. The hook is no longer part of this -
    /// hooks arrive through `registerHook`, which is the point of the registry.
    function configureSystemOnce(address locker_, address buybackVault_, address holderRewards_) external onlyOwner {
        LauncherStorage storage $ = _s();
        if ($.locker != address(0) || $.buybackVault != address(0) || $.holderRewards != address(0)) {
            revert AlreadyConfigured();
        }
        if (
            locker_ == address(0) || buybackVault_ == address(0) || holderRewards_ == address(0)
                || locker_.code.length == 0 || buybackVault_.code.length == 0 || holderRewards_.code.length == 0
        ) revert InvalidInfrastructure();
        // Every link is checked from both ends, so a half-wired system can never be switched on.
        if (
            IArchemistV4Locker(locker_).LAUNCHER() != address(this)
                || address(IArchemistV4Locker(locker_).POOL_MANAGER()) != address(POOL_MANAGER)
                || IArchemistHolderRewards(holderRewards_).LAUNCHER() != address(this)
                || IArchemistHolderRewards(holderRewards_).LOCKER() != locker_
        ) revert InvalidInfrastructure();

        $.locker = locker_;
        $.buybackVault = buybackVault_;
        $.holderRewards = holderRewards_;
        emit SystemConfigured(locker_, buybackVault_, holderRewards_);
    }

    /// @notice Adds a hook to the set launches may use. Append-only and irreversible: there is no
    /// `unregisterHook`, because the locker must keep accepting fees from every hook that ever backed a
    /// live pool. Use `setHookEnabled(hook, false)` to stop *new* launches picking it.
    ///
    /// The validation is the interesting part. Each check rules out a specific way a mis-wired hook
    /// would silently break launches that trusted it:
    ///   - `launcher()` / `locker()` / `poolManager()` must point back at exactly this system, or fees
    ///     would be minted into a locker that does not recognise the hook and would be unclaimable;
    ///   - the hook's address bits must equal the permissions it declares, which is what PoolManager
    ///     itself keys every callback off. A hook whose address was not mined to match would have its
    ///     callbacks silently skipped - no fee charged, no anti-snipe, no cap.
    function registerHook(address hook) external onlyOwner {
        if (hook == address(0)) revert InvalidAddress();
        if (hook.code.length == 0) revert NotAContract();
        LauncherStorage storage $ = _s();
        if ($.hookRecord[hook].known) revert HookAlreadyKnown();
        if (IArchemistHook(hook).launcher() != address(this)) revert HookLauncherMismatch();
        if (IArchemistHook(hook).locker() != $.locker || $.locker == address(0)) revert HookLockerMismatch();
        if (address(IArchemistHook(hook).poolManager()) != address(POOL_MANAGER)) revert HookPoolManagerMismatch();
        if (
            uint160(hook) & Hooks.ALL_HOOK_MASK
                != uint160(_permissionsToFlags(IArchemistHook(hook).getHookPermissions()))
        ) revert HookAddressMismatch();

        $.hookRecord[hook] = HookRecord({ known: true, enabled: true });
        $.knownHooks.push(hook);
        emit HookRegistered(hook);
        emit HookEnabledSet(hook, true);
    }

    /// @notice Curation, never retroactive. Disabling a hook stops new launches choosing it and does
    /// nothing at all to the pools already bound to it - they keep trading, keep charging their fee and
    /// keep being paid through the locker, because a pool's hook is part of its identity and cannot be
    /// changed by anyone, including us.
    function setHookEnabled(address hook, bool enabled) external onlyOwner {
        LauncherStorage storage $ = _s();
        if (!$.hookRecord[hook].known) revert HookDisabled(hook);
        $.hookRecord[hook].enabled = enabled;
        emit HookEnabledSet(hook, enabled);
    }

    /// @notice Was this hook ever registered? The locker's `onlyHook` check, and the one that must stay
    /// true forever for a pool launched on a since-disabled hook to keep working.
    function isKnownHook(address hook) external view returns (bool) {
        return _s().hookRecord[hook].known;
    }

    /// @notice May a NEW launch pick this hook?
    function isHookEnabled(address hook) public view returns (bool) {
        HookRecord storage record = _s().hookRecord[hook];
        return record.known && record.enabled;
    }

    function knownHooksLength() external view returns (uint256) {
        return _s().knownHooks.length;
    }

    function knownHookAt(uint256 index) external view returns (address) {
        return _s().knownHooks[index];
    }

    /// @notice One-way switch. There is no way back other
    /// than `retire()`, which is itself final - so the owner cannot use launch availability as a lever
    /// over creators who have already committed.
    function enableCreate() external onlyOwner {
        LauncherStorage storage $ = _s();
        if ($.retired) revert Retired_();
        if ($.locker == address(0) || $.buybackVault == address(0) || $.holderRewards == address(0)) {
            revert InvalidInfrastructure();
        }
        if ($.knownHooks.length == 0) revert InvalidInfrastructure();
        $.createEnabled = true;
        emit CreateEnabled();
    }

    /// @notice Permanently stops new launches on this launcher - the graceful end of life when a
    /// successor launcher exists. Irrevocable, and it touches nothing else: every pool already launched keeps
    /// trading, every fee keeps accruing, every claim and every buyback keeps working, forever.
    function retire() external onlyOwner {
        LauncherStorage storage $ = _s();
        $.retired = true;
        $.createEnabled = false;
        emit Retired();
    }

    // ---------------------------------------------------------------------------------------------
    // Launching
    // ---------------------------------------------------------------------------------------------

    function createToken(LaunchParams calldata p)
        external
        payable
        nonReentrant
        returns (address tokenAddress, PoolId poolId)
    {
        LauncherStorage storage $ = _s();
        if (!$.createEnabled) revert CreateDisabled();
        if (!isHookEnabled(p.hook)) revert HookDisabled(p.hook);
        uint256 requiredNativeValue = $.deployFee + (p.quote == address(0) ? p.creatorBuyAmount : 0);
        if (msg.value != requiredNativeValue) revert InvalidPayment();
        PairConfig memory pair = _enabledPair(p.quote);
        _validateLaunchParams(p, pair);

        bytes32 actualSalt = keccak256(abi.encode(msg.sender, block.chainid, p.salt));
        address predictedToken = _computeTokenAddress(actualSalt, p.name, p.symbol);
        if (predictedToken.code.length != 0) revert TokenAlreadyDeployed(predictedToken);
        // Registered before it exists: the token's own constructor needs the rewards address, and the
        // rewards contract only accepts calls about a token it already knows. CREATE2 makes the address
        // knowable in advance, so this ordering is safe - and the equality check below proves the
        // address we registered is the one we actually deployed.
        IArchemistHolderRewards($.holderRewards).register(predictedToken, p.quote);
        ArchemistV4Token token = new ArchemistV4Token{ salt: actualSalt }(
            p.name, p.symbol, INITIAL_SUPPLY, $.holderRewards, $.locker, address(POOL_MANAGER)
        );
        tokenAddress = address(token);
        if (tokenAddress != predictedToken) revert InvalidInfrastructure();

        (PoolKey memory key, int24 initialTick) = _initializePool(p, pair, tokenAddress);
        poolId = key.toId();

        if (!token.transfer($.locker, INITIAL_SUPPLY)) revert TransferFailed();
        (uint128 liquidity, uint256 tokenUsed) = _seedAndRecord(p, pair, tokenAddress, key, poolId, initialTick);

        if (p.creatorBuyAmount > 0) {
            _performCreatorBuy(p, key, tokenAddress);
        }

        (bool paid,) = $.treasury.call{ value: $.deployFee }("");
        if (!paid) revert TransferFailed();

        emit DeployFeePaid(msg.sender, $.treasury, $.deployFee);
        emit TokenLaunched(tokenAddress, msg.sender, poolId, initialTick, liquidity, tokenUsed);
        emit TokenLaunchedWithHook(tokenAddress, p.hook);
    }

    /// @dev Executes the atomic creator buy (see the LaunchParams.creatorBuyAmount comment) and forwards
    /// the purchased tokens to the creator. Pulls the quote amount via transferFrom for an ERC-20 quote
    /// (native quote's share of msg.value is already held by this contract, checked in createToken).
    function _performCreatorBuy(LaunchParams calldata p, PoolKey memory key, address tokenAddress) private {
        if (p.quote != address(0)) {
            if (!IErc20QuoteMinimal(p.quote).transferFrom(msg.sender, address(this), p.creatorBuyAmount)) {
                revert TransferFailed();
            }
        }

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == tokenAddress;
        // BUY = quote in, token out (the direction rule applied consistently everywhere in this
        // codebase): zeroForOne is true when the quote is currency0.
        bool zeroForOne = !tokenIsCurrency0;

        _tstore(BUY_PENDING_SLOT, 1);
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                CreatorBuy({
                    key: key, zeroForOne: zeroForOne, amountIn: p.creatorBuyAmount, minOut: p.creatorBuyMinTokensOut
                })
            )
        );
        _tstore(BUY_PENDING_SLOT, 0);
        uint256 tokensOut = abi.decode(result, (uint256));

        if (!ArchemistV4Token(tokenAddress).transfer(msg.sender, tokensOut)) revert TransferFailed();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotAuthorized();
        if (_tload(BUY_PENDING_SLOT) == 0) revert UnexpectedCallback();

        CreatorBuy memory buy = abi.decode(data, (CreatorBuy));
        PoolKey memory key = buy.key;
        bool zeroForOne = buy.zeroForOne;
        uint256 minOut = buy.minOut;
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -buy.amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        int128 quoteDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 tokenDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (quoteDelta >= 0 || tokenDelta <= 0) revert InvalidConfiguration();
        // Safe: tokenDelta was just checked > 0, so its uint128 bit pattern is a plain positive value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 tokensOut = uint256(uint128(tokenDelta));
        if (tokensOut < minOut) revert SlippageExceeded(tokensOut, minOut);

        Currency quoteCurrency = zeroForOne ? key.currency0 : key.currency1;
        // Safe: quoteDelta was just checked < 0 and is int128, so -quoteDelta fits uint128 exactly (it
        // can't be int128.min: that would require an in-pool balance change of 2^127, far beyond
        // creatorBuyAmount which is bounded by this contract's own settled balance).
        // forge-lint: disable-next-line(unsafe-typecast)
        _settle(quoteCurrency, uint256(uint128(-quoteDelta)));
        Currency tokenCurrency = zeroForOne ? key.currency1 : key.currency0;
        POOL_MANAGER.take(tokenCurrency, address(this), tokensOut);

        return abi.encode(tokensOut);
    }

    function _settle(Currency currency, uint256 amount) private {
        if (currency.isAddressZero()) {
            POOL_MANAGER.settle{ value: amount }();
        } else {
            POOL_MANAGER.sync(currency);
            if (!IErc20QuoteMinimal(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), amount)) {
                revert TransferFailed();
            }
            POOL_MANAGER.settle();
        }
    }

    /// @dev Split out of createToken solely to keep that function's local-variable count under the
    /// via-IR stack limit; behaviorally this is still "the first half of createToken".
    function _initializePool(LaunchParams calldata p, PairConfig memory pair, address tokenAddress)
        private
        returns (PoolKey memory key, int24 initialTick)
    {
        bool tokenIsCurrency0 = p.quote != address(0) && tokenAddress < p.quote;
        // Orientation is only known now that the token address exists, so the tick can only be derived
        // here - never accepted as a raw LaunchParams field (see the comment on targetFdvQuoteRaw).
        uint160 sqrtPriceX96;
        (initialTick, sqrtPriceX96) = InitialPriceMath.computeInitialTick(
            p.targetFdvQuoteRaw, INITIAL_SUPPLY, tokenIsCurrency0, pair.tickSpacing
        );
        if (initialTick < pair.minTick || initialTick > pair.maxTick) revert InvalidConfiguration();

        key = PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? tokenAddress : p.quote),
            currency1: Currency.wrap(tokenIsCurrency0 ? p.quote : tokenAddress),
            fee: 0,
            tickSpacing: pair.tickSpacing,
            hooks: IHooks(p.hook)
        });
        PoolId poolId = key.toId();
        (uint160 existingSqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        if (existingSqrtPriceX96 != 0) revert PoolAlreadyExists(poolId);

        // The hook decodes and bounds-checks `hookParams` itself; the launcher deliberately knows
        // nothing about their contents.
        IArchemistHook(p.hook).lockConfig(key, tokenAddress, Currency.wrap(p.quote), tokenIsCurrency0, p.hookParams);

        POOL_MANAGER.initialize(key, sqrtPriceX96);
    }

    /// @dev Second half of createToken, split out for the same stack-depth reason as _initializePool.
    function _seedAndRecord(
        LaunchParams calldata p,
        PairConfig memory pair,
        address tokenAddress,
        PoolKey memory key,
        PoolId poolId,
        int24 initialTick
    ) private returns (uint128 liquidity, uint256 tokenUsed) {
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == tokenAddress;
        int24 tickLower = tokenIsCurrency0 ? initialTick : TickMath.minUsableTick(pair.tickSpacing);
        int24 tickUpper = tokenIsCurrency0 ? TickMath.maxUsableTick(pair.tickSpacing) : initialTick;
        PoolId lockerPoolId;
        (lockerPoolId, liquidity, tokenUsed) = IArchemistV4Locker(_s().locker)
            .seedPosition(tokenAddress, key, tickLower, tickUpper, p.creatorShareBps, p.recipients);
        if (PoolId.unwrap(lockerPoolId) != PoolId.unwrap(poolId)) revert InvalidInfrastructure();

        LauncherStorage storage $ = _s();
        $.launchInfoForToken[tokenAddress] = LaunchInfo({
            creator: msg.sender,
            poolId: poolId,
            initialTick: initialTick,
            liquidity: liquidity,
            tokensInPosition: tokenUsed,
            hook: p.hook
        });
        $.allTokens.push(tokenAddress);
    }

    function computeTokenAddress(bytes32 salt, string calldata name, string calldata symbol, address creator)
        external
        view
        returns (address token)
    {
        if (creator == address(0)) revert InvalidAddress();
        bytes32 actualSalt = keccak256(abi.encode(creator, block.chainid, salt));
        token = _computeTokenAddress(actualSalt, name, symbol);
    }

    function _validateLaunchParams(LaunchParams calldata p, PairConfig memory pair) private pure {
        if (bytes(p.name).length == 0 || bytes(p.symbol).length == 0) revert InvalidConfiguration();
        if (
            p.targetFdvQuoteRaw == 0 || p.creatorShareBps < pair.minCreatorBps || p.creatorShareBps > pair.maxCreatorBps
        ) revert InvalidConfiguration();
    }

    function _enabledPair(address quote) private view returns (PairConfig memory config) {
        config = IArchemistPairRegistry(_s().pairRegistry).getPair(quote);
        if (!config.enabled) revert PairDisabled(quote);
    }

    function _computeTokenAddress(bytes32 actualSalt, string memory name, string memory symbol)
        private
        view
        returns (address token)
    {
        LauncherStorage storage $ = _s();
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(ArchemistV4Token).creationCode,
                abi.encode(name, symbol, INITIAL_SUPPLY, $.holderRewards, $.locker, address(POOL_MANAGER))
            )
        );
        token = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), actualSalt, initCodeHash))))
        );
    }

    /// @dev The same packing `Hooks.sol` uses, reproduced here so `registerHook` can compare a hook's
    /// declared permissions against the bits actually mined into its address. Kept in this one place and
    /// asserted against the library's own constants by `test_hookAddressBitsMatchDeclaredPermissions`.
    function _permissionsToFlags(Hooks.Permissions memory p) private pure returns (uint256 flags) {
        if (p.beforeInitialize) flags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) flags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) flags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) flags |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) flags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) flags |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) flags |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) flags |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) flags |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) flags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) flags |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }

    /// @inheritdoc ArchemistUpgradeable
    function ARCHEMIST_KIND() public pure override returns (bytes32) {
        return keccak256("archemist.kind.Launcher");
    }

    function _checkImplementation(address newImplementation) internal view override {
        ArchemistV4Launcher impl = ArchemistV4Launcher(payable(newImplementation));
        if (address(impl.POOL_MANAGER()) != address(POOL_MANAGER) || impl.EXPECTED_CHAIN_ID() != EXPECTED_CHAIN_ID) {
            revert ImplementationMismatch();
        }
    }

    function _s() private pure returns (LauncherStorage storage $) {
        assembly ("memory-safe") {
            $.slot := LAUNCHER_STORAGE
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
        // Only the PoolManager pays this contract, and only as the token leg of the creator's atomic
        // buy being taken back out.
        if (msg.sender != address(POOL_MANAGER)) revert NotAuthorized();
    }
}
