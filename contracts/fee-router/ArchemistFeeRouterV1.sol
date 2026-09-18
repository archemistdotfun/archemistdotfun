// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IERC20FeeRouter {
    function allowance(address owner, address spender) external view returns (uint256);
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

/**
 * @title ArchemistFeeRouterV1
 * @notice UUPS-upgradeable wrapper in front of a SwapRouter02-compatible venue that
 *         skims a protocol fee (basis points) from every swap routed through the
 *         Archemist /token and /dex pages, before forwarding the remainder to the
 *         underlying venue.
 *
 * Upgradeable by design: fee %, treasury, and the swap venue itself are all mutable
 * by the owner, and the whole implementation can be swapped out (upgradeToAndCall)
 * to support a different venue interface later (Uniswap v2, v4, an aggregator, etc.)
 * without changing the address users approve and trade against.
 *
 * Storage layout is append-only across versions - see __gap. Any V2+ implementation
 * must declare owner/pendingOwner/treasury/swapVenue/feeBps/_lock/_initialized in
 * this exact order before adding new state.
 *
 * IMPORTANT: Research draft. It has not been audited and must not be deployed to
 * production before testnet validation and an independent security review.
 */
contract ArchemistFeeRouterV1 {
    // Same constant as ArchemistFeeRouterProxy - used only to expose the current
    // implementation address for off-chain tooling; the proxy is the sole writer.
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 private constant _MAX_FEE_BPS = 500; // 5% hard ceiling
    uint256 private constant _BPS_DENOMINATOR = 10_000;

    address public owner;
    address public pendingOwner;
    address public treasury;
    address public swapVenue;
    uint256 public feeBps;
    uint8 private _lock;
    bool private _initialized;

    uint256[45] private __gap;

    event Initialized(address owner, address treasury, address swapVenue, uint256 feeBps);
    event FeeBpsSet(uint256 feeBps);
    event TreasurySet(address treasury);
    event SwapVenueSet(address swapVenue);
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

    /// @dev Locks the logic contract itself so `initialize` can only ever succeed
    ///      through a proxy's delegatecall, never by calling this address directly.
    constructor() {
        _initialized = true;
    }

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

    // ---- admin ----

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

    /// @notice Repoints swaps at a different SwapRouter02-compatible venue without
    ///         an upgrade (e.g. a new Uniswap v3 fork deployment with the same ABI).
    function setSwapVenue(address swapVenue_) external onlyOwner {
        if (swapVenue_ == address(0)) revert InvalidAddress();
        swapVenue = swapVenue_;
        emit SwapVenueSet(swapVenue_);
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
    ///         function on the new implementation in the same transaction, e.g.
    ///         when a new venue interface needs extra setup state.
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

    // ---- swaps ----

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
}
