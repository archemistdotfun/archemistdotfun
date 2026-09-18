// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { PairConfig } from "./ArchemistV4Types.sol";
import { IArchemistPairRegistry } from "./interfaces/IArchemistPairRegistry.sol";
import { ArchemistUpgradeable } from "./upgradeability/ArchemistUpgradeable.sol";

interface IArchemistV4LauncherProbeView {
    function LOCKER() external view returns (address);
    function TREASURY() external view returns (address);
    function BUYBACK_VAULT() external view returns (address);
    function HOLDER_REWARDS() external view returns (address);
}

/// @notice The curated list of quote currencies a launch may be priced in, and the per-pair parameters
/// (tick band, spacing, creator-share band, buyback route) that go with each.
///
/// Curation here is deliberately **never retroactive**. `updatePair` and `setPairEnabled` change what a
/// *future* launch may do; they cannot touch a pool that already exists, whose tick spacing and hook are
/// baked into its `PoolKey`, nor a buyback route the vault has already validated and cached. That is the
/// same rule the launcher's hook registry follows, and it is what lets this contract have an owner at
/// all without that owner having power over anyone's live position.
///
/// The owner is the 48-hour timelock, so even curation is public and delayed. `upgradeToAndCall` is the
/// only other privileged function.
contract ArchemistPairRegistry is ArchemistUpgradeable, IArchemistPairRegistry {
    uint16 public constant FLAG_NATIVE = 1 << 0;
    uint16 public constant FLAG_TRANSFER_RESTRICTED = 1 << 1;
    uint16 public constant FLAG_PAUSABLE = 1 << 2;
    uint16 public constant FLAG_FEE_ON_TRANSFER = 1 << 3;
    uint16 public constant FLAG_NON_STANDARD_RETURN = 1 << 4;
    uint16 public constant ALL_FLAGS = (1 << 5) - 1;
    // Flags a probe can observe that force a pair to register as disabled. PAUSABLE only records
    // that the token exposes a paused() killswitch (capability, not current state - a token that is
    // actually paused right now fails the probe transfer outright, see ProbePullFailed), and
    // NON_STANDARD_RETURN is informational (transfer() without a bool return is handled safely by
    // the probe's low-level call, so it does not by itself make the token unsafe to list).
    uint16 public constant RISK_FLAGS = FLAG_TRANSFER_RESTRICTED | FLAG_FEE_ON_TRANSFER;
    bytes4 private constant PAUSED_SELECTOR = 0x5c975abb; // paused()
    uint8 public constant MIN_QUOTE_DECIMALS = 6;
    uint8 public constant MAX_QUOTE_DECIMALS = 18;
    // Hard, contract-wide bounds on creator fee share. A pair class can only narrow this band
    // (e.g. a regulated tokenized-equity pair capped lower), never widen past it.
    uint16 public constant CREATOR_SHARE_MIN = 5_000;
    uint16 public constant CREATOR_SHARE_MAX = 8_000;

    address public immutable CANONICAL_NATIVE_ALIAS;
    uint256 public immutable EXPECTED_CHAIN_ID;

    /// @custom:storage-location erc7201:archemist.storage.PairRegistry
    struct PairRegistryStorage {
        address launcher;
        mapping(address => PairConfig) pairConfig;
        mapping(address => bool) pairExists;
        address[] pairs;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("archemist.storage.PairRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PAIR_REGISTRY_STORAGE = 0x4b98d64879486bcfb1c6847ae653aaf294e40726bf0eda79e0156f7466fd7100;

    event PairAdded(
        address indexed quote, uint8 decimals, int24 tickSpacing, uint16 flags, address indexed buybackRoute
    );
    event PairUpdated(
        address indexed quote,
        int24 defaultTick,
        int24 minTick,
        int24 maxTick,
        int24 tickSpacing,
        uint16 flags,
        address indexed buybackRoute
    );
    event PairEnabledSet(address indexed quote, bool enabled);
    event PairProbed(address indexed quote, uint16 observedFlags, bool enabled);
    event PairProbeSkipped(address indexed quote);
    event ProbeRecipientsConfigured(
        address indexed launcher, address locker, address treasury, address buybackVault, address holderRewards
    );
    error InvalidAddress();
    error InvalidChain(uint256 actual, uint256 expected);
    error PairExists(address quote);
    error PairNotRegistered(address quote);
    error InvalidPair(address quote);
    error DecimalsImmutable();
    error DecimalsMismatch(uint8 onchain, uint8 configured);
    error DecimalsOutOfRange(uint8 decimals);
    error InvalidCreatorShareRange(uint16 min, uint16 max);
    error CanonicalConflict(address existing);
    error AlreadyConfigured();
    error InvalidInfrastructure();
    error ProbeRecipientsNotConfigured();
    error ProbeAmountTooSmall();
    error ProbePullFailed();
    error PairFlaggedRisky(uint16 flags);

    constructor(address canonicalNativeAlias_, uint256 expectedChainId_) {
        CANONICAL_NATIVE_ALIAS = canonicalNativeAlias_;
        EXPECTED_CHAIN_ID = expectedChainId_;
    }

    function initialize(address owner_) external initializer {
        if (block.chainid != EXPECTED_CHAIN_ID) revert InvalidChain(block.chainid, EXPECTED_CHAIN_ID);
        __ArchemistUpgradeable_init(owner_);
    }

    function LAUNCHER() public view returns (address) {
        return _s().launcher;
    }

    /// @param probeAmount Quote tokens the caller must have approved to this registry beforehand.
    ///        Ignored when `skipProbe` is true, for the native quote, and for ERC-20 quotes added
    ///        before probe recipients are configured (see `configureProbeRecipients`). Once probing is
    ///        active for a quote and not skipped, the registry pulls `probeAmount`, forwards thirds of
    ///        it to LOCKER/TREASURY/BUYBACK_VAULT, and derives `flags` from what it actually observed -
    ///        declared `config.flags` for that quote is ignored, matching the "probe is authoritative,
    ///        registry is only metadata" rule.
    /// @param skipProbe When true, registers `quote` on admin-declared `config.flags`/`config.enabled`
    ///        alone, without moving any funds - no need for the admin to hold or acquire the quote
    ///        token first. This is a deliberate trust decision, not a technical limitation: skipping the
    ///        probe means nobody has verified LOCKER/TREASURY/BUYBACK_VAULT can actually receive this
    ///        token before real launches depend on it. Before setting this true, manually verify the
    ///        token is a standard, freely transferable ERC-20 - see the admin checklist in
    ///        docs/PROTOCOL_MECHANISM.md. Emits `PairProbeSkipped` so a skipped pair is
    ///        distinguishable on-chain from a probed one.
    function addPair(address quote, PairConfig calldata config, uint256 probeAmount, bool skipProbe)
        external
        nonReentrant
        onlyOwner
    {
        if (_s().pairExists[quote]) revert PairExists(quote);
        _checkCanonicalConflict(quote);
        _validatePair(quote, config, false);

        uint16 observedFlags = config.flags;
        bool probed = quote != address(0) && _s().launcher != address(0) && !skipProbe;
        if (probed) {
            observedFlags = _probePair(quote, probeAmount);
        }
        PairConfig memory stored = config;
        stored.flags = observedFlags;
        stored.enabled = config.enabled && (observedFlags & RISK_FLAGS) == 0;

        _s().pairExists[quote] = true;
        _s().pairConfig[quote] = stored;
        _s().pairs.push(quote);
        emit PairAdded(quote, stored.decimals, stored.tickSpacing, stored.flags, stored.buybackRoute);
        if (probed) {
            emit PairProbed(quote, observedFlags, stored.enabled);
        } else {
            emit PairProbeSkipped(quote);
        }
    }

    function updatePair(address quote, PairConfig calldata config) external onlyOwner {
        if (!_s().pairExists[quote]) revert PairNotRegistered(quote);
        PairConfig memory current = _s().pairConfig[quote];
        if (config.decimals != current.decimals) revert DecimalsImmutable();
        _validatePair(quote, config, true);
        PairConfig memory updated = config;
        updated.enabled = current.enabled;
        // Flags are probe-derived, not admin-declared; a config update cannot silently launder them.
        updated.flags = current.flags;
        _s().pairConfig[quote] = updated;
        emit PairUpdated(
            quote,
            updated.defaultTick,
            updated.minTick,
            updated.maxTick,
            updated.tickSpacing,
            updated.flags,
            updated.buybackRoute
        );
    }

    function setPairEnabled(address quote, bool enabled) external onlyOwner {
        if (!_s().pairExists[quote]) revert PairNotRegistered(quote);
        if (enabled && _s().pairConfig[quote].flags & RISK_FLAGS != 0) {
            revert PairFlaggedRisky(_s().pairConfig[quote].flags);
        }
        _s().pairConfig[quote].enabled = enabled;
        emit PairEnabledSet(quote, enabled);
    }

    /// @notice Re-runs the safety probe for a pair already in the registry (e.g. after an issuer
    ///         fixes an allowlist that was blocking LOCKER/TREASURY/BUYBACK_VAULT). Never flips
    ///         `enabled` to true by itself - a clean probe result still requires an explicit
    ///         `setPairEnabled(quote, true)` from the admin.
    function reprobePair(address quote, uint256 probeAmount) external nonReentrant onlyOwner {
        if (!_s().pairExists[quote]) revert PairNotRegistered(quote);
        if (quote == address(0)) revert InvalidPair(quote);
        uint16 observedFlags = _probePair(quote, probeAmount);
        _s().pairConfig[quote].flags = observedFlags;
        if (observedFlags & RISK_FLAGS != 0) {
            _s().pairConfig[quote].enabled = false;
        }
        emit PairProbed(quote, observedFlags, _s().pairConfig[quote].enabled);
    }

    /// @notice One-time wiring to the launcher whose LOCKER/TREASURY/BUYBACK_VAULT the probe pays
    ///         into. Must be called after `ArchemistV4Launcher.configureSystemOnce`. Until this is
    ///         set, `addPair` skips probing entirely and trusts admin-declared flags, so this call
    ///         is what switches probing on for the whole registry.
    function configureProbeRecipients(address launcher_) external onlyOwner {
        if (_s().launcher != address(0)) revert AlreadyConfigured();
        if (launcher_ == address(0) || launcher_.code.length == 0) revert InvalidAddress();
        (address locker, address treasury, address vault, address rewards) = _launcherAddresses(launcher_);
        if (locker == address(0) || treasury == address(0) || vault == address(0) || rewards == address(0)) {
            revert InvalidInfrastructure();
        }
        _s().launcher = launcher_;
        emit ProbeRecipientsConfigured(launcher_, locker, treasury, vault, rewards);
    }

    function getPair(address quote) external view override returns (PairConfig memory config) {
        if (!_s().pairExists[quote]) revert PairNotRegistered(quote);
        return _s().pairConfig[quote];
    }

    function pairCount() external view returns (uint256) {
        return _s().pairs.length;
    }

    function pairAt(uint256 index) external view returns (address) {
        return _s().pairs[index];
    }

    /// @dev Pulls `probeAmount` from msg.sender, then forwards a quarter of what actually arrived to
    ///      each of LOCKER/TREASURY/BUYBACK_VAULT/HOLDER_REWARDS, measuring balances before/after every leg instead
    ///      of trusting return values or the requested amount. This is a technical pre-flight check,
    ///      not a curation step - the admin has already chosen to list `quote`; the probe only
    ///      catches launch-breaking details the admin can't see from outside the token (e.g. an
    ///      issuer allowlist that doesn't yet know about our LOCKER address).
    function _probePair(address quote, uint256 probeAmount) private returns (uint16 flags) {
        if (_s().launcher == address(0)) revert ProbeRecipientsNotConfigured();
        if (probeAmount < 4) revert ProbeAmountTooSmall();
        (address locker, address treasury, address vault, address rewards) = _launcherAddresses(_s().launcher);

        // Where the probe's tokens come from.
        //
        // Pulling them from `msg.sender` is the natural thing right up until the owner becomes a
        // `TimelockController`: then listing one quote currency needs the timelock to hold the token
        // AND to have an `approve` scheduled and executed against it - three timelocked operations
        // instead of one, to run a safety check. `skipProbe = true` becomes the path of least
        // resistance, and a safety net nobody uses is not a safety net.
        //
        // So the probe spends a balance the registry already holds, if it has one. Pre-funding is an
        // ordinary ERC-20 transfer from anybody - no approval, no governance, no coordination - and
        // listing the pair stays a single timelock operation. The pull is kept as the fallback, so an
        // EOA-owned registry behaves exactly as before.
        //
        // Two consequences, neither of them a hole: anything pre-funded beyond `probeAmount` stays in
        // this contract, which has no sweep - donations were always inert here and still are. And the
        // pre-funded path does not get to observe `transferFrom`'s return shape, which is why the
        // non-standard-return and fee-on-transfer flags are also derived in `_probeLeg`, from the four
        // `transfer` calls that follow. Nothing a pre-funder does can make a risky token look clean.
        uint256 held = _probeBalanceOf(quote, address(this));
        uint256 received;
        if (held >= probeAmount) {
            received = probeAmount;
        } else {
            (bool ok, bytes memory ret) = quote.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), probeAmount)
            );
            if (!ok) revert ProbePullFailed();
            if (ret.length == 0) {
                flags |= FLAG_NON_STANDARD_RETURN;
            } else if (ret.length < 32 || !abi.decode(ret, (bool))) {
                revert ProbePullFailed();
            }
            received = _probeBalanceOf(quote, address(this)) - held;
            if (received == 0) revert ProbePullFailed();
        }
        if (received < probeAmount) flags |= FLAG_FEE_ON_TRANSFER;

        uint256 leg = received / 4;
        if (leg == 0) revert ProbeAmountTooSmall();

        flags |= _probeLeg(quote, locker, leg);
        flags |= _probeLeg(quote, treasury, leg);
        flags |= _probeLeg(quote, vault, leg);
        // Holder rewards holds and pays out this same quote currency, so a quote it cannot receive
        // would break reward payouts for every launch on this pair - worth catching before any pool
        // exists, not after holders have accrued rewards they can never be paid.
        flags |= _probeLeg(quote, rewards, leg);

        (bool pausedOk, bytes memory pausedRet) = quote.staticcall(abi.encodeWithSelector(PAUSED_SELECTOR));
        if (pausedOk && pausedRet.length >= 32) flags |= FLAG_PAUSABLE;
    }

    /// @dev Sends `amount` of `quote` from this registry to `to` and reports what that leg revealed.
    ///      A revert or a `false` return marks the recipient as blocked (FLAG_TRANSFER_RESTRICTED);
    ///      any shortfall between amount sent and amount received marks fee-on-transfer.
    function _probeLeg(address quote, address to, uint256 amount) private returns (uint16 flags) {
        uint256 balBefore = _probeBalanceOf(quote, to);
        (bool ok, bytes memory ret) = quote.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok || (ret.length != 0 && (ret.length < 32 || !abi.decode(ret, (bool))))) {
            return FLAG_TRANSFER_RESTRICTED;
        }
        if (ret.length == 0) flags |= FLAG_NON_STANDARD_RETURN;
        uint256 receivedByTo = _probeBalanceOf(quote, to) - balBefore;
        if (receivedByTo < amount) flags |= FLAG_FEE_ON_TRANSFER;
    }

    function _probeBalanceOf(address token, address account) private view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        if (!ok || ret.length < 32) revert ProbePullFailed();
        return abi.decode(ret, (uint256));
    }

    function _launcherAddresses(address launcher_)
        private
        view
        returns (address locker, address treasury, address vault, address rewards)
    {
        IArchemistV4LauncherProbeView v = IArchemistV4LauncherProbeView(launcher_);
        locker = v.LOCKER();
        treasury = v.TREASURY();
        vault = v.BUYBACK_VAULT();
        rewards = v.HOLDER_REWARDS();
    }

    function _checkCanonicalConflict(address quote) private view {
        if (CANONICAL_NATIVE_ALIAS == address(0)) return;
        if (quote == address(0) && _s().pairExists[CANONICAL_NATIVE_ALIAS]) {
            revert CanonicalConflict(CANONICAL_NATIVE_ALIAS);
        }
        if (quote == CANONICAL_NATIVE_ALIAS && _s().pairExists[address(0)]) revert CanonicalConflict(address(0));
    }

    function _validatePair(address quote, PairConfig calldata config, bool allowDisabled) private view {
        if ((!allowDisabled && !config.enabled) || config.flags & ~ALL_FLAGS != 0) revert InvalidPair(quote);
        if (
            config.minCreatorBps < CREATOR_SHARE_MIN || config.maxCreatorBps > CREATOR_SHARE_MAX
                || config.minCreatorBps > config.maxCreatorBps
        ) revert InvalidCreatorShareRange(config.minCreatorBps, config.maxCreatorBps);
        // The two route shapes are exclusive. A v4 route is built from fee + tick spacing and must
        // carry no address (there is nothing to point at - the pool IS its key); a v3 route is an
        // address the vault checks against the canonical factory, and reads the fee tier off the pool
        // itself. Accepting a half-filled mixture of the two is how an address nobody validated ends up
        // being used.
        if (config.buybackRouteIsV4) {
            if (
                config.buybackRoute != address(0) || config.buybackRouteTickSpacing <= 0
                    || config.buybackRouteTickSpacing > TickMath.MAX_TICK_SPACING
            ) revert InvalidPair(quote);
        } else if (config.buybackRouteFee != 0 || config.buybackRouteTickSpacing != 0) {
            revert InvalidPair(quote);
        }
        if (
            config.tickSpacing <= 0 || config.tickSpacing > TickMath.MAX_TICK_SPACING
                || config.minTick >= config.defaultTick || config.defaultTick >= config.maxTick
                || config.minTick % config.tickSpacing != 0 || config.defaultTick % config.tickSpacing != 0
                || config.maxTick % config.tickSpacing != 0
                || config.minTick <= TickMath.minUsableTick(config.tickSpacing)
                || config.maxTick >= TickMath.maxUsableTick(config.tickSpacing)
        ) revert InvalidPair(quote);

        if (quote == address(0)) {
            if (config.decimals != 18 || config.flags & FLAG_NATIVE == 0) revert InvalidPair(quote);
            return;
        }
        if (quote.code.length == 0 || config.flags & FLAG_NATIVE != 0) revert InvalidPair(quote);
        if (config.decimals < MIN_QUOTE_DECIMALS || config.decimals > MAX_QUOTE_DECIMALS) {
            revert DecimalsOutOfRange(config.decimals);
        }
        (bool ok, bytes memory result) = quote.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || result.length < 32) revert InvalidPair(quote);
        uint256 rawDecimals = abi.decode(result, (uint256));
        if (rawDecimals > type(uint8).max) revert InvalidPair(quote);
        // Safe: the explicit bound above proves the metadata value fits in uint8.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 onchainDecimals = uint8(rawDecimals);
        if (onchainDecimals != config.decimals) revert DecimalsMismatch(onchainDecimals, config.decimals);
    }

    /// @inheritdoc ArchemistUpgradeable
    function ARCHEMIST_KIND() public pure override returns (bytes32) {
        return keccak256("archemist.kind.PairRegistry");
    }

    function _checkImplementation(address newImplementation) internal view override {
        ArchemistPairRegistry impl = ArchemistPairRegistry(newImplementation);
        if (impl.CANONICAL_NATIVE_ALIAS() != CANONICAL_NATIVE_ALIAS || impl.EXPECTED_CHAIN_ID() != EXPECTED_CHAIN_ID) {
            revert ImplementationMismatch();
        }
    }

    function _s() private pure returns (PairRegistryStorage storage $) {
        assembly ("memory-safe") {
            $.slot := PAIR_REGISTRY_STORAGE
        }
    }
}
