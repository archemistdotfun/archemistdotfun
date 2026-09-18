// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @dev Exposes the four addresses ArchemistPairRegistry._probePair pays into, without needing a
/// fully wired ArchemistV4Launcher/Locker/Hook stack in every probe test.
contract MockProbeLauncher {
    address public immutable LOCKER;
    address public immutable TREASURY;
    address public immutable BUYBACK_VAULT;
    address public immutable HOLDER_REWARDS;

    constructor(address locker_, address treasury_, address vault_, address rewards_) {
        LOCKER = locker_;
        TREASURY = treasury_;
        BUYBACK_VAULT = vault_;
        HOLDER_REWARDS = rewards_;
    }
}

/// @dev Plain, well-behaved ERC-20 with a mint hook. The probe's happy path.
contract MockStandardQuote {
    string public constant name = "Mock Standard Quote";
    string public constant symbol = "mSTD";
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Transfers revert outright while paused, everywhere - the way OZ Pausable tokens behave.
/// paused() is also readable so the probe can flag the killswitch capability independently.
contract MockPausableToken is MockStandardQuote {
    bool public paused;

    error TokenPaused();

    constructor(uint8 decimals_) MockStandardQuote(decimals_) { }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (paused) revert TokenPaused();
        super._transfer(from, to, amount);
    }
}

/// @dev KYC/allowlist-gated token: transfers to a non-allowed recipient revert. Sender-side
/// balance is untouched by the revert, matching a real allowlist gate on the recipient.
contract MockAllowlistToken is MockStandardQuote {
    mapping(address => bool) public allowedRecipient;

    error RecipientNotAllowed(address to);

    constructor(uint8 decimals_) MockStandardQuote(decimals_) { }

    function setAllowed(address account, bool allowed_) external {
        allowedRecipient[account] = allowed_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (!allowedRecipient[to]) revert RecipientNotAllowed(to);
        super._transfer(from, to, amount);
    }
}

/// @dev Skims `feeBps` off every transfer; the fee is burned (not credited anywhere), so
/// received-by-recipient is strictly less than amount-sent, even for a 1 bps fee.
contract MockFeeOnTransferToken is MockStandardQuote {
    uint16 public immutable feeBps;

    constructor(uint8 decimals_, uint16 feeBps_) MockStandardQuote(decimals_) {
        feeBps = feeBps_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = amount * feeBps / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += (amount - fee);
    }
}

interface IReentrantTarget {
    function claim(address asset, address to) external returns (uint256);
    function collect(bytes32 poolId) external returns (uint256, uint256);
}

/// @dev A quote token that, on the leg of a transfer a victim contract doesn't control (i.e. the
/// outbound payout inside `ArchemistV4Locker.claim`), tries to re-enter a `nonReentrant`-guarded
/// function on that same victim contract. Used to prove the locker's shared reentrancy lock blocks a
/// malicious quote from draining funds via a second call while the first is still unwinding.
contract MockReentrantQuote is MockStandardQuote {
    address public attackTarget;
    address public attackAsset;
    address public attackTo;
    bytes32 public attackPoolId;
    bool public attackViaCollect;
    bool public attacking;
    bool private _reentered;

    constructor(uint8 decimals_) MockStandardQuote(decimals_) { }

    function armReentrantClaim(address target, address asset, address to) external {
        attackTarget = target;
        attackAsset = asset;
        attackTo = to;
        attackViaCollect = false;
        attacking = true;
    }

    function armReentrantCollect(address target, bytes32 poolId_) external {
        attackTarget = target;
        attackPoolId = poolId_;
        attackViaCollect = true;
        attacking = true;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        if (attacking && !_reentered) {
            _reentered = true;
            if (attackViaCollect) {
                IReentrantTarget(attackTarget).collect(attackPoolId);
            } else {
                IReentrantTarget(attackTarget).claim(attackAsset, attackTo);
            }
        }
    }
}

/// @dev transfer()/transferFrom() do the state change but declare no return value at all, so the
/// probe's low-level call sees zero-length returndata - the pre-EIP20-strict "old USDT" pattern.
contract MockNoReturnToken {
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Stands in for SwapRouter02 in the fee router's mixed v3->v4 route test. Pulls `tokenIn`
/// from the caller (the router, which approves it) and pays `tokenOut` to `recipient` at a fixed
/// rate, so the first hop is a real ERC20 movement without needing a deployed v3 pool. Only the
/// exactInputSingle shape is implemented - the mixed route never calls the path-based form.
contract MockSwapVenue {
    // tokenOut paid per 1e18 of tokenIn.
    uint256 public rate;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        MockStandardQuote(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = (params.amountIn * rate) / 1e18;
        require(amountOut >= params.amountOutMinimum, "venue slippage");
        MockStandardQuote(params.tokenOut).mint(params.recipient, amountOut);
    }
}
