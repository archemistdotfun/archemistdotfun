// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/**
 * @title ArchemistV2USDCFactoryV3
 * @notice Archemist V2 launch factory: Arc linked-USDC token launches on Uniswap v3, paired with
 *         ArchemistV2USDCLockerV3.
 *
 * The entire fixed token supply is deposited into a one-sided Uniswap v3 position. The initial pool
 * price is placed exactly on the position boundary, so the position behaves like a virtual bonding
 * curve: buys add Arc linked USDC and remove launch tokens; sells reverse that movement. There is no
 * separate bonding phase and no graduation step. The position NFT is minted directly into the locker,
 * which owns fee accounting, creator administration and claims - and, since implementation v3, has no
 * way to give the position back to anyone.
 *
 * ## Administration
 *
 * There is no launch switch: the factory accepts launches from the moment it is deployed. The only
 * privileged function on this contract is `upgradeToAndCall`, and its owner is a
 * `TimelockController` with a 48-hour minimum delay. That is more power than any single administrative
 * function in absolute terms and less in practice, because it is slow and public: every upgrade emits
 * `CallScheduled` at least 48 hours before it can execute. The trade is stated plainly in
 * docs/UPGRADE_POLICY.md rather than buried.
 *
 * ## Storage layout - APPEND ONLY
 *
 * No constructor state: everything lives in the proxy. A future implementation must declare this exact
 * list, in this exact order, before adding state of its own, and consume `__gap` as it grows.
 *
 *   slot  0  _pairedToken            slot  7  pendingOwner
 *   slot  1  _uniswapV3Factory       slot  8  _lock
 *   slot  2  _positionManager        slot  9  _initialized
 *   slot  3  _swapRouter02           slot 10  launchInfoForToken (mapping)
 *   slot  4  _locker                 slot 11  allTokens          (array)
 *   slot  5  _treasury               slots 12..43  __gap
 *   slot  6  owner
 *
 * This table is informational. The authoritative reference is
 * `contracts/v2/storage-layout-reference/ArchemistV2USDCFactoryV3.layout.json`, the compiler's own
 * layout, enforced on every `npm run compile` by `check-storage-layout.mjs`; a future upgrade is checked
 * against that file, not against this comment.
 *
 * `EXPECTED_CHAIN_ID` is the sole immutable - a chain constant that lives in the implementation's code,
 * which is exactly why `upgradeToAndCall` re-checks it: an implementation compiled for another chain
 * would pass every storage check while silently re-pointing the system.
 *
 * ARCH itself is a token of the earlier V2 factory, not this one, and stays registered with that
 * factory's locker. See docs/INTERNAL_AUDIT.md.
 */

