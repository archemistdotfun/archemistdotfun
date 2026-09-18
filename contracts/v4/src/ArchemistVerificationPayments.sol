// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice Escrow for Archemist's paid "Verified Token Information" product, in which a creator pays
/// Archemist to publish their token's identity to Blockscout's explorer, and Blockscout is paid a
/// wholesale fee per published record.
///
/// The whole design follows from one fact about the Blockscout API, measured before this was written
/// (see blockscout/FINDINGS.md): we cannot find out whether a record will be accepted until we submit
/// it, and by then the creator has already paid. Submission can fail for reasons that are entirely
/// ours - the API key is not authorised for the chain, the token's factory is not registered, or the
/// record is already owned by a different provider and cannot be overwritten by us at all.
///
/// So money does not move at payment time:
///
///   1. `pay` holds the creator's funds in this contract against a request id.
///   2. Archemist submits to Blockscout and confirms the record is actually live.
///   3. `settle` then - and only then - pays Blockscout its fee and Archemist the remainder.
///   4. `refund` returns the creator's money in full if the record never goes live.
///
/// That ordering is what makes "no refunds once published" an honest policy rather than a trap: the
/// only way funds reach Blockscout is a record that exists, and the only alternative outcome is the
/// creator getting everything back. Nothing can be settled and refunded; nothing is stuck in between.
///
/// Two roles, deliberately split. `owner` is a cold key: it sets prices and payout addresses and
/// nothing else. `settler` is the backend's hot key: it can only decide settle-or-refund on requests
/// that already exist, and can never redirect a payout or change a price. A compromised settler can
/// misroute outcomes between two fixed addresses and the payer; it cannot steal to a new address.
///
/// The fee owed to Blockscout is snapshotted into each payment at `pay` time, so a later price change
/// never alters what an already-paid request owes - a creator who paid under the old terms settles
/// under the old terms.
///
/// Payments are in the chain's native currency. On Arc that currency is USDC, so `price` and
/// `blockscoutFee` are plain native amounts and no token approval is involved.
contract ArchemistVerificationPayments {
    enum Status {
        None,
        Escrowed,
        Settled,
        Refunded
    }

    struct Payment {
        /// @dev Who paid, and who a refund goes back to. Never reassignable.
        address payer;
        uint96 paidAt;
        /// @dev The token whose information this payment verifies. Recorded for audit; the contract
        /// never reads it, because whether the record went live is a fact only the server can know.
        address token;
        Status status;
        /// @dev Escrowed amount, net of any excess already returned to the payer at `pay` time.
        uint256 amount;
        /// @dev Blockscout's share, fixed at `pay` time.
        uint256 fee;
    }

    /// @dev Guards against a deployment being replayed on a chain it was not configured for - the
    /// price here is denominated in Arc's native USDC and would be nonsense elsewhere.
    uint256 public immutable EXPECTED_CHAIN_ID;

    address public owner;
    address public pendingOwner;
    /// @dev Backend key allowed to call `settle` and `refund`.
    address public settler;
    /// @dev Receives the Archemist share on settlement.
    address public treasury;
    /// @dev Receives the wholesale fee on settlement.
    address public blockscoutRecipient;

    /// @dev What a creator pays. Retail price, Archemist's to set.
    uint256 public price;
    /// @dev What Blockscout is owed out of that price. Must never exceed `price`.
    uint256 public blockscoutFee;
    /// @dev Stops new payments. Never blocks `settle` or `refund`: money already escrowed must always
    /// be able to reach its destination, including while the product is paused.
    bool public paused;

    mapping(bytes32 requestId => Payment) public payments;
    /// @dev Owed to an address whose push transfer failed. Prevents one unreachable recipient from
    /// bricking settlement for everyone else.
    mapping(address recipient => uint256) public claimable;

    uint256 private _lock;

    event Paid(bytes32 indexed requestId, address indexed token, address indexed payer, uint256 amount, uint256 fee);
    event Settled(bytes32 indexed requestId, address indexed token, uint256 feeToBlockscout, uint256 amountToTreasury);
    event Refunded(bytes32 indexed requestId, address indexed token, address indexed payer, uint256 amount);
    event Credited(address indexed recipient, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);
    event PriceUpdated(uint256 price, uint256 blockscoutFee);
    event TreasuryUpdated(address treasury);
    event BlockscoutRecipientUpdated(address blockscoutRecipient);
    event SettlerUpdated(address settler);
    event PausedUpdated(bool paused);
    event OwnerTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    error NotAuthorized();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidFee();
    error DuplicateRequest();
    error UnknownRequest();
    error AlreadyResolved();
    error Paused();
    error Reentrancy();
    error NothingToClaim();
    error WrongChain();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlySettler() {
        if (msg.sender != settler && msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier nonReentrant() {
        if (_lock == 1) revert Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    constructor(
        address owner_,
        address treasury_,
        address blockscoutRecipient_,
        address settler_,
        uint256 price_,
        uint256 blockscoutFee_,
        uint256 expectedChainId_
    ) {
        if (owner_ == address(0) || treasury_ == address(0) || blockscoutRecipient_ == address(0)) {
            revert InvalidAddress();
        }
        if (settler_ == address(0)) revert InvalidAddress();
        if (price_ == 0) revert InvalidAmount();
        if (blockscoutFee_ > price_) revert InvalidFee();
        if (expectedChainId_ == 0) revert WrongChain();

        owner = owner_;
        treasury = treasury_;
        blockscoutRecipient = blockscoutRecipient_;
        settler = settler_;
        price = price_;
        blockscoutFee = blockscoutFee_;
        EXPECTED_CHAIN_ID = expectedChainId_;

        emit OwnerTransferred(address(0), owner_);
        emit TreasuryUpdated(treasury_);
        emit BlockscoutRecipientUpdated(blockscoutRecipient_);
        emit SettlerUpdated(settler_);
        emit PriceUpdated(price_, blockscoutFee_);
    }

    // ------------------------------------------------------------------ creator

    /// @notice Pay for one verification. The funds stay here until the record is live (`settle`) or
    /// confirmed impossible (`refund`).
    /// @param token The token being verified. Recorded in the event so the submission our server sends
    /// can be tied back to the payment that authorises it.
    /// @param requestId Single-use identifier minted by our server, the same id carried through the
    /// signed payload and the Blockscout submission. Replaying one reverts, which is what makes the
    /// payment, the signature and the submission a single unit.
    function pay(address token, bytes32 requestId) external payable nonReentrant {
        if (block.chainid != EXPECTED_CHAIN_ID) revert WrongChain();
        if (paused) revert Paused();
        if (token == address(0)) revert InvalidAddress();
        if (requestId == bytes32(0)) revert UnknownRequest();
        if (payments[requestId].status != Status.None) revert DuplicateRequest();

        uint256 due = price;
        if (msg.value < due) revert InvalidAmount();

        payments[requestId] = Payment({
            payer: msg.sender,
            paidAt: uint96(block.timestamp),
            token: token,
            status: Status.Escrowed,
            amount: due,
            fee: blockscoutFee
        });

        emit Paid(requestId, token, msg.sender, due, blockscoutFee);

        // Overpayment goes straight back. Credited rather than pushed on failure, so a contract payer
        // with no receive function cannot make its own overpayment revert the purchase.
        uint256 excess = msg.value - due;
        if (excess != 0) _pushOrCredit(msg.sender, excess);
    }

    // ------------------------------------------------------------------- backend

    /// @notice Release an escrowed payment: Blockscout's fee to Blockscout, the rest to the treasury.
    /// Call only after the record has been confirmed live on the explorer - this contract cannot check
    /// that, and deliberately does not pretend to.
    function settle(bytes32 requestId) external onlySettler nonReentrant {
        Payment storage payment = payments[requestId];
        Status status = payment.status;
        if (status == Status.None) revert UnknownRequest();
        if (status != Status.Escrowed) revert AlreadyResolved();

        payment.status = Status.Settled;

        uint256 fee = payment.fee;
        uint256 remainder = payment.amount - fee;
        address token = payment.token;

        emit Settled(requestId, token, fee, remainder);

        if (fee != 0) _pushOrCredit(blockscoutRecipient, fee);
        if (remainder != 0) _pushOrCredit(treasury, remainder);
    }

    /// @notice Return an escrowed payment to the creator, in full. For the cases the creator cannot be
    /// blamed for: the record is owned by another provider, our key is not authorised for the chain, or
    /// Blockscout rejected the submission outright.
    function refund(bytes32 requestId) external onlySettler nonReentrant {
        Payment storage payment = payments[requestId];
        Status status = payment.status;
        if (status == Status.None) revert UnknownRequest();
        if (status != Status.Escrowed) revert AlreadyResolved();

        payment.status = Status.Refunded;

        uint256 amount = payment.amount;
        address payer = payment.payer;

        emit Refunded(requestId, payment.token, payer, amount);

        _pushOrCredit(payer, amount);
    }

    // -------------------------------------------------------------------- claims

    /// @notice Withdraw funds credited after a failed push. Anyone can trigger a recipient's own claim;
    /// the money can only ever go to that recipient.
    function claim(address recipient) external nonReentrant returns (uint256 amount) {
        amount = claimable[recipient];
        if (amount == 0) revert NothingToClaim();
        claimable[recipient] = 0;
        emit Claimed(recipient, amount);
        (bool success,) = recipient.call{ value: amount }("");
        if (!success) revert NothingToClaim();
    }

    // --------------------------------------------------------------------- admin

    /// @notice Set the retail price and the wholesale fee together, because a fee above the price would
    /// make settlement underflow and the two are only ever meaningful as a pair.
    function setPricing(uint256 price_, uint256 blockscoutFee_) external onlyOwner {
        if (price_ == 0) revert InvalidAmount();
        if (blockscoutFee_ > price_) revert InvalidFee();
        price = price_;
        blockscoutFee = blockscoutFee_;
        emit PriceUpdated(price_, blockscoutFee_);
    }

    /// @notice Change the retail price, keeping Blockscout's fee as it is. The common case: Archemist
    /// runs a promotion or moves the price, while the wholesale fee is fixed by agreement.
    function setPrice(uint256 price_) external onlyOwner {
        if (price_ == 0) revert InvalidAmount();
        if (blockscoutFee > price_) revert InvalidFee();
        price = price_;
        emit PriceUpdated(price_, blockscoutFee);
    }

    /// @notice Change Blockscout's wholesale fee, keeping the retail price as it is.
    function setBlockscoutFee(uint256 blockscoutFee_) external onlyOwner {
        if (blockscoutFee_ > price) revert InvalidFee();
        blockscoutFee = blockscoutFee_;
        emit PriceUpdated(price, blockscoutFee_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @dev Blockscout's Arc address was not known when this was deployed; that is the only reason this
    /// setter exists. Changing it does not alter what an already-escrowed payment owes, only where the
    /// next settlement sends it.
    function setBlockscoutRecipient(address blockscoutRecipient_) external onlyOwner {
        if (blockscoutRecipient_ == address(0)) revert InvalidAddress();
        blockscoutRecipient = blockscoutRecipient_;
        emit BlockscoutRecipientUpdated(blockscoutRecipient_);
    }

    function setSettler(address settler_) external onlyOwner {
        if (settler_ == address(0)) revert InvalidAddress();
        settler = settler_;
        emit SettlerUpdated(settler_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedUpdated(paused_);
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

    // --------------------------------------------------------------------- views

    function paymentOf(bytes32 requestId)
        external
        view
        returns (address payer, address token, Status status, uint256 amount, uint256 fee, uint256 paidAt)
    {
        Payment storage payment = payments[requestId];
        return (payment.payer, payment.token, payment.status, payment.amount, payment.fee, payment.paidAt);
    }

    // ------------------------------------------------------------------ internal

    function _pushOrCredit(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{ value: amount, gas: 100_000 }("");
        if (!success) {
            claimable[recipient] += amount;
            emit Credited(recipient, amount);
        }
    }
}
