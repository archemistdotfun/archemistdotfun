// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice Stand-ins for the Uniswap v3 periphery that the V2 launchpad talks to.
///
/// Settlement- and interface-accurate rather than a reimplementation of v3's math: the launchpad's own
/// guards and wiring are what is under test, not Uniswap's curve. Every check the factory performs at
/// `initialize` and at launch - `feeAmountTickSpacing`, `getPool` before and after creation, `slot0`
/// matching the requested price, `positionManager.factory()`, `ownerOf` - is answered honestly here, so
/// a test that passes has actually exercised them.

contract MockPairedToken {
    string public name = "Mock Linked USDC";
    string public symbol = "USDC";
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint160 public sqrtPriceX96;
    int24 public tick;

    constructor(address token0_, address token1_, uint24 fee_, uint160 sqrtPriceX96_, int24 tick_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }
}

contract MockV3Factory {
    mapping(bytes32 => address) private _pools;
    mapping(uint24 => int24) public feeAmountTickSpacing;

    constructor() {
        feeAmountTickSpacing[10_000] = 200;
        feeAmountTickSpacing[3_000] = 60;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) public view returns (address) {
        return _pools[_key(tokenA, tokenB, fee)];
    }

    function record(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function _key(address a, address b, uint24 fee) private pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(x, y, fee));
    }
}

interface IMintableForMock {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockPositionManager {
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

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    MockV3Factory public immutable v3Factory;
    address public constant WETH9 = address(0);
    /// @dev The manager stands in for the pool's inventory, so it is also where the router buys from.
    /// Approved at mint time because the creator buy happens inside `createToken`, with no window for
    /// the test to approve anything in between.
    address public router;

    uint256 public nextTokenId = 1;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => Position) private _positions;
    /// @dev What the next `collect` pays out, set by the test. Real fees accrue from trading; here they
    /// are placed directly, because what is under test is the locker's split and accounting.
    mapping(uint256 => uint256) public owed0;
    mapping(uint256 => uint256) public owed1;

    constructor(MockV3Factory v3Factory_) {
        v3Factory = v3Factory_;
    }

    function setRouter(address router_) external {
        router = router_;
    }

    function factory() external view returns (address) {
        return address(v3Factory);
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool)
    {
        pool = v3Factory.getPool(token0, token1, fee);
        if (pool != address(0)) return pool;
        pool = address(new MockV3Pool(token0, token1, fee, sqrtPriceX96, _tickOf(sqrtPriceX96)));
        v3Factory.record(token0, token1, fee, pool);
    }

    /// @dev The factory checks `slot0().tick` against the tick it asked for, so the pool has to report
    /// the right one. The real pool derives it from the price; here the test's price came from
    /// `getSqrtRatioAtTick`, so the mapping is recorded when the price is handed over.
    mapping(uint160 => int24) public tickForPrice;

    function setTickForPrice(uint160 sqrtPriceX96, int24 tick) external {
        tickForPrice[sqrtPriceX96] = tick;
    }

    function _tickOf(uint160 sqrtPriceX96) private view returns (int24) {
        return tickForPrice[sqrtPriceX96];
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        if (amount0 > 0) IMintableForMock(params.token0).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IMintableForMock(params.token1).transferFrom(msg.sender, address(this), amount1);

        if (router != address(0)) {
            if (amount0 > 0) IMintableForMock(params.token0).approve(router, type(uint256).max);
            if (amount1 > 0) IMintableForMock(params.token1).approve(router, type(uint256).max);
        }

        tokenId = nextTokenId++;
        ownerOf[tokenId] = params.recipient;
        liquidity = uint128(amount0 + amount1);
        _positions[tokenId] =
            Position(params.token0, params.token1, params.fee, params.tickLower, params.tickUpper, liquidity);
    }

    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Position memory p = _positions[tokenId];
        return (
            0,
            address(0),
            p.token0,
            p.token1,
            p.fee,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            0,
            0,
            uint128(owed0[tokenId]),
            uint128(owed1[tokenId])
        );
    }

    /// @dev Places fees on a position, funded by the test, so `collect` has something real to pay.
    function setOwed(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        owed0[tokenId] = amount0;
        owed1[tokenId] = amount1;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1) {
        require(msg.sender == ownerOf[params.tokenId], "not owner");
        Position memory p = _positions[params.tokenId];
        amount0 = owed0[params.tokenId];
        amount1 = owed1[params.tokenId];
        owed0[params.tokenId] = 0;
        owed1[params.tokenId] = 0;
        // The manager holds these, so it transfers rather than pulling.
        if (amount0 > 0) IMintableForMock(p.token0).transfer(params.recipient, amount0);
        if (amount1 > 0) IMintableForMock(p.token1).transfer(params.recipient, amount1);
    }
}

contract MockSwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    address public immutable factoryAddress;
    address public constant WETH9 = address(0);
    /// @dev Tokens out per token in, in bps of `amountIn`. 10_000 = 1:1.
    uint256 public rateBps = 10_000;
    address public tokenSource;

    constructor(address factory_) {
        factoryAddress = factory_;
    }

    function factory() external view returns (address) {
        return factoryAddress;
    }

    function setRate(uint256 rateBps_) external {
        rateBps = rateBps_;
    }

    /// @dev Where the output tokens come from. The launch mints its whole supply into the position
    /// manager, so that is the natural holder to buy from.
    function setTokenSource(address source) external {
        tokenSource = source;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        IMintableForMock(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn * rateBps / 10_000;
        require(amountOut >= params.amountOutMinimum, "Too little received");
        IMintableForMock(params.tokenOut).transferFrom(tokenSource, params.recipient, amountOut);
        require(IMintableForMock(params.tokenOut).balanceOf(params.recipient) >= amountOut, "no output");
    }
}