interface IERC20V3USDCLaunchV3 {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function allowance(address account, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IUniswapV3FactoryUSDCLaunchV3 {
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3PoolUSDCLaunchV3 {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface INonfungiblePositionManagerUSDCLaunchV3 {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function factory() external view returns (address);
    function WETH9() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface ISwapRouter02USDCLaunchV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

interface IArchemistV2USDCLockerLaunchV3 {
    function positionManager() external view returns (address);
    function pairedToken() external view returns (address);
    function treasury() external view returns (address);
    function launchFactory() external view returns (address);
    function registerPosition(
        address token,
        uint256 positionId,
        address creatorFeeAdmin,
        address creatorFeeRecipient
    ) external;
}

/// @dev Exact getSqrtRatioAtTick implementation from Uniswap v3-core TickMath.
library V3USDCLaunchTickMathV3 {
    int24 internal constant MAX_TICK = 887272;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(uint24(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}

contract V3USDCLaunchTokenV3 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public immutable launchFactory;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error InsufficientBalance();
    error InsufficientAllowance();
    error InvalidAddress();

    constructor(string memory name_, string memory symbol_, uint256 supply_) {
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert InvalidAddress();
        name = name_;
        symbol = symbol_;
        launchFactory = msg.sender;
        totalSupply = supply_;
        balanceOf[msg.sender] = supply_;
        emit Transfer(address(0), msg.sender, supply_);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidAddress();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

contract ArchemistV2USDCFactoryV3 {
    // Same constant as ArchemistProxy - exposed here only so off-chain tooling can read the current
    // implementation; the proxy's constructor and `upgradeToAndCall` are the only writers.
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant DEPLOY_FEE = 0.1 ether;
    uint24 public constant POOL_FEE = 10_000; // Uniswap v3 1% fee tier
    int24 public constant STARTING_TICK = -398_400;
    uint256 public constant NATIVE_TO_USDC_SCALE = 1e12;
    uint8 public constant PAIRED_TOKEN_DECIMALS = 6;

    // Mint-at-boundary rounding can leave a tiny amount of token dust.
    uint256 public constant MAX_TOKEN_DUST = 1e12; // 0.000001 token at 18 decimals
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Infrastructure links live in PROXY storage, not in the implementation's code, so that an
    // upgrade cannot silently re-point them (see the layout table in the contract header). They are
    // written once by `initialize` and have no setter. The SCREAMING_CASE getters below keep the exact
    // ABI the indexer, the backend and the frontend already read.
    address private _pairedToken;
    address private _uniswapV3Factory;
    address private _positionManager;
    address private _swapRouter02;
    address private _locker;
    address private _treasury;

    /// @dev The one immutable: a chain constant, and the one thing `upgradeToAndCall` re-checks,
    /// because an implementation compiled for another chain would pass every storage check.
    uint256 public immutable EXPECTED_CHAIN_ID;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    struct CreateParams {
        string name;
        string symbol;
        bytes32 salt;
        uint256 minTokensForCreatorBuy;
        address creatorFeeAdmin;
        address creatorFeeRecipient;
    }

    struct LaunchInfo {
        address creator;
        address pool;
        uint256 positionId;
        uint24 poolFee;
        int24 normalizedTick;
        int24 actualPoolTick;
        uint160 initialSqrtPriceX96;
        bool tokenIsToken0;
    }

    struct PositionConfig {
        bool tokenIsToken0;
        uint24 poolFee;
        int24 actualPoolTick;
        uint160 initialSqrtPriceX96;
        int24 minTick;
        int24 maxTick;
    }

    struct CreationResult {
        address token;
        address pool;
        uint256 positionId;
        uint256 tokensUsed;
        int24 actualPoolTick;
        uint160 initialSqrtPriceX96;
        bool tokenIsToken0;
    }

    address public owner;
    address public pendingOwner;
    uint256 private _lock;
    bool private _initialized;

    mapping(address => LaunchInfo) public launchInfoForToken;
    address[] public allTokens;

    uint256[32] private __gap;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed pool,
        uint256 positionId,
        address creatorFeeRecipient,
        uint24 poolFee,
        int24 normalizedTick,
        int24 actualPoolTick,
        uint160 initialSqrtPriceX96,
        uint256 tokensInPosition,
        uint256 creatorBuyNative,
        uint256 creatorBuyTokens
    );
    event PositionLocked(
        address indexed token,
        uint256 indexed positionId,
        address indexed locker,
        address creatorFeeRecipient
    );
    event DeployFeePaid(address indexed treasury, uint256 amount);
    event Initialized(address owner, address treasury, address locker);
    event Upgraded(address indexed implementation);
    event OwnerTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    error AlreadyInitialized();
    error InvalidImplementation();
    error InvalidAddress();
    error InvalidFeeTier();
    error InvalidTick();
    error InvalidInitialPrice();
    error InvalidPayment();
    error InvalidPosition();
    error InvalidInfrastructure();
    error InvalidChain(uint256 actual, uint256 expected);
    error PoolAlreadyExists();
    error ExcessTokenDust(uint256 dust);
    error NotAuthorized();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    /// @dev Locks the logic contract itself, so `initialize` can only ever succeed through a proxy's
    /// delegatecall and this address can never be owned by whoever calls it first.
    constructor(uint256 expectedChainId_) {
        EXPECTED_CHAIN_ID = expectedChainId_;
        _initialized = true;
    }

    /// @notice Everything the old constructor checked, moved verbatim - none of it may be lost in the
    /// move to a proxy, because each check rules out a specific mis-wiring that would only surface
    /// once a real creator had already paid to launch.
    /// @param locker_ The locker PROXY, already deployed and already initialized pointing at THIS
    ///        proxy's (nonce-predicted) address. The `launchFactory() == address(this)` check below is
    ///        what proves that prediction was right, before anything can depend on it.
    function initialize(
        address owner_,
        address treasury_,
        address pairedToken_,
        address v3Factory_,
        address positionManager_,
        address swapRouter02_,
        address locker_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (block.chainid != EXPECTED_CHAIN_ID) revert InvalidChain(block.chainid, EXPECTED_CHAIN_ID);
        if (
            owner_ == address(0) ||
            treasury_ == address(0) ||
            pairedToken_ == address(0) ||
            v3Factory_ == address(0) ||
            positionManager_ == address(0) ||
            swapRouter02_ == address(0) ||
            locker_ == address(0)
        ) revert InvalidAddress();
        if (
            pairedToken_.code.length == 0 ||
            v3Factory_.code.length == 0 ||
            positionManager_.code.length == 0 ||
            swapRouter02_.code.length == 0 ||
            locker_.code.length == 0
        ) revert InvalidInfrastructure();
        if (
            IERC20V3USDCLaunchV3(pairedToken_).decimals() != PAIRED_TOKEN_DECIMALS ||
            IUniswapV3FactoryUSDCLaunchV3(v3Factory_).feeAmountTickSpacing(POOL_FEE) != 200
        ) {
            revert InvalidInfrastructure();
        }
        _validateNormalizedTick(STARTING_TICK, 200);
        if (
            INonfungiblePositionManagerUSDCLaunchV3(positionManager_).factory() != v3Factory_
                || ISwapRouter02USDCLaunchV3(swapRouter02_).factory() != v3Factory_
                || IArchemistV2USDCLockerLaunchV3(locker_).positionManager() != positionManager_
                || IArchemistV2USDCLockerLaunchV3(locker_).pairedToken() != pairedToken_
                || IArchemistV2USDCLockerLaunchV3(locker_).treasury() != treasury_
                // The loop closes here: the locker was initialized with a PREDICTED address for this
                // proxy. If the prediction was wrong, this reverts now, at deploy time, rather than
                // leaving a factory whose launches would mint LP NFTs into a locker that refuses them.
                || IArchemistV2USDCLockerLaunchV3(locker_).launchFactory() != address(this)
        ) revert InvalidInfrastructure();

        _initialized = true;
        _lock = 1;
        owner = owner_;
        _treasury = treasury_;
        _pairedToken = pairedToken_;
        _uniswapV3Factory = v3Factory_;
        _positionManager = positionManager_;
        _swapRouter02 = swapRouter02_;
        _locker = locker_;
        emit Initialized(owner_, treasury_, locker_);
    }

    /// @notice Lets off-chain tooling, and `upgradeToAndCall` itself, tell what it is looking at.
    function PROXY_VERSION() external pure returns (uint256) {
        return 3;
    }

    /// @notice What kind of contract this is. Distinct from the other implementation in this pair, and
    /// checked on every upgrade so this proxy can only ever be pointed at another version of *itself*.
    ///
    /// `PROXY_VERSION() != 0` and the chain id are both satisfied by the factory *and* the locker, so
    /// without this tag `upgradeToAndCall(lockerProxy, factoryImpl)` succeeds: the proxy comes back
    /// speaking the wrong ABI over the right storage, and every locked position becomes unreachable.
    /// The two proxies are deployed seconds apart by one script and upgraded by copy-pasted commands,
    /// which makes swapping them the most plausible operator typo there is - and typo protection is the
    /// whole stated purpose of the checks in `upgradeToAndCall`.
    function ARCHEMIST_KIND() external pure returns (bytes32) {
        return keccak256("archemist.kind.V2UsdcFactoryV3");
    }

    // ---- infrastructure getters (same names and ABI the indexer and frontend already read) ----

    function PAIRED_TOKEN() external view returns (address) {
        return _pairedToken;
    }

    function UNISWAP_V3_FACTORY() external view returns (address) {
        return _uniswapV3Factory;
    }

    function POSITION_MANAGER() external view returns (address) {
        return _positionManager;
    }

    function SWAP_ROUTER_02() external view returns (address) {
        return _swapRouter02;
    }

    function LOCKER() external view returns (address) {
        return _locker;
    }

    function TREASURY() external view returns (address) {
        return _treasury;
    }

    // ---- the only privileged surface ----

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

    /// @notice UUPS upgrade entrypoint, and the ONLY thing the owner can do. The two checks are what
    /// stop a typo from permanently disabling every future launch: the target must have code, and it
    /// must actually be one of these implementations, compiled for this chain.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external onlyOwner {
        if (newImplementation.code.length == 0) revert InvalidImplementation();
        if (ArchemistV2USDCFactoryV3(payable(newImplementation)).PROXY_VERSION() == 0) {
            revert InvalidImplementation();
        }
        if (ArchemistV2USDCFactoryV3(payable(newImplementation)).EXPECTED_CHAIN_ID() != EXPECTED_CHAIN_ID) {
            revert InvalidImplementation();
        }
        // A target without this function reverts here rather than returning something wrong, which is
        // the safe direction: anything that is not this contract's own kind is refused.
        if (ArchemistV2USDCFactoryV3(payable(newImplementation)).ARCHEMIST_KIND() != this.ARCHEMIST_KIND()) {
            revert InvalidImplementation();
        }
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

    function getTotalTokens() external view returns (uint256) {
        return allTokens.length;
    }

    function getTokenAtIndex(uint256 index) external view returns (address) {
        return allTokens[index];
    }

    function computeTokenAddress(
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        address creator
    ) public view returns (address token) {
        if (creator == address(0)) revert InvalidAddress();
        bytes32 actualSalt = keccak256(abi.encodePacked(creator, salt));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(V3USDCLaunchTokenV3).creationCode, abi.encode(name, symbol, INITIAL_SUPPLY))
        );
        token = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), actualSalt, initCodeHash
        )))));
    }

    function previewPosition(
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        address creator
    ) external view returns (
        address token,
        bool tokenIsToken0,
        int24 actualPoolTick,
        uint160 initialSqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) {
        int24 tickSpacing = IUniswapV3FactoryUSDCLaunchV3(_uniswapV3Factory).feeAmountTickSpacing(POOL_FEE);
        token = computeTokenAddress(salt, name, symbol, creator);
        tokenIsToken0 = token < _pairedToken;
        actualPoolTick = tokenIsToken0 ? STARTING_TICK : -STARTING_TICK;
        initialSqrtPriceX96 = V3USDCLaunchTickMathV3.getSqrtRatioAtTick(actualPoolTick);
        tickLower = tokenIsToken0 ? actualPoolTick : _minUsableTick(tickSpacing);
        tickUpper = tokenIsToken0 ? _maxUsableTick(tickSpacing) : actualPoolTick;
    }

    function createToken(CreateParams calldata p)
        external
        payable
        nonReentrant
        returns (address tokenAddress, address pool, uint256 positionId)
    {
        // There is no launch switch. The only link worth re-checking on every launch is the one that decides
        // where the LP NFT ends up.
        if (IArchemistV2USDCLockerLaunchV3(_locker).launchFactory() != address(this)) {
            revert InvalidInfrastructure();
        }
        if (
            msg.value < DEPLOY_FEE ||
            msg.value % NATIVE_TO_USDC_SCALE != 0
        ) revert InvalidPayment();
        if (p.creatorFeeAdmin == address(0) || p.creatorFeeRecipient == address(0)) {
            revert InvalidAddress();
        }
        int24 tickSpacing = IUniswapV3FactoryUSDCLaunchV3(_uniswapV3Factory).feeAmountTickSpacing(POOL_FEE);
        if (tickSpacing <= 0) revert InvalidFeeTier();

        int24 minTick = _minUsableTick(tickSpacing);
        int24 maxTick = _maxUsableTick(tickSpacing);

        bytes32 actualSalt = keccak256(abi.encodePacked(msg.sender, p.salt));
        V3USDCLaunchTokenV3 token = new V3USDCLaunchTokenV3{salt: actualSalt}(p.name, p.symbol, INITIAL_SUPPLY);
        tokenAddress = address(token);

        bool tokenIsToken0 = tokenAddress < _pairedToken;
        int24 actualPoolTick = tokenIsToken0
            ? STARTING_TICK
            : -STARTING_TICK;
        uint160 initialSqrtPriceX96 = V3USDCLaunchTickMathV3.getSqrtRatioAtTick(actualPoolTick);
        uint256 tokensUsed;
        (pool, positionId, tokensUsed) = _createPoolAndPosition(
            token,
            PositionConfig({
                tokenIsToken0: tokenIsToken0,
                poolFee: POOL_FEE,
                actualPoolTick: actualPoolTick,
                initialSqrtPriceX96: initialSqrtPriceX96,
                minTick: minTick,
                maxTick: maxTick
            })
        );

        _finalizeLaunch(
            p,
            CreationResult({
                token: tokenAddress,
                pool: pool,
                positionId: positionId,
                tokensUsed: tokensUsed,
                actualPoolTick: actualPoolTick,
                initialSqrtPriceX96: initialSqrtPriceX96,
                tokenIsToken0: tokenIsToken0
            })
        );
    }

    function _finalizeLaunch(CreateParams calldata p, CreationResult memory result) internal {
        launchInfoForToken[result.token] = LaunchInfo({
            creator: msg.sender,
            pool: result.pool,
            positionId: result.positionId,
            poolFee: POOL_FEE,
            normalizedTick: STARTING_TICK,
            actualPoolTick: result.actualPoolTick,
            initialSqrtPriceX96: result.initialSqrtPriceX96,
            tokenIsToken0: result.tokenIsToken0
        });
        allTokens.push(result.token);
        IArchemistV2USDCLockerLaunchV3(_locker).registerPosition(
            result.token,
            result.positionId,
            p.creatorFeeAdmin,
            p.creatorFeeRecipient
        );

        (bool deployFeeSent,) = _treasury.call{value: DEPLOY_FEE}("");
        if (!deployFeeSent) revert TransferFailed();
        emit DeployFeePaid(_treasury, DEPLOY_FEE);

        uint256 creatorBuyNative = msg.value - DEPLOY_FEE;
        uint256 creatorBuyTokens = _executeCreatorBuy(
            result.token,
            POOL_FEE,
            creatorBuyNative,
            p.minTokensForCreatorBuy,
            msg.sender
        );

        emit TokenCreated(
            result.token,
            msg.sender,
            result.pool,
            result.positionId,
            p.creatorFeeRecipient,
            POOL_FEE,
            STARTING_TICK,
            result.actualPoolTick,
            result.initialSqrtPriceX96,
            result.tokensUsed,
            creatorBuyNative,
            creatorBuyTokens
        );
        emit PositionLocked(result.token, result.positionId, _locker, p.creatorFeeRecipient);
    }

    function _executeCreatorBuy(
        address token,
        uint24 poolFee,
        uint256 nativeAmount,
        uint256 minTokens,
        address recipient
    ) internal returns (uint256 tokensBought) {
        if (nativeAmount == 0) {
            if (minTokens != 0) revert InvalidPayment();
            return 0;
        }

        uint256 pairedAmount = nativeAmount / NATIVE_TO_USDC_SCALE;
        IERC20V3USDCLaunchV3 pairedToken = IERC20V3USDCLaunchV3(_pairedToken);
        if (pairedToken.balanceOf(address(this)) < pairedAmount) revert InvalidPayment();
        // Snapshot AFTER that check, so `pairedBefore >= pairedAmount` holds and the subtraction in the
        // post-swap assertion cannot underflow. These are what the leftover check compares against.
        uint256 pairedBefore = pairedToken.balanceOf(address(this));
        uint256 nativeBefore = address(this).balance;
        if (!pairedToken.approve(_swapRouter02, 0)) revert TransferFailed();
        if (!pairedToken.approve(_swapRouter02, pairedAmount)) revert TransferFailed();

        tokensBought = ISwapRouter02USDCLaunchV3(_swapRouter02).exactInputSingle(
            ISwapRouter02USDCLaunchV3.ExactInputSingleParams({
                tokenIn: _pairedToken,
                tokenOut: token,
                fee: poolFee,
                recipient: recipient,
                amountIn: pairedAmount,
                amountOutMinimum: minTokens,
                sqrtPriceLimitX96: 0
            })
        );

        if (!pairedToken.approve(_swapRouter02, 0)) revert TransferFailed();
        // Every unit this call brought in must have left in the swap - but measured against what was
        // here beforehand, not against zero.
        //
        // The absolute version (`!= 0`) was a griefing vector rather than a safety check. This factory
        // has no sweep and no owner, so anything sitting in it is permanent; on Arc, native and the
        // linked USDC at 0x3600 are the same balance viewed at two decimal scales, so **one wei** sent
        // to the proxy by anybody would have made every `createToken` with a creator buy revert
        // `InvalidPayment` forever, recoverable only by a 48-hour timelocked upgrade.
        //
        // Relative comparison keeps exactly the property that was wanted - the whole `pairedAmount` this
        // call brought in has left - while a donation just sits there inertly, which is all it should
        // ever have been able to do. The native leg is a non-increase check: on Arc it is the same
        // balance as the paired token seen at another scale, so the line above already covers it, and
        // on any chain where it is not, this still catches value arriving and staying.
        if (pairedToken.balanceOf(address(this)) > pairedBefore - pairedAmount || address(this).balance > nativeBefore)
        {
            revert InvalidPayment();
        }
    }

    function _createPoolAndPosition(
        V3USDCLaunchTokenV3 token,
        PositionConfig memory config
    ) internal returns (address pool, uint256 positionId, uint256 tokensUsed) {
        address tokenAddress = address(token);
        address token0 = config.tokenIsToken0 ? tokenAddress : _pairedToken;
        address token1 = config.tokenIsToken0 ? _pairedToken : tokenAddress;
        IUniswapV3FactoryUSDCLaunchV3 v3Factory = IUniswapV3FactoryUSDCLaunchV3(_uniswapV3Factory);

        // A predictable CREATE2 address lets an attacker pre-create/initialize this pool.
        // Never accept an existing pool, even if its current price happens to match.
        if (v3Factory.getPool(token0, token1, config.poolFee) != address(0)) {
            revert PoolAlreadyExists();
        }

        INonfungiblePositionManagerUSDCLaunchV3 manager = INonfungiblePositionManagerUSDCLaunchV3(_positionManager);
        pool = manager.createAndInitializePoolIfNecessary(
            token0,
            token1,
            config.poolFee,
            config.initialSqrtPriceX96
        );

        address canonicalPool = v3Factory.getPool(
            token0,
            token1,
            config.poolFee
        );
        if (pool == address(0) || pool != canonicalPool) revert InvalidPosition();

        (uint160 actualSqrtPriceX96, int24 actualTick,,,,,) = IUniswapV3PoolUSDCLaunchV3(pool).slot0();
        if (actualSqrtPriceX96 != config.initialSqrtPriceX96 || actualTick != config.actualPoolTick) {
            revert InvalidInitialPrice();
        }

        INonfungiblePositionManagerUSDCLaunchV3.MintParams memory params;
        params.token0 = token0;
        params.token1 = token1;
        params.fee = config.poolFee;
        params.tickLower = config.tokenIsToken0 ? config.actualPoolTick : config.minTick;
        params.tickUpper = config.tokenIsToken0 ? config.maxTick : config.actualPoolTick;
        params.amount0Desired = config.tokenIsToken0 ? INITIAL_SUPPLY : 0;
        params.amount1Desired = config.tokenIsToken0 ? 0 : INITIAL_SUPPLY;
        params.amount0Min = 0;
        params.amount1Min = 0;
        params.recipient = _locker;
        params.deadline = block.timestamp;

        (positionId, tokensUsed) = _mintOneSidedPosition(token, params, config.tokenIsToken0);
    }

    function _mintOneSidedPosition(
        V3USDCLaunchTokenV3 token,
        INonfungiblePositionManagerUSDCLaunchV3.MintParams memory params,
        bool tokenIsToken0
    ) internal returns (uint256 positionId, uint256 tokensUsed) {
        if (!token.approve(_positionManager, INITIAL_SUPPLY)) revert TransferFailed();

        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        INonfungiblePositionManagerUSDCLaunchV3 manager = INonfungiblePositionManagerUSDCLaunchV3(_positionManager);
        (positionId, liquidity, amount0, amount1) = manager.mint(params);
        if (liquidity == 0 || positionId == 0) revert InvalidPosition();
        if ((tokenIsToken0 && amount1 != 0) || (!tokenIsToken0 && amount0 != 0)) {
            revert InvalidPosition();
        }
        _validateMintedPosition(manager, positionId, params, liquidity);

        tokensUsed = tokenIsToken0 ? amount0 : amount1;
        uint256 dust = INITIAL_SUPPLY - tokensUsed;
        if (dust > MAX_TOKEN_DUST) revert ExcessTokenDust(dust);

        if (!token.approve(_positionManager, 0)) revert TransferFailed();
        if (dust > 0 && !token.transfer(DEAD, dust)) revert TransferFailed();
    }

    function _validateMintedPosition(
        INonfungiblePositionManagerUSDCLaunchV3 manager,
        uint256 positionId,
        INonfungiblePositionManagerUSDCLaunchV3.MintParams memory params,
        uint128 expectedLiquidity
    ) internal view {
        if (manager.ownerOf(positionId) != _locker) revert InvalidPosition();
        (
            ,,
            address positionToken0,
            address positionToken1,
            uint24 positionFee,
            int24 positionTickLower,
            int24 positionTickUpper,
            uint128 positionLiquidity,,,,
        ) = manager.positions(positionId);
        if (
            positionToken0 != params.token0 ||
            positionToken1 != params.token1 ||
            positionFee != params.fee ||
            positionTickLower != params.tickLower ||
            positionTickUpper != params.tickUpper ||
            positionLiquidity != expectedLiquidity
        ) revert InvalidPosition();
    }

    function _validateNormalizedTick(int24 normalizedTick, int24 tickSpacing) internal pure {
        int24 minTick = _minUsableTick(tickSpacing);
        if (
            tickSpacing <= 0 ||
            normalizedTick >= 0 ||
            normalizedTick <= minTick ||
            normalizedTick % tickSpacing != 0
        ) revert InvalidTick();
    }

    function _minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (MIN_TICK / tickSpacing) * tickSpacing;
    }

    function _maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (MAX_TICK / tickSpacing) * tickSpacing;
    }

    receive() external payable {
        if (msg.sender != _swapRouter02) revert InvalidPayment();
    }
}
