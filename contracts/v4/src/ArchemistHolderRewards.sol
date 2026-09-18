// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { IArchemistHolderRewards, IArchemistRewardToken } from "./interfaces/IArchemistHolderRewards.sol";
import { ArchemistUpgradeable } from "./upgradeability/ArchemistUpgradeable.sol";

interface IHolderRewardsLocker {
    function claimable(address beneficiary, address asset) external view returns (uint256);
    function claim(address asset, address to) external returns (uint256);
}

/// @notice Custodian of the holder slice of sell fees, and the entry point holders claim through. One
/// instance serves every launch; state is namespaced by token address.
///
/// **This contract no longer does the accounting.** It used to own the per-holder ledger and be called
/// by every token on every transfer. That callback is what token scanners reported as a trade
/// restriction, so the ledger moved into `ArchemistV4Token` itself (see the long note there) and what
/// remains here is the part that genuinely needs to be shared: custody of the quote currency, the pull
/// from the locker, and the payout paths.
///
/// The shape of the problem, and why it is still solved this way:
///
///   1. A sell cannot pay holders directly. The fee is charged inside someone else's swap, and the
///      holder set is unbounded - looping over it there would cost unbounded gas and let a single
///      refusing recipient revert an unrelated trader's trade. So a sell only ever moves ONE number,
///      the token's own `rewardPerTokenX128`. Every holder's entitlement is derived from their own
///      balance, on demand.
///
///   2. Money leaves only by an explicit transaction: `claim` (the holder pays their own gas) or
///      `claimFor` (anyone pays to push rewards to holders' own addresses - the "airdrop" path, which a
///      keeper can run on a schedule). Nothing is lost if nobody ever pushes; entitlements are recorded
///      permanently on the token and remain claimable.
///
/// Accepted limitation: any contract holding the token that cannot or will not claim - a third-party
/// pool, a custodian, a bridge - still accrues a share that may never be collected. That is inherent to
/// every balance-proportional distribution, and the alternative (an admin-editable exclusion list) would
/// hand someone the power to decide who is a real holder. For a transfer-restricted quote currency
/// (tokenized equity), a holder the issuer has not allowlisted simply cannot receive the payout; their
/// entitlement stays recorded and unclaimed rather than being lost or blocking anyone else.
///
/// The only privileged function on this contract is `upgradeToAndCall`, and its owner is the timelock.
/// There are no setters and no withdrawal path.
contract ArchemistHolderRewards is ArchemistUpgradeable, IArchemistHolderRewards {
    /// @dev Gas allowed to a recipient on the permissionless push path. Bounds what one hostile or
    /// merely expensive recipient can burn out of a batch the caller is paying for; a contract that
    /// legitimately needs more can always call `claim` itself, which forwards everything.
    uint256 private constant PUSH_GAS_STIPEND = 50_000;

    uint256 public immutable EXPECTED_CHAIN_ID;

    struct TokenState {
        /// @dev Currency holders of this token are rewarded in (address(0) = native).
        address quote;
        bool registered;
    }

    /// @custom:storage-location erc7201:archemist.storage.HolderRewards
    struct HolderRewardsStorage {
        address launcher;
        address locker;
        mapping(address token => TokenState) tokenState;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("archemist.storage.HolderRewards")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant HOLDER_REWARDS_STORAGE =
        0x7cc4e3216ff2a8a828543bdf480b8c60cfb363339885b57639e432fb9de1f000;

    event TokenRegistered(address indexed token, address indexed quote);
    event RewardNotified(address indexed token, address indexed quote, uint256 amount, uint256 eligibleSupply);
    event RewardClaimed(address indexed token, address indexed holder, address indexed to, uint256 amount);

    error NotLauncher();
    error NotLocker();
    error NotRegisteredToken();
    error AlreadyRegistered();
    error AssetMismatch();
    error InvalidAddress();
    error InvalidChain(uint256 actual, uint256 expected);
    error NothingToClaim();
    error TransferFailed();

    constructor(uint256 expectedChainId_) {
        EXPECTED_CHAIN_ID = expectedChainId_;
    }

    /// @dev Holds everything the old constructor held. `launcher_` and `locker_` are the two proxy
    /// addresses, both already deployed by the time this runs (see the deployment order in
    /// `script/DeployArcMainnet.s.sol`).
    function initialize(address owner_, address launcher_, address locker_) external initializer {
        if (block.chainid != EXPECTED_CHAIN_ID) revert InvalidChain(block.chainid, EXPECTED_CHAIN_ID);
        if (launcher_ == address(0) || locker_ == address(0)) revert InvalidAddress();
        if (launcher_.code.length == 0 || locker_.code.length == 0) revert InvalidAddress();
        __ArchemistUpgradeable_init(owner_);
        HolderRewardsStorage storage $ = _s();
        $.launcher = launcher_;
        $.locker = locker_;
    }

    function LAUNCHER() public view returns (address) {
        return _s().launcher;
    }

    function LOCKER() public view returns (address) {
        return _s().locker;
    }

    /// @notice Registers a launch token before it exists. The launcher knows the token's CREATE2 address
    /// ahead of deployment, and the token's own constructor needs this contract's address, so
    /// registration has to come first. Once written, nothing here can be changed.
    function register(address token, address quote) external {
        HolderRewardsStorage storage $ = _s();
        if (msg.sender != $.launcher) revert NotLauncher();
        if (token == address(0)) revert InvalidAddress();
        TokenState storage ts = $.tokenState[token];
        if (ts.registered) revert AlreadyRegistered();
        ts.registered = true;
        ts.quote = quote;
        emit TokenRegistered(token, quote);
    }

    /// @inheritdoc IArchemistHolderRewards
    function notify(address token, address asset, uint256 amount) external returns (bool accepted) {
        HolderRewardsStorage storage $ = _s();
        if (msg.sender != $.locker) revert NotLocker();
        TokenState storage ts = $.tokenState[token];
        if (!ts.registered) revert NotRegisteredToken();
        if (asset != ts.quote) revert AssetMismatch();

        // The token owns the ledger now; all this contract does is forward. `notifyReward` returns
        // false rather than reverting when there is nothing to divide among, because this call sits
        // inside a trader's swap and their trade must not depend on reward bookkeeping.
        accepted = IArchemistRewardToken(token).notifyReward(amount);
        if (accepted) {
            emit RewardNotified(token, ts.quote, amount, IArchemistRewardToken(token).eligibleSupply());
        }
    }

    /// @notice Collect your own accrued rewards for `token`.
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidAddress();
        TokenState storage ts = _s().tokenState[token];
        if (!ts.registered) revert NotRegisteredToken();

        amount = IArchemistRewardToken(token).consumeReward(msg.sender);
        if (amount == 0) revert NothingToClaim();

        _pull(ts.quote);
        if (!_payOut(ts.quote, to, amount, 0)) revert TransferFailed();
        emit RewardClaimed(token, msg.sender, to, amount);
    }

    /// @notice Permissionless push: pays each listed holder their accrued rewards, to their own address.
    /// This is the "airdrop" path - a keeper can run it on a schedule so holders receive without acting.
    /// A holder who cannot receive (a contract that rejects, an address the quote currency's issuer has
    /// not allowlisted) is skipped with their entitlement handed straight back, intact; they never block
    /// the rest of the batch.
    function claimFor(address token, address[] calldata holders) external nonReentrant returns (uint256 totalPaid) {
        TokenState storage ts = _s().tokenState[token];
        if (!ts.registered) revert NotRegisteredToken();
        address quote = ts.quote;

        _pull(quote);
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            if (holder == address(0)) continue;
            uint256 amount = IArchemistRewardToken(token).consumeReward(holder);
            if (amount == 0) continue;
            if (_payOut(quote, holder, amount, PUSH_GAS_STIPEND)) {
                totalPaid += amount;
                emit RewardClaimed(token, holder, holder, amount);
            } else {
                // Nothing lost, nothing stuck - the holder can still claim it themselves later, with
                // full gas and to an address of their choosing.
                IArchemistRewardToken(token).restoreReward(holder, amount);
            }
        }
    }

    /// @notice Rewards `holder` could collect for `token` right now, including what has accrued since
    /// their last settlement.
    function earned(address token, address holder) external view returns (uint256) {
        if (!_s().tokenState[token].registered) return 0;
        return IArchemistRewardToken(token).earned(holder);
    }

    /// @dev Kept at the same name and shape the frontend already reads, with the two accounting fields
    /// now sourced from the token rather than from this contract's own storage.
    function getTokenState(address token)
        external
        view
        returns (address quote, bool registered, uint256 eligibleSupply, uint256 rewardPerTokenX128)
    {
        TokenState storage ts = _s().tokenState[token];
        if (!ts.registered) return (address(0), false, 0, 0);
        return (
            ts.quote,
            true,
            IArchemistRewardToken(token).eligibleSupply(),
            IArchemistRewardToken(token).rewardPerTokenX128()
        );
    }

    function tokenState(address token) external view returns (address quote, bool registered) {
        TokenState storage ts = _s().tokenState[token];
        return (ts.quote, ts.registered);
    }

    /// @dev Sweeps whatever the locker currently owes this contract in `asset` into real balance. The
    /// locker credits rewards as claimable rather than pushing them, so this is where they materialize.
    function _pull(address asset) private {
        address locker = _s().locker;
        uint256 pending = IHolderRewardsLocker(locker).claimable(address(this), asset);
        if (pending != 0) IHolderRewardsLocker(locker).claim(asset, address(this));
    }

    /// @param gasStipend 0 forwards all remaining gas (self-service claim); non-zero caps it (push).
    function _payOut(address asset, address to, uint256 amount, uint256 gasStipend) private returns (bool) {
        if (asset == address(0)) {
            (bool sent,) =
                gasStipend == 0 ? to.call{ value: amount }("") : to.call{ value: amount, gas: gasStipend }("");
            return sent;
        }
        (bool ok, bytes memory ret) = asset.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    /// @inheritdoc ArchemistUpgradeable
    function ARCHEMIST_KIND() public pure override returns (bytes32) {
        return keccak256("archemist.kind.HolderRewards");
    }

    function _checkImplementation(address newImplementation) internal view override {
        if (ArchemistHolderRewards(payable(newImplementation)).EXPECTED_CHAIN_ID() != EXPECTED_CHAIN_ID) {
            revert ImplementationMismatch();
        }
    }

    function _s() private pure returns (HolderRewardsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := HOLDER_REWARDS_STORAGE
        }
    }

    receive() external payable {
        // Native rewards arrive only as this contract's own claim from the locker.
        if (msg.sender != _s().locker) revert InvalidAddress();
    }
}
