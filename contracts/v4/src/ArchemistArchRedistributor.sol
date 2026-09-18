// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IArchLocker {
    function claimable(address account, address asset) external view returns (uint256);
    function claim(address asset, address to) external returns (uint256);
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1);
}

interface IERC20Redistributor {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Redistributes the ARCH side of the ARCH/USDC launch-pool fees to ARCH holders, in
/// proportion to what they hold. One asset in, one asset out: ARCH. The USDC side of the same fee
/// stream is never distributed - it is swept to `usdcSink` untouched.
///
/// Why this shape, and not the continuous accrual of ArchemistHolderRewards:
///
///   1. ARCH is a plain ERC-20 from the V2 launchpad. It has no transfer hook, so this contract can
///      never be told that a balance moved. Continuous, per-interval accrual is therefore impossible
///      for ARCH - and the naive substitute (multiply a holder's CURRENT `balanceOf` by the reward
///      accrued since they last claimed) is not a simplification but a hole: buy a large balance a
///      block before claiming and you harvest a period you did not hold through.
///
///   2. So entitlement is measured off-chain, at a stated block, and committed on-chain as one
///      Merkle root per epoch. The snapshot is reproducible by anyone: `snapshotBlock` is recorded
///      with the root, balances at a past block are public, and `uri` points at the full leaf list.
///      A root that does not match the published list is visible to everyone holding the list.
///
///   3. Claims are pull OR push with the same function. `claim` pays the account named in the leaf,
///      never the caller, so a keeper can submit proofs on everyone's behalf (the "airdrop" run) and
///      a holder who would rather pay their own gas can submit their own. `claimBatch` is the keeper
///      path: a recipient that cannot receive is skipped with the entitlement intact, and never
///      blocks the rest of the batch.
///
/// What the owner can and cannot do. The owner (and a separate `publisher` key, so the schedule can
/// run from a hot wallet) can publish epochs and can revoke an epoch that nobody has claimed from
/// yet - the recovery path for a bad root. The owner CANNOT withdraw ARCH. There is no function that
/// moves ARCH out of this contract other than a valid Merkle claim; `sweepToken` rejects ARCH
/// explicitly. ARCH that arrives and is never put into an epoch simply waits for the next one, and
/// an entitlement nobody claims stays claimable forever.
///
/// Accepted limitation: a root commits a fixed list. An address that acquires ARCH after
/// `snapshotBlock` earns from the NEXT epoch, not this one. That is the price of measuring holdings
/// without a transfer hook, and it is the same tradeoff every snapshot airdrop makes.
contract ArchemistArchRedistributor {
    /// @dev Gas allowed to one recipient on the batch path. Bounds what a single hostile or merely
    /// expensive recipient can burn out of a batch the keeper is paying for. A contract that
    /// legitimately needs more can always have its own claim submitted on its own.
    uint256 private constant PUSH_GAS_STIPEND = 50_000;

    /// @notice The token being distributed, and the token holdings are measured in. Same address.
    address public immutable ARCH;
    /// @notice The quote side of the launch pool. Never distributed - only ever swept to `usdcSink`.
    address public immutable USDC;
    /// @notice ArchemistV2LockerV2 custodying the ARCH LP position. Credits fees as `claimable`.
    address public immutable LOCKER;
    uint256 public immutable EXPECTED_CHAIN_ID;

    address public owner;
    address public pendingOwner;
    /// @notice May publish and revoke epochs, alongside the owner. Meant for the snapshot keeper.
    address public publisher;
    /// @notice Where the USDC side of the fees - and any other stray token - goes.
    address public usdcSink;

    struct Epoch {
        bytes32 root;
        /// @dev Total ARCH this epoch may ever pay out. Reserved from the balance at publish time.
        uint128 total;
        uint128 claimed;
        /// @dev Block the balances behind `root` were read at. Makes the root reproducible.
        uint64 snapshotBlock;
        uint64 publishedAt;
        bool revoked;
        /// @dev Where the full leaf list lives, so anyone can recompute the root.
        string uri;
    }

    Epoch[] private _epochs;

    /// @notice epoch => holder => already paid.
    mapping(uint256 => mapping(address => bool)) public isClaimed;

    /// @notice ARCH committed to published epochs and not yet claimed. Never distributable again.
    uint256 public reserved;

    event EpochPublished(uint256 indexed epochId, bytes32 root, uint256 total, uint64 snapshotBlock, string uri);
    event EpochRevoked(uint256 indexed epochId, bytes32 root, uint256 total);
    event Claimed(uint256 indexed epochId, address indexed account, uint256 amount);
    event Pulled(uint256 archPulled, uint256 usdcSwept);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event PublisherSet(address indexed previousPublisher, address indexed newPublisher);
    event UsdcSinkSet(address indexed previousSink, address indexed newSink);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPublisher();
    error InvalidAddress();
    error InvalidChain(uint256 actual, uint256 expected);
    error InvalidEpoch();
    error InvalidProof();
    error AlreadyClaimed();
    error EpochRevokedError();
    error EpochStarted();
    error EpochOverdrawn();
    error NothingToDistribute();
    error InsufficientUnallocated(uint256 requested, uint256 available);
    error AmountTooLarge();
    error TransferFailed();
    error ArchNotSweepable();
    error LengthMismatch();
    error Reentrancy();

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyPublisher() {
        if (msg.sender != publisher && msg.sender != owner) revert NotPublisher();
        _;
    }

    constructor(
        address arch_,
        address usdc_,
        address locker_,
        address owner_,
        address publisher_,
        address usdcSink_,
        uint256 expectedChainId_
    ) {
        if (block.chainid != expectedChainId_) revert InvalidChain(block.chainid, expectedChainId_);
        if (
            arch_ == address(0) || usdc_ == address(0) || locker_ == address(0) || owner_ == address(0)
                || publisher_ == address(0) || usdcSink_ == address(0)
        ) revert InvalidAddress();
        if (arch_ == usdc_) revert InvalidAddress();
        if (arch_.code.length == 0 || locker_.code.length == 0) revert InvalidAddress();
        ARCH = arch_;
        USDC = usdc_;
        LOCKER = locker_;
        owner = owner_;
        publisher = publisher_;
        usdcSink = usdcSink_;
        EXPECTED_CHAIN_ID = expectedChainId_;
        emit OwnershipTransferred(address(0), owner_);
        emit PublisherSet(address(0), publisher_);
        emit UsdcSinkSet(address(0), usdcSink_);
    }

    // --- fee intake -------------------------------------------------------------------------

    /// @notice Permissionless. Collects this launch's LP fees, materializes the ARCH the locker owes
    /// this contract, and sends the USDC side straight on to `usdcSink`. Safe to call at any time and
    /// by anyone; a keeper runs it before each snapshot.
    /// @dev `collectFees` is wrapped: it reverts when there is nothing to collect or when the locker
    /// no longer holds the position, and neither should stop the ARCH already credited from being pulled in.
    function pull() public nonReentrant returns (uint256 archPulled, uint256 usdcSwept) {
        try IArchLocker(LOCKER).collectFees(ARCH) { } catch { }

        if (IArchLocker(LOCKER).claimable(address(this), ARCH) != 0) {
            archPulled = IArchLocker(LOCKER).claim(ARCH, address(this));
        }
        usdcSwept = _sweepUsdc();
        emit Pulled(archPulled, usdcSwept);
    }

    /// @notice ARCH held here that is not committed to a published epoch - what the next epoch can
    /// distribute.
    function unallocated() public view returns (uint256) {
        uint256 balance = IERC20Redistributor(ARCH).balanceOf(address(this));
        uint256 committed = reserved;
        return balance > committed ? balance - committed : 0;
    }

    // --- epochs -----------------------------------------------------------------------------

    /// @notice Commits one snapshot's payouts. `total` is reserved out of the uncommitted ARCH
    /// balance immediately, so two epochs can never promise the same token twice.
    /// @param root Merkle root over leaves `keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))))`.
    /// @param total Sum of every leaf amount under `root`.
    /// @param snapshotBlock The block balances were read at. Recorded so the root is reproducible.
    /// @param uri Where the full leaf list is published.
    function publishEpoch(bytes32 root, uint256 total, uint64 snapshotBlock, string calldata uri)
        external
        onlyPublisher
        returns (uint256 epochId)
    {
        if (root == bytes32(0)) revert InvalidEpoch();
        if (total == 0) revert NothingToDistribute();
        if (total > type(uint128).max) revert AmountTooLarge();
        if (snapshotBlock == 0 || snapshotBlock > block.number) revert InvalidEpoch();

        uint256 available = unallocated();
        if (total > available) revert InsufficientUnallocated(total, available);

        epochId = _epochs.length;
        _epochs.push(
            Epoch({
                root: root,
                // casting to 'uint128' is safe because the bound above rejects anything larger
                // forge-lint: disable-next-line(unsafe-typecast)
                total: uint128(total),
                claimed: 0,
                snapshotBlock: snapshotBlock,
                publishedAt: uint64(block.timestamp),
                revoked: false,
                uri: uri
            })
        );
        reserved += total;
        emit EpochPublished(epochId, root, total, snapshotBlock, uri);
    }

    /// @notice Cancels an epoch and returns its ARCH to the uncommitted balance. The recovery path
    /// for a root published against the wrong list.
    /// @dev Only before anyone has claimed from it. Once one holder has been paid under a root, the
    /// rest of that root is theirs too - nobody gets to take it back halfway.
    function revokeEpoch(uint256 epochId) external onlyPublisher {
        if (epochId >= _epochs.length) revert InvalidEpoch();
        Epoch storage e = _epochs[epochId];
        if (e.revoked) revert EpochRevokedError();
        if (e.claimed != 0) revert EpochStarted();
        e.revoked = true;
        reserved -= e.total;
        emit EpochRevoked(epochId, e.root, e.total);
    }

    // --- claiming ---------------------------------------------------------------------------

    /// @notice Pays `account` its entitlement for `epochId`. Callable by anyone: the leaf fixes the
    /// recipient, so a keeper submitting proofs cannot redirect a single token.
    function claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (!_verify(epochId, account, amount, proof)) revert InvalidProof();
        if (isClaimed[epochId][account]) revert AlreadyClaimed();
        Epoch storage e = _epochs[epochId];
        if (e.revoked) revert EpochRevokedError();
        // Bounds a mis-built root to its own reservation: an epoch can never pay out more than it
        // reserved, so it can never reach into another epoch's ARCH.
        if (uint256(e.claimed) + amount > e.total) revert EpochOverdrawn();

        isClaimed[epochId][account] = true;
        // casting to 'uint128' is safe because `amount` cannot exceed `e.total`, itself a uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        e.claimed += uint128(amount);
        reserved -= amount;

        if (!_payOut(account, amount, 0)) revert TransferFailed();
        emit Claimed(epochId, account, amount);
        return amount;
    }

