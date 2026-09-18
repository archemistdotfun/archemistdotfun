// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IERC20V3USDCLockerV3 {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IV3USDCLaunchTokenLockerV3 {
    function launchFactory() external view returns (address);
}

interface INonfungiblePositionManagerV3USDCLockerV3 {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

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

/**
 * @title ArchemistV2USDCLockerV3
 * @notice Custodies Archemist Arc USDC/launch-token Uniswap v3 positions permanently, and splits LP
 *         fees between the creator's recipient and the protocol treasury.
 *
 * ## Administration
 *
 * The only privileged function on this contract is `upgradeToAndCall`, and its owner is a
 * `TimelockController` with a 48-hour minimum delay. There is no function that transfers a position
 * or a balance out, and the fee split is a constant.
 *
 * An upgradeable contract is more powerful than any single administrative function: an upgrade can do
 * anything at all. What makes that acceptable is that it is **slow and public**. Every upgrade is a
 * timelock operation that emits `CallScheduled` at least 48 hours before it can execute, so holders,
 * creators and LPs can see it coming and act. "Trustless" becomes "transparent and time-delayed", and
 * that trade is stated here rather than buried.
 *
 * The delay is also the entire protection against the single key that can propose (there is no multisig
 * on Arc yet). Moving the proposer role to a multisig later is a scheduled `grantRole`/`revokeRole` on
 * the timelock - no upgrade, no redeploy, no migration. See docs/UPGRADE_POLICY.md.
 *
 * ## Storage layout - APPEND ONLY
 *
 * This contract has no constructor state; everything below lives in the proxy and must never be
 * reordered or retyped by a future implementation. A new version declares this exact list, in this
 * exact order, before adding anything of its own, and consumes `__gap` as it grows.
 *
 *   slot  0  owner
 *   slot  1  pendingOwner
 *   slot  2  treasury
 *   slot  3  pairedToken
 *   slot  4  positionManager
 *   slot  5  launchFactory
 *   slot  6  protocolFeeBps
 *   slot  7  _lock
 *   slot  8  _initialized
 *   slot  9  positionForToken   (mapping)
 *   slot 10  tokenForPositionId (mapping)
 *   slot 11  claimable          (mapping)
 *   slot 12  totalLiability     (mapping)
 *   slot 13  allPositionTokens  (array)
 *   slots 14..45  __gap
 *
 * `EXPECTED_CHAIN_ID` is the one immutable: it is a chain constant, lives in the implementation's code
 * rather than in storage, and `upgradeToAndCall` refuses any implementation whose value differs - an
 * implementation compiled for another chain would otherwise pass every storage check while silently
 * re-pointing the system.
 */
contract ArchemistV2USDCLockerV3 {
    // Same constant as ArchemistProxy - exposed here only so off-chain tooling can read the current
    // implementation; the proxy's constructor and `upgradeToAndCall` are the only writers.
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint24 public constant POOL_FEE = 10_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice The LP-fee split, fixed in code: **creator 80%, treasury 20%**.
    ///
    /// Not a deploy argument, and not settable. Rather than an `initialize` parameter that a wrong
    /// deploy could get wrong, the number lives here. The only way it ever
    /// changes is a timelocked upgrade, which is public for 48 hours first.
    ///
    /// `protocolFeeBps` below is still storage, seeded from this constant, so the getter the indexer and
    /// frontend already read keeps working and a future version can migrate it with a reinitializer.
    uint256 public constant PROTOCOL_FEE_BPS = 2_000; // treasury 20%
    uint256 public constant CREATOR_FEE_BPS = 8_000; // creator 80% - always BPS_DENOMINATOR - PROTOCOL_FEE_BPS

    struct PositionInfo {
        uint256 positionId;
        address creatorFeeAdmin;
        address creatorFeeRecipient;
        address token0;
        address token1;
    }

    // ---- storage (append-only; see the layout table above) ----
    address public owner;
    address public pendingOwner;
    address public treasury;
    address public pairedToken;
    address public positionManager;
    address public launchFactory;
    uint256 public protocolFeeBps;
    uint256 private _lock;
    bool private _initialized;

    mapping(address => PositionInfo) public positionForToken;
    mapping(uint256 => address) public tokenForPositionId;
    mapping(address => mapping(address => uint256)) public claimable;
    mapping(address => uint256) public totalLiability;
    address[] public allPositionTokens;

    uint256[32] private __gap;

    uint256 public immutable EXPECTED_CHAIN_ID;

    event Initialized(address owner, address treasury, address pairedToken, address launchFactory, uint256 protocolFeeBps);
    event Upgraded(address indexed implementation);
    event OwnerTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event PositionRegistered(
        address indexed token,
        uint256 indexed positionId,
        address indexed creatorFeeRecipient,
        address creatorFeeAdmin,
        address token0,
        address token1
    );
    event FeesCollected(
        address indexed token,
        uint256 indexed positionId,
        uint256 totalToken0,
        uint256 totalToken1,
        uint256 creatorToken0,
        uint256 creatorToken1,
        uint256 protocolToken0,
        uint256 protocolToken1
    );
    event FeesClaimed(address indexed account, address indexed asset, address indexed to, uint256 amount);
    event CreatorFeeRecipientUpdated(
        address indexed token, address indexed previousRecipient, address indexed newRecipient
    );
    event CreatorFeeAdminUpdated(address indexed token, address indexed previousAdmin, address indexed newAdmin);

    error AlreadyInitialized();
    error InvalidAddress();
    error InvalidChain(uint256 actual, uint256 expected);
    error InvalidImplementation();
    error InvalidInfrastructure();
    error InvalidPosition();
    error AlreadyConfigured();
    error NotAuthorized();
    error NoClaimableBalance();
    error TransferFailed();
    error Reentrancy();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyLaunchFactory() {
        if (msg.sender != launchFactory || launchFactory == address(0)) revert NotAuthorized();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @dev Locks the logic contract itself, so `initialize` can only ever succeed through a proxy's
    /// delegatecall and this address can never be owned by whoever calls it first.
    constructor(uint256 expectedChainId_) {
        EXPECTED_CHAIN_ID = expectedChainId_;
        _initialized = true;
    }

    /// @notice Everything the old constructor did, plus the one thing `setLaunchFactory` used to do.
    /// Called exactly once, from the proxy's own constructor.
    /// @param launchFactory_ The factory PROXY's address. It does not exist yet when this runs - the
    ///        deploy script predicts it from the deployer's nonce - so it cannot be checked from this
    ///        side here. The factory's own `initialize` closes the loop by requiring
    ///        `locker.launchFactory() == address(this)`, which fails loudly if the prediction was wrong,
    ///        before any launch can happen.
    function initialize(
        address owner_,
        address treasury_,
        address pairedToken_,
        address positionManager_,
        address launchFactory_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (block.chainid != EXPECTED_CHAIN_ID) revert InvalidChain(block.chainid, EXPECTED_CHAIN_ID);
        if (
            owner_ == address(0) || treasury_ == address(0) || pairedToken_ == address(0)
                || positionManager_ == address(0) || launchFactory_ == address(0)
        ) revert InvalidAddress();
        if (
            pairedToken_.code.length == 0 || positionManager_.code.length == 0
                || IERC20V3USDCLockerV3(pairedToken_).decimals() != 6
        ) revert InvalidInfrastructure();
        _initialized = true;
        _lock = 1;
        owner = owner_;
        treasury = treasury_;
        pairedToken = pairedToken_;
        positionManager = positionManager_;
        launchFactory = launchFactory_;
        protocolFeeBps = PROTOCOL_FEE_BPS;
        emit Initialized(owner_, treasury_, pairedToken_, launchFactory_, PROTOCOL_FEE_BPS);
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
        return keccak256("archemist.kind.V2UsdcLockerV3");
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

    /// @notice UUPS upgrade entrypoint. The two checks are what stop a typo from disabling every locked
    /// position permanently: the target must have code, and it must actually be one of these
    /// implementations, compiled for this chain.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external onlyOwner {
        if (newImplementation.code.length == 0) revert InvalidImplementation();
        if (ArchemistV2USDCLockerV3(payable(newImplementation)).PROXY_VERSION() == 0) revert InvalidImplementation();
        if (ArchemistV2USDCLockerV3(payable(newImplementation)).EXPECTED_CHAIN_ID() != EXPECTED_CHAIN_ID) {
            revert InvalidImplementation();
        }
        // A target without this function reverts here rather than returning something wrong, which is
        // the safe direction: anything that is not this contract's own kind is refused.
        if (ArchemistV2USDCLockerV3(payable(newImplementation)).ARCHEMIST_KIND() != this.ARCHEMIST_KIND()) {
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

    // ---- positions and fees (behaviour unchanged from V2) ----

    function getTotalPositions() external view returns (uint256) {
        return allPositionTokens.length;
    }

    function registerPosition(address token, uint256 positionId, address creatorFeeAdmin, address creatorFeeRecipient)
        external
        onlyLaunchFactory
    {
        if (token == address(0) || creatorFeeAdmin == address(0) || creatorFeeRecipient == address(0)) {
            revert InvalidAddress();
        }
        if (positionForToken[token].positionId != 0 || tokenForPositionId[positionId] != address(0)) {
            revert AlreadyConfigured();
        }
        if (
            token.code.length == 0 || IV3USDCLaunchTokenLockerV3(token).launchFactory() != launchFactory
                || positionId == 0
        ) revert InvalidPosition();

        INonfungiblePositionManagerV3USDCLockerV3 manager =
            INonfungiblePositionManagerV3USDCLockerV3(positionManager);
        if (manager.ownerOf(positionId) != address(this)) revert InvalidPosition();
        (,, address token0, address token1, uint24 fee,,, uint128 liquidity,,,,) = manager.positions(positionId);
        if (
            fee != POOL_FEE || liquidity == 0
                || !((token0 == token && token1 == pairedToken) || (token0 == pairedToken && token1 == token))
        ) revert InvalidPosition();

        positionForToken[token] = PositionInfo({
            positionId: positionId,
            creatorFeeAdmin: creatorFeeAdmin,
            creatorFeeRecipient: creatorFeeRecipient,
            token0: token0,
            token1: token1
        });
        tokenForPositionId[positionId] = token;
        allPositionTokens.push(token);
        emit PositionRegistered(token, positionId, creatorFeeRecipient, creatorFeeAdmin, token0, token1);
    }

    /// @notice Permissionless. Collects the position's accrued LP fees and splits them.
    function collectFees(address token) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        PositionInfo storage info = positionForToken[token];
        if (info.positionId == 0) revert InvalidPosition();

        (amount0, amount1) = INonfungiblePositionManagerV3USDCLockerV3(positionManager).collect(
            INonfungiblePositionManagerV3USDCLockerV3.CollectParams({
                tokenId: info.positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint256 bps = protocolFeeBps;
        uint256 protocol0 = (amount0 * bps) / BPS_DENOMINATOR;
        uint256 protocol1 = (amount1 * bps) / BPS_DENOMINATOR;
        uint256 creator0 = amount0 - protocol0;
        uint256 creator1 = amount1 - protocol1;

        _credit(info.creatorFeeRecipient, info.token0, creator0);
        _credit(info.creatorFeeRecipient, info.token1, creator1);
        _pushOrCredit(treasury, info.token0, protocol0);
        _pushOrCredit(treasury, info.token1, protocol1);

        emit FeesCollected(token, info.positionId, amount0, amount1, creator0, creator1, protocol0, protocol1);
    }

    function updateCreatorFeeRecipient(address token, address newRecipient) external {
        if (newRecipient == address(0)) revert InvalidAddress();
        PositionInfo storage info = positionForToken[token];
        address previousRecipient = info.creatorFeeRecipient;
        if (msg.sender != info.creatorFeeAdmin || previousRecipient == address(0)) revert NotAuthorized();
        info.creatorFeeRecipient = newRecipient;
        emit CreatorFeeRecipientUpdated(token, previousRecipient, newRecipient);
    }

    function updateCreatorFeeAdmin(address token, address newAdmin) external {
        if (newAdmin == address(0)) revert InvalidAddress();
        PositionInfo storage info = positionForToken[token];
        address previousAdmin = info.creatorFeeAdmin;
        if (msg.sender != previousAdmin || previousAdmin == address(0)) revert NotAuthorized();
        info.creatorFeeAdmin = newAdmin;
        emit CreatorFeeAdminUpdated(token, previousAdmin, newAdmin);
    }

    function claim(address asset, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidAddress();
        amount = claimable[msg.sender][asset];
        if (amount == 0) revert NoClaimableBalance();
        claimable[msg.sender][asset] = 0;
        totalLiability[asset] -= amount;
        _transferAsset(asset, to, amount);
        emit FeesClaimed(msg.sender, asset, to, amount);
    }

    /// @dev The launch factory mints the position straight to this contract. Nothing else may send an
    /// LP NFT here, and there is no function that sends one back out - that is the lock.
    function onERC721Received(address operator, address from, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != positionManager || operator != launchFactory || from != address(0)) {
            revert InvalidPosition();
        }
        return this.onERC721Received.selector;
    }

    function _credit(address account, address asset, uint256 amount) internal {
        if (amount == 0) return;
        claimable[account][asset] += amount;
        totalLiability[asset] += amount;
    }

    /// @dev Pushes `amount` to `recipient` with a non-reverting low-level call. A failed treasury push
    /// must never revert fee collection for the creator, so on failure the amount falls back to the
    /// pull-claim pattern and the recipient can `claim()` it later.
    function _pushOrCredit(address recipient, address asset, uint256 amount) internal {
        if (amount == 0) return;
        bool success;
        if (asset == address(0)) {
            (success,) = recipient.call{ value: amount }("");
        } else {
            (bool called, bytes memory data) =
                asset.call(abi.encodeWithSelector(IERC20V3USDCLockerV3.transfer.selector, recipient, amount));
            success = called && (data.length == 0 || abi.decode(data, (bool)));
        }
        if (!success) {
            _credit(recipient, asset, amount);
        }
    }

    function _transferAsset(address asset, address to, uint256 amount) internal {
        if (asset == address(0)) {
            (bool sent,) = to.call{ value: amount }("");
            if (!sent) revert TransferFailed();
        } else {
            (bool success, bytes memory data) =
                asset.call(abi.encodeWithSelector(IERC20V3USDCLockerV3.transfer.selector, to, amount));
            if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }
    }

    receive() external payable { }
}
