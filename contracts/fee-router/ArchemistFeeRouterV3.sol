// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IERC20FeeRouter {
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Matches SwapRouter02's ABI so this router is a drop-in replacement target
///      for the existing /token and /dex frontend calls.
interface ISwapRouter02FeeRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut);
}

/// @dev The one Uniswap v2 router entrypoint this router uses. Native-in/out variants are
///      deliberately absent: they need WETH9, which Arc does not have (Uniswap's own WETH9 on
///      Arc is a revert stub), so a v2 leg always settles the linked ERC-20 form.
interface IUniswapV2RouterFeeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @dev Minimal, dependency-free mirrors of the exact v4-core PoolManager surface this router
/// needs (same "no imports" discipline as V1 - see compile-fee-router.mjs, which has no
/// remappings configured). Field/parameter shapes must stay byte-for-byte ABI-compatible with
/// the real `@uniswap/v4-core` types (`Currency` is a bare `address` at the ABI level, `BalanceDelta`
/// is a bare `int256` packing two int128s - see `_unpackDelta` below).
struct PoolKeyFR {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParamsFR {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerFR {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKeyFR calldata key, SwapParamsFR calldata params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
}

interface IUnlockCallbackFR {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/**
 * @title ArchemistFeeRouterV3
 * @notice V3 of the UUPS-upgradeable fee router. Keeps every V1/V2 entrypoint byte-for-byte
 *         (exactInputSingle / exactInput for v3, exactInputSingleV4, exactInputV3ThenV4) and adds
 *         `exactInputMulti`: one call that walks an arbitrary list of legs across Uniswap v2, v3
 *         and v4 pools in any order ("smart pool" routing), skimming the protocol fee ONCE from
 *         the trade's input. The route itself is computed off-chain (indexer `/route`, which
 *         merges the Uniswap Trading API's pathfinding with the indexer's own quotes for hooked
 *         and native-currency v4 pools) - this contract only executes what it is handed.
 *
 * Arc-specific: the native currency (address(0)) and the linked ERC-20 USDC are one balance,
 * so a route may legitimately step from a pool quoted in one form into a pool quoted in the
 * other. `exactInputMulti` allows exactly that crossing, rescaling the carried amount by
 * 10^12 (18 vs 6 decimals), and nothing else. `nativeAlias` is that ERC-20's address; leave it
 * zero on a chain without the aliasing and the crossing is simply rejected as InvalidPath.
 *
 * Both venues charge the same `feeBps` protocol skim on `tokenIn`, independently of whatever
 * fee the venue itself charges (e.g. a v4 pool's own Archemist hook fee) - this is a deliberate
 * choice: the router's fee is Archemist's own revenue share for routing the trade, separate
 * from the hook's fee which is split between the token's creator, the ARCH buyback, and the
 * protocol treasury. See ArchemistV3Hook / ArchemistV3Locker for that split.
 *
 * Storage layout is append-only across versions (UUPS proxy, no constructor state). V1's
 * seven slots (owner, pendingOwner, treasury, swapVenue, feeBps, _lock, _initialized) are
 * reproduced here in the exact same order and must never be reordered or retyped. V2 then
 * consumes 10 of V1's 45 reserved `__gap` slots for its own state (see the accounting comment
 * above `__gap` below) - any V3+ implementation must declare this file's full field list,
 * in this exact order, before adding new state.
 *
 * IMPORTANT: Research draft. It has not been audited and must not be upgraded to on mainnet
 * before testnet validation and an independent security review.
 */
contract ArchemistFeeRouterV3 is IUnlockCallbackFR {
    // Same constant as ArchemistFeeRouterProxy - used only to expose the current
    // implementation address for off-chain tooling; the proxy is the sole writer.
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 private constant _MAX_FEE_BPS = 500; // 5% hard ceiling
    uint256 private constant _BPS_DENOMINATOR = 10_000;
    uint160 private constant _MIN_SQRT_PRICE_LIMIT = 4_295_128_740; // TickMath.MIN_SQRT_PRICE + 1
    uint160 private constant _MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341; // TickMath.MAX_SQRT_PRICE - 1

    // ---- V1 layout (unchanged, do not reorder/retype) ----
    address public owner;
    address public pendingOwner;
    address public treasury;
    address public swapVenue;
    uint256 public feeBps;
    uint8 private _lock;
    bool private _initialized;

    // ---- V2 additions (consume __gap; slot accounting below assumes 1 slot per field, no
    // cross-field packing, deliberately conservative so the __gap size below can never be
    // an overestimate even if the compiler does end up packing some of these) ----
    address public poolManager; // 1 slot
    bool private _initializedV2; // 1 slot
    PoolKeyFR private _activeKey; // 3 slots (currency0, currency1, [fee|tickSpacing|hooks])
    bool private _activeZeroForOne; // 1 slot
    uint256 private _activeAmountIn; // 1 slot (net of the router's own fee skim)
    uint256 private _activeMinOut; // 1 slot
    address private _activeRecipient; // 1 slot
    bool private _activePending; // 1 slot
    // Total consumed by V2: 10 of V1's original 45 __gap slots.

    // ---- V3 additions (same accounting, 1 slot each) ----
    address public v2Router; // 1 slot
    address public nativeAlias; // 1 slot
    bool private _initializedV3; // 1 slot
    // Total consumed by V3: 13 of V1's original 45 __gap slots.

    uint256[32] private __gap;

    event Initialized(address owner, address treasury, address swapVenue, uint256 feeBps);
    event InitializedV2(address poolManager);
    event InitializedV3(address v2Router, address nativeAlias);
    event V2RouterSet(address v2Router);
    event NativeAliasSet(address nativeAlias);
    event FeeBpsSet(uint256 feeBps);
    event TreasurySet(address treasury);
    event SwapVenueSet(address swapVenue);
    event PoolManagerSet(address poolManager);
    event OwnerTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event Upgraded(address indexed implementation);
    event FeeCollected(address indexed token, address indexed trader, uint256 feeAmount);

    error AlreadyInitialized();
    error NotAuthorized();
    error InvalidAddress();
    error InvalidFeeBps();
    error InvalidImplementation();
    error InvalidPath();
    error InvalidLeg();
    error InvalidPayment();
    error InvalidPool();
    error SlippageExceeded(uint256 amountOut, uint256 amountOutMinimum);
    error UnexpectedCallback();
    error Reentrancy();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier nonReentrant() {
        if (_lock == 1) revert Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    /// @dev Locks the logic contract itself so `initialize`/`initializeV2` can only ever
    ///      succeed through a proxy's delegatecall, never by calling this address directly.
    constructor() {
        _initialized = true;
        _initializedV2 = true;
        _initializedV3 = true;
    }

    // ---- V1 initializer (kept for ABI/deploy-script parity; a no-op on an upgrade of an
    // already-initialized proxy, which is the only path this version will ever actually take) ----
    function initialize(address owner_, address treasury_, address swapVenue_, uint256 feeBps_) external {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || treasury_ == address(0) || swapVenue_ == address(0)) revert InvalidAddress();
        if (feeBps_ > _MAX_FEE_BPS) revert InvalidFeeBps();
        _initialized = true;
        owner = owner_;
        treasury = treasury_;
        swapVenue = swapVenue_;
        feeBps = feeBps_;
        emit Initialized(owner_, treasury_, swapVenue_, feeBps_);
    }

    /// @notice One-time V2 setup - call via `upgradeToAndCall`'s `data` parameter in the same
    ///         transaction as the upgrade, exactly like `initialize` is called from the proxy
    ///         constructor's `data_` parameter.
    function initializeV2(address poolManager_) external {
        if (_initializedV2) revert AlreadyInitialized();
        if (poolManager_ == address(0)) revert InvalidAddress();
        if (poolManager_.code.length == 0) revert InvalidAddress();
        _initializedV2 = true;
        poolManager = poolManager_;
        emit InitializedV2(poolManager_);
    }

    /// @notice One-time V3 setup - pass via `upgradeToAndCall`'s `data`. `v2Router_` is the
    ///         Uniswap v2 router used by v2 legs (may be zero on a chain without v2, in which
    ///         case v2 legs revert). `nativeAlias_` is the linked ERC-20 form of the native
    ///         currency on Arc (0x3600…); zero disables native<->alias crossings.
    function initializeV3(address v2Router_, address nativeAlias_) external {
        if (_initializedV3) revert AlreadyInitialized();
        _initializedV3 = true;
        v2Router = v2Router_;
        nativeAlias = nativeAlias_;
        emit InitializedV3(v2Router_, nativeAlias_);
    }

    /// @notice Lets off-chain code tell which entrypoints this proxy currently supports.
    function routerVersion() external pure returns (uint256) {
        return 3;
    }

    // ---- admin ----

    function setV2Router(address v2Router_) external onlyOwner {
        v2Router = v2Router_;
        emit V2RouterSet(v2Router_);
    }

    function setNativeAlias(address nativeAlias_) external onlyOwner {
        nativeAlias = nativeAlias_;
        emit NativeAliasSet(nativeAlias_);
    }

    function setFeeBps(uint256 feeBps_) external onlyOwner {
        if (feeBps_ > _MAX_FEE_BPS) revert InvalidFeeBps();
        feeBps = feeBps_;
        emit FeeBpsSet(feeBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Repoints v3 swaps at a different SwapRouter02-compatible venue without
    ///         an upgrade (e.g. a new Uniswap v3 fork deployment with the same ABI).
    function setSwapVenue(address swapVenue_) external onlyOwner {
        if (swapVenue_ == address(0)) revert InvalidAddress();
        swapVenue = swapVenue_;
        emit SwapVenueSet(swapVenue_);
    }

    /// @notice Repoints v4 swaps at a different PoolManager singleton without an upgrade.
    function setPoolManager(address poolManager_) external onlyOwner {
        if (poolManager_ == address(0)) revert InvalidAddress();
        poolManager = poolManager_;
        emit PoolManagerSet(poolManager_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnerTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotAuthorized();
        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnerTransferred(previousOwner, owner);
    }

    /// @notice UUPS upgrade entrypoint, callable only through the proxy (owner is
    ///         proxy-scoped storage). Use `data` to call an initializer-style
    ///         function on the new implementation in the same transaction.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external onlyOwner {
        if (newImplementation.code.length == 0) revert InvalidImplementation();
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
        emit Upgraded(newImplementation);
        if (data.length > 0) {
            (bool ok, bytes memory ret) = newImplementation.delegatecall(data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function implementation() external view returns (address impl) {
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
    }

    // ---- v3 swaps (unchanged from V1) ----

    function exactInputSingle(ISwapRouter02FeeRouter.ExactInputSingleParams calldata params)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        uint256 netAmountIn = _pullAndTakeFee(params.tokenIn, params.amountIn);
        _ensureAllowance(params.tokenIn, netAmountIn);
        amountOut = ISwapRouter02FeeRouter(swapVenue).exactInputSingle(
            ISwapRouter02FeeRouter.ExactInputSingleParams({
                tokenIn: params.tokenIn,
                tokenOut: params.tokenOut,
                fee: params.fee,
                recipient: params.recipient,
                amountIn: netAmountIn,
                amountOutMinimum: params.amountOutMinimum,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            })
        );
    }

    function exactInput(ISwapRouter02FeeRouter.ExactInputParams calldata params)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        address tokenIn = _firstTokenFromPath(params.path);
        uint256 netAmountIn = _pullAndTakeFee(tokenIn, params.amountIn);
        _ensureAllowance(tokenIn, netAmountIn);
        amountOut = ISwapRouter02FeeRouter(swapVenue).exactInput(
            ISwapRouter02FeeRouter.ExactInputParams({
                path: params.path,
                recipient: params.recipient,
                amountIn: netAmountIn,
                amountOutMinimum: params.amountOutMinimum
            })
        );
    }

    // ---- v4 swaps (new in V2) ----

    struct V4SwapParams {
        PoolKeyFR key;
        // true = pay currency0, receive currency1. false = the reverse. The caller (frontend)
        // resolves this from the pool's own currency ordering, same as any v4 integration.
        bool zeroForOne;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Single-hop exact-input swap against a Uniswap v4 pool (e.g. an Archemist V3
    ///         hook pool). Skims `feeBps` from `amountIn` exactly like the v3 path above, then
    ///         swaps the remainder through `poolManager`. For a native-currency leg, send the
    ///         full `amountIn` as `msg.value` - there is no partial/excess payment: it must
    ///         match exactly, mirroring ArchemistV3Launcher's own payment check.
    function exactInputSingleV4(V4SwapParams calldata params) external payable nonReentrant returns (uint256 amountOut) {
        if (params.key.currency0 == params.key.currency1) revert InvalidPool();
        address tokenIn = params.zeroForOne ? params.key.currency0 : params.key.currency1;
        address tokenOut = params.zeroForOne ? params.key.currency1 : params.key.currency0;

        uint256 netAmountIn;
        if (tokenIn == address(0)) {
            if (msg.value != params.amountIn) revert InvalidPayment();
            netAmountIn = _takeNativeFee(params.amountIn);
        } else {
            if (msg.value != 0) revert InvalidPayment();
            netAmountIn = _pullAndTakeFee(tokenIn, params.amountIn);
        }

        _activeKey = params.key;
        _activeZeroForOne = params.zeroForOne;
        _activeAmountIn = netAmountIn;
        _activeMinOut = params.amountOutMinimum;
        _activeRecipient = params.recipient;
        _activePending = true;
        bytes memory result = IPoolManagerFR(poolManager).unlock(bytes(""));
        _activePending = false;
        amountOut = abi.decode(result, (uint256));

        // Unreachable in practice (tokenOut is always the non-`tokenIn` currency), kept only
        // to silence an unused-variable warning without changing the ABI.
        tokenOut;
    }

    // ---- mixed v3 -> v4 route (new in V2) ----

    struct V3ThenV4Params {
        // First hop, on the SwapRouter02-compatible venue. `v3TokenOut` is the
        // intermediate currency and must be the v4 hop's input side.
        address tokenIn;
        address v3TokenOut;
        uint24 v3Fee;
        // Second hop, on the v4 PoolManager.
        PoolKeyFR key;
        bool zeroForOne;
        address recipient;
        uint256 amountIn;
        // Applied to the FINAL output only. A squeeze on the first hop leaves
        // less to swap on the second and so shows up here too, which is why
        // there is no separate intermediate minimum to get wrong.
        uint256 amountOutMinimum;
    }

    /// @notice Exact-input swap that chains a Uniswap v3 hop into a Uniswap v4 hop, for a
    ///         token whose only pool is against a quote the trader does not hold. Buying an
    ///         ARCH-paired launch with USDC is the motivating case: USDC/ARCH is a classic v3
    ///         pool, ARCH/TOKEN is a v4 hook pool, and neither `exactInput` (v3 path format
    ///         only) nor `exactInputSingleV4` (one pool) can span both.
    ///
    ///         The protocol fee is skimmed ONCE, from `amountIn`, exactly as a single-hop
    ///         trade would - chaining hops is a routing detail and must not cost the trader a
    ///         second cut. The venue's own fees and the v4 pool's hook fee still apply per hop,
    ///         since those are the pools' charges, not this router's.
    ///
    ///         ERC-20 in only: the intermediate currency is whatever the v3 hop pays out, so
    ///         there is no native leg to fund. Left non-payable rather than checking
    ///         `msg.value` - the compiler rejects value sent to a non-payable function on its
    ///         own, which is the same guarantee without the redundant check.
    function exactInputV3ThenV4(V3ThenV4Params calldata params) external nonReentrant returns (uint256 amountOut) {
        if (params.key.currency0 == params.key.currency1) revert InvalidPool();
        if (params.tokenIn == address(0) || params.v3TokenOut == address(0)) revert InvalidPool();

        // The hops have to actually meet: the v4 leg's input currency must be
        // the token the v3 leg pays out, or the second swap would be settled
        // from whatever unrelated balance this router happens to hold.
        address v4In = params.zeroForOne ? params.key.currency0 : params.key.currency1;
        if (v4In != params.v3TokenOut) revert InvalidPath();

        uint256 netAmountIn = _pullAndTakeFee(params.tokenIn, params.amountIn);
        _ensureAllowance(params.tokenIn, netAmountIn);

        // Paid to this router, not the trader: it is the second hop's input.
        // Measured rather than trusted from the return value, so a venue that
        // reports optimistically cannot make the v4 leg try to settle more
        // than actually arrived.
        uint256 balanceBefore = IERC20FeeRouter(params.v3TokenOut).balanceOf(address(this));
        ISwapRouter02FeeRouter(swapVenue).exactInputSingle(
            ISwapRouter02FeeRouter.ExactInputSingleParams({
                tokenIn: params.tokenIn,
                tokenOut: params.v3TokenOut,
                fee: params.v3Fee,
                recipient: address(this),
                amountIn: netAmountIn,
                // No floor on the intermediate - `amountOutMinimum` on the
                // final output is strictly stronger, and a second threshold
                // would only add a way to misconfigure the trade.
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 intermediate = IERC20FeeRouter(params.v3TokenOut).balanceOf(address(this)) - balanceBefore;
        if (intermediate == 0) revert InvalidPool();

        _activeKey = params.key;
        _activeZeroForOne = params.zeroForOne;
        _activeAmountIn = intermediate;
        _activeMinOut = params.amountOutMinimum;
        _activeRecipient = params.recipient;
        _activePending = true;
        bytes memory result = IPoolManagerFR(poolManager).unlock(bytes(""));
        _activePending = false;
        amountOut = abi.decode(result, (uint256));
    }

    // ---- multi-venue route (new in V3) ----

    uint8 private constant _LEG_V2 = 0;
    uint8 private constant _LEG_V3 = 1;
    uint8 private constant _LEG_V4 = 2;
    uint256 private constant _NATIVE_ALIAS_SCALE = 1e12; // 18-decimal native : 6-decimal alias

    struct Leg {
        // _LEG_V2 / _LEG_V3 / _LEG_V4.
        uint8 kind;
        // The currency this leg consumes and pays, as the pool itself sees them
        // (address(0) for native on a v4 pool). Must chain: leg[i].tokenOut is
        // leg[i+1].tokenIn, or its native/alias twin.
        address tokenIn;
        address tokenOut;
        // v3 only: the pool's fee tier.
        uint24 fee;
        // v4 only: the pool key. zeroForOne is derived from tokenIn.
        PoolKeyFR key;
    }

    /// @notice Exact-input swap across any sequence of v2 / v3 / v4 legs. The protocol fee is
    ///         skimmed once, from `amountIn`; every leg then runs on what the previous one
    ///         actually delivered (measured, never trusted), and `amountOutMinimum` is checked on
    ///         the final output only. For a native first leg send `amountIn` as `msg.value`
    ///         exactly. Intermediate outputs stay inside this contract for one call and are
    ///         fully consumed by the next leg, so nothing is ever left stranded.
    function exactInputMulti(Leg[] calldata legs, uint256 amountIn, uint256 amountOutMinimum, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (legs.length == 0) revert InvalidPath();
        if (recipient == address(0)) revert InvalidAddress();

        address carryCurrency = legs[0].tokenIn;
        uint256 carry;
        if (carryCurrency == address(0)) {
            if (msg.value != amountIn) revert InvalidPayment();
            carry = _takeNativeFee(amountIn);
        } else {
            if (msg.value != 0) revert InvalidPayment();
            carry = _pullAndTakeFee(carryCurrency, amountIn);
        }

        uint256 last = legs.length - 1;
        for (uint256 i = 0; i <= last; i++) {
            Leg calldata leg = legs[i];
            if (leg.tokenIn == leg.tokenOut) revert InvalidLeg();
            (carryCurrency, carry) = _crossForm(carryCurrency, carry, leg.tokenIn);
            if (carry == 0) revert InvalidPool();

            bool isLast = i == last;
            address to = isLast ? recipient : address(this);
            uint256 minOut = isLast ? amountOutMinimum : 0;
            carry = _runLeg(leg, carry, to, minOut, isLast);
            carryCurrency = leg.tokenOut;
        }
        amountOut = carry;
        if (amountOut < amountOutMinimum) revert SlippageExceeded(amountOut, amountOutMinimum);
    }

    /// @dev Reconciles what the previous leg paid with what the next one consumes. Same
    ///      currency: nothing to do. Native vs its ERC-20 alias: one balance, two decimal
    ///      scales - rescale. Anything else does not chain and must never be swapped from
    ///      whatever unrelated balance this contract happens to hold.
    function _crossForm(address have, uint256 amount, address need) private view returns (address, uint256) {
        if (have == need) return (need, amount);
        address alias_ = nativeAlias;
        if (alias_ != address(0)) {
            if (have == address(0) && need == alias_) return (need, amount / _NATIVE_ALIAS_SCALE);
            if (have == alias_ && need == address(0)) return (need, amount * _NATIVE_ALIAS_SCALE);
        }
        revert InvalidPath();
    }

    function _runLeg(Leg calldata leg, uint256 amountIn, address to, uint256 minOut, bool isLast)
        private
        returns (uint256 amountOut)
    {
        if (leg.kind == _LEG_V4) {
            if (leg.key.currency0 == leg.key.currency1) revert InvalidPool();
            bool zeroForOne = leg.tokenIn == leg.key.currency0;
            if (!zeroForOne && leg.tokenIn != leg.key.currency1) revert InvalidLeg();
            if (leg.tokenOut != (zeroForOne ? leg.key.currency1 : leg.key.currency0)) revert InvalidLeg();
            _activeKey = leg.key;
            _activeZeroForOne = zeroForOne;
            _activeAmountIn = amountIn;
            _activeMinOut = minOut;
            _activeRecipient = to;
            _activePending = true;
            bytes memory result = IPoolManagerFR(poolManager).unlock(bytes(""));
            _activePending = false;
            return abi.decode(result, (uint256));
        }

        // v2 and v3 both consume an ERC-20 held by this contract. Output is measured on the
        // intermediate legs (it stays here) and trusted from the venue's return value only on
        // the final leg, where it goes straight to the recipient and the venue enforced minOut.
        if (leg.tokenIn == address(0)) revert InvalidLeg();
        uint256 before = isLast ? 0 : _balanceOf(leg.tokenOut, address(this));
        if (leg.kind == _LEG_V3) {
            _ensureAllowanceFor(leg.tokenIn, swapVenue, amountIn);
            amountOut = ISwapRouter02FeeRouter(swapVenue).exactInputSingle(
                ISwapRouter02FeeRouter.ExactInputSingleParams({
                    tokenIn: leg.tokenIn,
                    tokenOut: leg.tokenOut,
                    fee: leg.fee,
                    recipient: to,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        } else if (leg.kind == _LEG_V2) {
            address router = v2Router;
            if (router == address(0)) revert InvalidLeg();
            _ensureAllowanceFor(leg.tokenIn, router, amountIn);
            address[] memory path = new address[](2);
            path[0] = leg.tokenIn;
            path[1] = leg.tokenOut;
            uint256[] memory amounts =
                IUniswapV2RouterFeeRouter(router).swapExactTokensForTokens(amountIn, minOut, path, to, block.timestamp);
            amountOut = amounts[amounts.length - 1];
        } else {
            revert InvalidLeg();
        }
        if (!isLast) amountOut = _balanceOf(leg.tokenOut, address(this)) - before;
    }

    function _balanceOf(address currency, address account) private view returns (uint256) {
        return currency == address(0) ? account.balance : IERC20FeeRouter(currency).balanceOf(account);
    }

    function _ensureAllowanceFor(address token, address spender, uint256 amountIn) private {
        if (IERC20FeeRouter(token).allowance(address(this), spender) < amountIn) {
            IERC20FeeRouter(token).approve(spender, type(uint256).max);
        }
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        if (msg.sender != poolManager) revert NotAuthorized();
        if (!_activePending) revert UnexpectedCallback();

        PoolKeyFR memory key = _activeKey;
        bool zeroForOne = _activeZeroForOne;
        int256 rawDelta = IPoolManagerFR(poolManager).swap(
            key,
            SwapParamsFR({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(_activeAmountIn),
                sqrtPriceLimitX96: zeroForOne ? _MIN_SQRT_PRICE_LIMIT : _MAX_SQRT_PRICE_LIMIT
            }),
            bytes("")
        );
        (int128 amount0, int128 amount1) = _unpackDelta(rawDelta);

        int128 inDelta = zeroForOne ? amount0 : amount1;
        int128 outDelta = zeroForOne ? amount1 : amount0;
        if (inDelta >= 0 || outDelta <= 0) revert InvalidPool();
        // Safe: outDelta was just checked > 0, so its uint128 bit pattern is a plain positive value.
        uint256 tokensOut = uint256(uint128(outDelta));
        if (tokensOut < _activeMinOut) revert SlippageExceeded(tokensOut, _activeMinOut);

        address currencyIn = zeroForOne ? key.currency0 : key.currency1;
        // Safe: inDelta was just checked < 0 and is int128, so -inDelta fits uint128 exactly
        // (it can't be int128.min: that would require this swap alone to move 2^127 units,
        // far beyond any amountIn this router could ever have settled from its own balance).
        _settle(currencyIn, uint256(uint128(-inDelta)));

        address currencyOut = zeroForOne ? key.currency1 : key.currency0;
        IPoolManagerFR(poolManager).take(currencyOut, _activeRecipient, tokensOut);

        return abi.encode(tokensOut);
    }

    function _settle(address currency, uint256 amount) private {
        if (currency == address(0)) {
            IPoolManagerFR(poolManager).settle{ value: amount }();
        } else {
            IPoolManagerFR(poolManager).sync(currency);
            if (!IERC20FeeRouter(currency).transfer(poolManager, amount)) revert TransferFailed();
            IPoolManagerFR(poolManager).settle();
        }
    }

    /// @dev Unpacks a v4-core `BalanceDelta` (a bare `int256` at the ABI level: the top 128
    ///      bits are amount0, the bottom 128 bits are amount1, each independently sign-extended
    ///      - this is exactly `BalanceDelta.amount0()`/`.amount1()`'s own bit layout).
    function _unpackDelta(int256 packed) private pure returns (int128 amount0, int128 amount1) {
        assembly {
            amount0 := sar(128, packed)
            amount1 := signextend(15, packed)
        }
    }

    function _takeNativeFee(uint256 amountIn) private returns (uint256 netAmountIn) {
        uint256 feeAmount = (amountIn * feeBps) / _BPS_DENOMINATOR;
        if (feeAmount > 0) {
            (bool ok,) = treasury.call{ value: feeAmount }("");
            if (!ok) revert TransferFailed();
            emit FeeCollected(address(0), msg.sender, feeAmount);
        }
        netAmountIn = amountIn - feeAmount;
    }

    function _pullAndTakeFee(address token, uint256 amountIn) private returns (uint256 netAmountIn) {
        if (!IERC20FeeRouter(token).transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        uint256 feeAmount = (amountIn * feeBps) / _BPS_DENOMINATOR;
        if (feeAmount > 0) {
            if (!IERC20FeeRouter(token).transfer(treasury, feeAmount)) revert TransferFailed();
            emit FeeCollected(token, msg.sender, feeAmount);
        }
        netAmountIn = amountIn - feeAmount;
    }

    function _ensureAllowance(address token, uint256 amountIn) private {
        if (IERC20FeeRouter(token).allowance(address(this), swapVenue) < amountIn) {
            IERC20FeeRouter(token).approve(swapVenue, type(uint256).max);
        }
    }

    function _firstTokenFromPath(bytes calldata path) private pure returns (address token) {
        if (path.length < 20) revert InvalidPath();
        assembly {
            token := shr(96, calldataload(path.offset))
        }
    }

    receive() external payable {}
}