    /// @notice The keeper path: pays many holders in one transaction, so holders receive without
    /// having to act. An entry that is already claimed, proves nothing, or cannot be received is
    /// skipped with the entitlement intact - it never takes the rest of the batch down.
    function claimBatch(
        uint256[] calldata epochIds,
        address[] calldata accounts,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant returns (uint256 totalPaid) {
        uint256 n = accounts.length;
        if (epochIds.length != n || amounts.length != n || proofs.length != n) revert LengthMismatch();

        for (uint256 i; i < n; ++i) {
            uint256 epochId = epochIds[i];
            address account = accounts[i];
            uint256 amount = amounts[i];

            if (isClaimed[epochId][account]) continue;
            if (!_verify(epochId, account, amount, proofs[i])) continue;
            Epoch storage e = _epochs[epochId];
            if (e.revoked) continue;
            if (uint256(e.claimed) + amount > e.total) continue;

            isClaimed[epochId][account] = true;
            // casting to 'uint128' is safe because `amount` cannot exceed `e.total`, a uint128
            // forge-lint: disable-next-line(unsafe-typecast)
            e.claimed += uint128(amount);
            reserved -= amount;

            if (_payOut(account, amount, PUSH_GAS_STIPEND)) {
                totalPaid += amount;
                emit Claimed(epochId, account, amount);
            } else {
                // Hand it straight back. Nothing is lost: the holder can still be paid later, with
                // full gas, through `claim`.
                isClaimed[epochId][account] = false;
                // forge-lint: disable-next-line(unsafe-typecast)
                e.claimed -= uint128(amount);
                reserved += amount;
            }
        }
    }

    /// @notice What `account` can still collect for `epochId`, given a proof. Zero once claimed, for
    /// a revoked epoch, or if the proof does not check out.
    function claimableAmount(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof)
        external
        view
        returns (uint256)
    {
        if (isClaimed[epochId][account]) return 0;
        if (!_verify(epochId, account, amount, proof)) return 0;
        Epoch storage e = _epochs[epochId];
        if (e.revoked) return 0;
        if (uint256(e.claimed) + amount > e.total) return 0;
        return amount;
    }

    // --- sweeping ---------------------------------------------------------------------------

    /// @notice Permissionless. Moves the USDC side of the fees - held here or still credited at the
    /// locker - to `usdcSink`. Called by `pull`; exposed separately so it can be run on its own.
    function sweepUsdc() external nonReentrant returns (uint256 amount) {
        amount = _sweepUsdc();
    }

    /// @notice Permissionless. Forwards any other token that lands here to `usdcSink`. ARCH is
    /// rejected: the only way ARCH leaves this contract is a valid claim.
    function sweepToken(address token) external nonReentrant returns (uint256 amount) {
        if (token == ARCH) revert ArchNotSweepable();
        if (token == address(0)) revert InvalidAddress();
        address sink = usdcSink;
        amount = IERC20Redistributor(token).balanceOf(address(this));
        if (amount == 0) return 0;
        if (!_erc20Transfer(token, sink, amount, 0)) revert TransferFailed();
        emit Swept(token, sink, amount);
    }

    /// @notice Permissionless. Arc's native currency is USDC at another scale, so treat anything that
    /// arrives that way exactly like the USDC side: straight to the sink.
    function sweepNative() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) return 0;
        address sink = usdcSink;
        (bool sent,) = sink.call{ value: amount }("");
        if (!sent) revert TransferFailed();
        emit Swept(address(0), sink, amount);
    }

    // --- admin ------------------------------------------------------------------------------

    function setPublisher(address newPublisher) external onlyOwner {
        if (newPublisher == address(0)) revert InvalidAddress();
        emit PublisherSet(publisher, newPublisher);
        publisher = newPublisher;
    }

    function setUsdcSink(address newSink) external onlyOwner {
        if (newSink == address(0)) revert InvalidAddress();
        emit UsdcSinkSet(usdcSink, newSink);
        usdcSink = newSink;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // --- views ------------------------------------------------------------------------------

    function epochCount() external view returns (uint256) {
        return _epochs.length;
    }

    function epochs(uint256 epochId)
        external
        view
        returns (
            bytes32 root,
            uint256 total,
            uint256 claimed,
            uint64 snapshotBlock,
            uint64 publishedAt,
            bool revoked,
            string memory uri
        )
    {
        if (epochId >= _epochs.length) revert InvalidEpoch();
        Epoch storage e = _epochs[epochId];
        return (e.root, e.total, e.claimed, e.snapshotBlock, e.publishedAt, e.revoked, e.uri);
    }

    /// @notice The leaf hash for an entry, so tooling and the contract can never disagree on encoding.
    function leaf(uint256 epochId, address account, uint256 amount) public pure returns (bytes32) {
        // Double hash: a leaf can then never be mistaken for an internal node, whatever the list.
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));
    }

    // --- internals --------------------------------------------------------------------------

    function _sweepUsdc() private returns (uint256 amount) {
        address sink = usdcSink;
        // Straight from the locker to the sink - it never has to touch this contract's balance.
        if (IArchLocker(LOCKER).claimable(address(this), USDC) != 0) {
            amount = IArchLocker(LOCKER).claim(USDC, sink);
        }
        uint256 sitting = IERC20Redistributor(USDC).balanceOf(address(this));
        if (sitting != 0) {
            if (!_erc20Transfer(USDC, sink, sitting, 0)) revert TransferFailed();
            amount += sitting;
        }
        if (amount != 0) emit Swept(USDC, sink, amount);
    }

    function _verify(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof)
        private
        view
        returns (bool)
    {
        if (epochId >= _epochs.length) return false;
        if (account == address(0) || amount == 0) return false;
        bytes32 computed = leaf(epochId, account, amount);
        for (uint256 i; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            computed = computed < sibling
                ? keccak256(abi.encode(computed, sibling))
                : keccak256(abi.encode(sibling, computed));
        }
        return computed == _epochs[epochId].root;
    }

    /// @param gasStipend 0 forwards all remaining gas (single claim); non-zero caps it (batch).
    function _payOut(address to, uint256 amount, uint256 gasStipend) private returns (bool) {
        return _erc20Transfer(ARCH, to, amount, gasStipend);
    }

    function _erc20Transfer(address token, address to, uint256 amount, uint256 gasStipend) private returns (bool) {
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", to, amount);
        (bool ok, bytes memory ret) = gasStipend == 0 ? token.call(data) : token.call{ gas: gasStipend }(data);
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    receive() external payable { }
}
