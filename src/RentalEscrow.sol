// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RentalEscrow
/// @notice Deposit escrow for a small equipment-rental application.
///
/// Lifecycle of one reservation (one per item at a time):
///
///   reserve ──► Reserved ──cancel (renter, before expiry)──► Cancelled   (deposit - fee credited)
///                  │     ──expire (anyone, at/after expiry)──► Expired   (deposit - fee credited)
///                  └─────checkOut (staff, before expiry)────► Rented
///                                                              └──confirmReturn (staff)──► Returned (full deposit credited)
///
/// Refund credits are pulled by their beneficiary with `withdrawRefund`. Cancellation fees accrue
/// to `accruedFees` and are the only balance the administrator can withdraw.
///
/// Accounting invariant: token.balanceOf(this) >= totalEscrowed + totalRefundCredits + accruedFees.
contract RentalEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Physical state of an item as tracked by the contract.
    enum ItemState {
        Available,
        Reserved,
        Rented
    }

    /// @notice Lifecycle state of a reservation. `Cancelled`, `Expired` and `Returned` are terminal.
    enum ReservationStatus {
        None,
        Reserved,
        Rented,
        Cancelled,
        Expired,
        Returned
    }

    /// @notice An immutable pricing/timing policy version. Items point at a policy; reservations snapshot it.
    struct Policy {
        uint256 deposit; // required deposit in token base units, > 0
        uint256 cancellationFee; // fee kept on cancel/expire, <= deposit
        uint64 reservationWindow; // seconds from reservation until expiry, > 0
    }

    struct Item {
        bool exists;
        bool listed; // false: no new reservations (existing ones continue)
        ItemState state;
        uint64 policyId; // policy applied to the next reservation
        uint256 activeReservationId; // 0 when the item is available
        string metadataURI; // off-chain description, free-form
    }

    struct Reservation {
        uint256 itemId;
        address renter;
        uint64 policyId; // snapshot
        uint64 createdAt;
        uint64 expiresAt; // snapshot: createdAt + policy.reservationWindow
        ReservationStatus status;
        uint256 deposit; // snapshot
        uint256 cancellationFee; // snapshot
        bytes32 clientRef; // caller-chosen idempotency key, unique per renter
    }

    /// @notice Permanent result of one successful fee withdrawal request.
    struct FeeWithdrawal {
        address recipient;
        uint256 amount;
        bool completed;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Payment token (expected: 6-decimal ERC-20).
    IERC20 public immutable token;

    /// @notice Administrator: manages items, staff, policies and fee withdrawals.
    address public admin;
    /// @notice Address that may call `acceptAdmin` to complete a two-step handover.
    address public pendingAdmin;

    mapping(address => bool) private _staff;

    uint64 public policyCount;
    mapping(uint64 => Policy) private _policies;

    uint256 public itemCount;
    mapping(uint256 => Item) private _items;

    uint256 public reservationCount;
    mapping(uint256 => Reservation) private _reservations;

    /// @notice renter => clientRef => reservationId (0 = unused). Idempotency index for `reserve`.
    mapping(address => mapping(bytes32 => uint256)) public reservationByRef;

    /// @notice Refund credit withdrawable by each beneficiary.
    mapping(address => uint256) public refundCreditOf;

    /// @notice Sum of deposits held for reservations in `Reserved` or `Rented` status.
    uint256 public totalEscrowed;
    /// @notice Sum of all outstanding `refundCreditOf` balances.
    uint256 public totalRefundCredits;
    /// @notice Cancellation fees earned and not yet withdrawn by the administrator.
    uint256 public accruedFees;

    /// @notice Request ID => completed result. Global to this escrow, including across admin handovers.
    /// @dev An unused or reverted request returns (address(0), 0, false). Completed records are never cleared.
    mapping(bytes32 => FeeWithdrawal) public feeWithdrawalById;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event StaffUpdated(address indexed account, bool enabled);
    event PolicyCreated(uint64 indexed policyId, uint256 deposit, uint256 cancellationFee, uint64 reservationWindow);
    event ItemAdded(uint256 indexed itemId, uint64 indexed policyId, string metadataURI);
    event ItemPolicyUpdated(uint256 indexed itemId, uint64 indexed oldPolicyId, uint64 indexed newPolicyId);
    event ItemListingUpdated(uint256 indexed itemId, bool listed);
    event ItemMetadataUpdated(uint256 indexed itemId, string metadataURI);

    event ReservationCreated(
        uint256 indexed reservationId,
        uint256 indexed itemId,
        address indexed renter,
        uint64 policyId,
        uint256 deposit,
        uint256 cancellationFee,
        uint64 expiresAt,
        bytes32 clientRef
    );
    event ReservationCancelled(
        uint256 indexed reservationId, uint256 indexed itemId, address indexed renter, uint256 refund, uint256 fee
    );
    event ReservationExpired(
        uint256 indexed reservationId,
        uint256 indexed itemId,
        address indexed renter,
        address caller,
        uint256 refund,
        uint256 fee
    );
    event ItemCheckedOut(uint256 indexed reservationId, uint256 indexed itemId, address indexed staff);
    event ItemReturned(uint256 indexed reservationId, uint256 indexed itemId, address indexed staff, uint256 refund);
    event RefundCredited(address indexed beneficiary, uint256 indexed reservationId, uint256 amount);
    event RefundWithdrawn(address indexed beneficiary, uint256 amount);
    event FeesWithdrawn(bytes32 indexed requestId, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotAdmin();
    error NotPendingAdmin();
    error NotStaff();
    error NotRenter();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidPolicy();
    error PolicyNotFound(uint64 policyId);
    error ItemNotFound(uint256 itemId);
    error ItemNotListed(uint256 itemId);
    error ItemNotAvailable(uint256 itemId, uint256 activeReservationId);
    error PolicyMismatch(uint64 expected, uint64 actual);
    error ClientRefRequired();
    error ClientRefAlreadyUsed(bytes32 clientRef, uint256 reservationId);
    error ReservationNotFound(uint256 reservationId);
    error InvalidReservationStatus(uint256 reservationId, ReservationStatus current);
    error ReservationExpiredAlready(uint256 reservationId, uint64 expiresAt);
    error ReservationNotExpired(uint256 reservationId, uint64 expiresAt);
    error DepositMismatch(uint256 expected, uint256 received);
    error NothingToWithdraw();
    error InsufficientFees(uint256 requested, uint256 available);
    error FeeWithdrawalIdRequired();
    error FeeWithdrawalAlreadyCompleted(bytes32 requestId, address recipient, uint256 amount);
    error FeeWithdrawalConflict(bytes32 requestId, address recipient, uint256 amount);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev Checked at call time, so a revoked staff member is rejected immediately.
    modifier onlyStaff() {
        if (!_staff[msg.sender]) revert NotStaff();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param token_ ERC-20 payment token. Not called in the constructor; checked on first use.
    /// @param admin_ Initial administrator. Must not be zero.
    constructor(address token_, address admin_) {
        if (token_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
        admin = admin_;
        emit AdminTransferred(address(0), admin_);
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    /// @notice Start a two-step admin handover. Pass zero to cancel a pending handover.
    /// @dev Zero is intentionally accepted here: it clears `pendingAdmin` and `acceptAdmin` rejects it.
    // forge-lint: disable-next-line(missing-zero-check)
    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(msg.sender, newAdmin);
    }

    /// @notice Complete the admin handover. Only the pending admin can call this.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) revert NotPendingAdmin();
        address previous = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(previous, msg.sender);
    }

    /// @notice Grant or revoke staff permission. Takes effect immediately.
    function setStaff(address account, bool enabled) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        _staff[account] = enabled;
        emit StaffUpdated(account, enabled);
    }

    /// @notice Create a new immutable policy version.
    /// @param deposit Required deposit, > 0.
    /// @param cancellationFee Fee retained on cancellation/expiry, <= deposit.
    /// @param reservationWindow Seconds between reservation and expiry, > 0.
    function createPolicy(uint256 deposit, uint256 cancellationFee, uint64 reservationWindow)
        external
        onlyAdmin
        returns (uint64 policyId)
    {
        if (deposit == 0 || cancellationFee > deposit || reservationWindow == 0) revert InvalidPolicy();
        policyId = ++policyCount;
        _policies[policyId] =
            Policy({deposit: deposit, cancellationFee: cancellationFee, reservationWindow: reservationWindow});
        emit PolicyCreated(policyId, deposit, cancellationFee, reservationWindow);
    }

    /// @notice Register a new, listed item under `policyId`.
    function addItem(uint64 policyId, string calldata metadataURI) external onlyAdmin returns (uint256 itemId) {
        _requirePolicy(policyId);
        itemId = ++itemCount;
        Item storage item = _items[itemId];
        item.exists = true;
        item.listed = true;
        item.policyId = policyId;
        item.metadataURI = metadataURI;
        emit ItemAdded(itemId, policyId, metadataURI);
    }

    /// @notice Point an item at a different policy. Only the next reservation is affected.
    function setItemPolicy(uint256 itemId, uint64 policyId) external onlyAdmin {
        Item storage item = _requireItem(itemId);
        _requirePolicy(policyId);
        uint64 old = item.policyId;
        item.policyId = policyId;
        emit ItemPolicyUpdated(itemId, old, policyId);
    }

    /// @notice List or delist an item. Delisting blocks new reservations; an active one continues normally.
    function setItemListed(uint256 itemId, bool listed) external onlyAdmin {
        Item storage item = _requireItem(itemId);
        item.listed = listed;
        emit ItemListingUpdated(itemId, listed);
    }

    /// @notice Update an item's off-chain description.
    function setItemMetadata(uint256 itemId, string calldata metadataURI) external onlyAdmin {
        Item storage item = _requireItem(itemId);
        item.metadataURI = metadataURI;
        emit ItemMetadataUpdated(itemId, metadataURI);
    }

    /// @notice Withdraw earned cancellation fees. Escrowed deposits and refund credits are never reachable here.
    /// @dev Matching retries revert with the recorded result; conflicting payloads revert with
    ///      FeeWithdrawalConflict carrying the original result. Neither retry moves tokens or emits an event.
    ///      A failed transfer rolls back the result, fee deduction and event, allowing the same ID to be retried.
    /// @param requestId Non-zero application request ID, unique for this escrow's entire lifetime.
    function withdrawFees(bytes32 requestId, address to, uint256 amount) external nonReentrant onlyAdmin {
        if (requestId == bytes32(0)) revert FeeWithdrawalIdRequired();
        FeeWithdrawal memory previous = feeWithdrawalById[requestId];
        if (previous.completed) {
            if (previous.recipient != to || previous.amount != amount) {
                revert FeeWithdrawalConflict(requestId, previous.recipient, previous.amount);
            }
            revert FeeWithdrawalAlreadyCompleted(requestId, previous.recipient, previous.amount);
        }
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 available = accruedFees;
        if (amount > available) revert InsufficientFees(amount, available);
        accruedFees = available - amount;
        feeWithdrawalById[requestId] = FeeWithdrawal({recipient: to, amount: amount, completed: true});
        emit FeesWithdrawn(requestId, to, amount);
        token.safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------------
    // Renter actions
    // ---------------------------------------------------------------------

    /// @notice Reserve an available item, pulling exactly the policy deposit into escrow.
    /// @dev The caller must have approved at least the deposit. The transfer and the reservation are
    ///      atomic: if anything fails nothing is taken. Retrying with the same `clientRef` after a
    ///      success reverts with `ClientRefAlreadyUsed`, carrying the reservation id, so a retry can
    ///      never create a second deposit for the same request.
    /// @param itemId Item to reserve.
    /// @param expectedPolicyId Policy the caller saw when quoting; reverts if the item's policy changed.
    /// @param clientRef Non-zero idempotency key chosen by the caller, unique per renter.
    function reserve(uint256 itemId, uint64 expectedPolicyId, bytes32 clientRef)
        external
        nonReentrant
        returns (uint256 reservationId)
    {
        if (clientRef == bytes32(0)) revert ClientRefRequired();
        uint256 existing = reservationByRef[msg.sender][clientRef];
        if (existing != 0) revert ClientRefAlreadyUsed(clientRef, existing);

        Item storage item = _requireItem(itemId);
        if (!item.listed) revert ItemNotListed(itemId);
        if (item.state != ItemState.Available) revert ItemNotAvailable(itemId, item.activeReservationId);
        if (item.policyId != expectedPolicyId) revert PolicyMismatch(expectedPolicyId, item.policyId);
        Policy memory policy = _policies[item.policyId];

        // Effects
        reservationId = ++reservationCount;
        // block.timestamp fits in uint64 for the next ~584 billion years; the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp);
        uint64 expiresAt = nowTs + policy.reservationWindow;
        _reservations[reservationId] = Reservation({
            itemId: itemId,
            renter: msg.sender,
            policyId: item.policyId,
            createdAt: nowTs,
            expiresAt: expiresAt,
            status: ReservationStatus.Reserved,
            deposit: policy.deposit,
            cancellationFee: policy.cancellationFee,
            clientRef: clientRef
        });
        reservationByRef[msg.sender][clientRef] = reservationId;
        item.state = ItemState.Reserved;
        item.activeReservationId = reservationId;
        totalEscrowed += policy.deposit;

        emit ReservationCreated(
            reservationId,
            itemId,
            msg.sender,
            item.policyId,
            policy.deposit,
            policy.cancellationFee,
            expiresAt,
            clientRef
        );

        // Interaction: pull exactly the deposit. Fee-on-transfer or short transfers revert the whole call.
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), policy.deposit);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != policy.deposit) revert DepositMismatch(policy.deposit, received);
    }

    /// @notice Cancel an own reservation before expiry. Credits deposit minus the snapshotted fee.
    function cancel(uint256 reservationId) external {
        Reservation storage r = _requireReservation(reservationId);
        if (r.renter != msg.sender) revert NotRenter();
        if (r.status != ReservationStatus.Reserved) revert InvalidReservationStatus(reservationId, r.status);
        if (block.timestamp >= r.expiresAt) revert ReservationExpiredAlready(reservationId, r.expiresAt);

        (uint256 refund, uint256 fee) = _settleUnrented(r, reservationId, ReservationStatus.Cancelled);
        emit ReservationCancelled(reservationId, r.itemId, r.renter, refund, fee);
    }

    /// @notice Withdraw the caller's whole refund credit. Reverts if there is nothing to withdraw.
    /// @dev This pays the aggregate credit at execution, not a particular application request.
    ///      New settlements between calls can produce new credit that a later call will withdraw.
    function withdrawRefund() external nonReentrant returns (uint256 amount) {
        amount = refundCreditOf[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        refundCreditOf[msg.sender] = 0;
        totalRefundCredits -= amount;
        emit RefundWithdrawn(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Staff actions
    // ---------------------------------------------------------------------

    /// @notice Confirm the physical handover of a reserved item before its expiry.
    function checkOut(uint256 reservationId) external onlyStaff {
        Reservation storage r = _requireReservation(reservationId);
        if (r.status != ReservationStatus.Reserved) revert InvalidReservationStatus(reservationId, r.status);
        if (block.timestamp >= r.expiresAt) revert ReservationExpiredAlready(reservationId, r.expiresAt);

        r.status = ReservationStatus.Rented;
        _items[r.itemId].state = ItemState.Rented;
        emit ItemCheckedOut(reservationId, r.itemId, msg.sender);
    }

    /// @notice Confirm the physical return of a rented item. Credits the full deposit and frees the item.
    function confirmReturn(uint256 reservationId) external onlyStaff {
        Reservation storage r = _requireReservation(reservationId);
        if (r.status != ReservationStatus.Rented) revert InvalidReservationStatus(reservationId, r.status);

        r.status = ReservationStatus.Returned;
        _releaseItem(r.itemId);
        totalEscrowed -= r.deposit;
        _credit(r.renter, reservationId, r.deposit);
        emit ItemReturned(reservationId, r.itemId, msg.sender, r.deposit);
    }

    // ---------------------------------------------------------------------
    // Permissionless maintenance
    // ---------------------------------------------------------------------

    /// @notice Expire a reservation that was never checked out, at or after its expiry timestamp.
    /// @dev Applies the same snapshotted cancellation fee as `cancel`. Rented reservations never expire.
    function expire(uint256 reservationId) external {
        Reservation storage r = _requireReservation(reservationId);
        if (r.status != ReservationStatus.Reserved) revert InvalidReservationStatus(reservationId, r.status);
        if (block.timestamp < r.expiresAt) revert ReservationNotExpired(reservationId, r.expiresAt);

        (uint256 refund, uint256 fee) = _settleUnrented(r, reservationId, ReservationStatus.Expired);
        emit ReservationExpired(reservationId, r.itemId, r.renter, msg.sender, refund, fee);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function isStaff(address account) external view returns (bool) {
        return _staff[account];
    }

    function getPolicy(uint64 policyId) external view returns (Policy memory) {
        _requirePolicy(policyId);
        return _policies[policyId];
    }

    function getItem(uint256 itemId) external view returns (Item memory) {
        _requireItem(itemId);
        return _items[itemId];
    }

    function getReservation(uint256 reservationId) external view returns (Reservation memory) {
        _requireReservation(reservationId);
        return _reservations[reservationId];
    }

    /// @notice Deposit a new reservation of `itemId` would need right now, and the policy it would snapshot.
    function quote(uint256 itemId) external view returns (uint64 policyId, Policy memory policy) {
        Item storage item = _requireItem(itemId);
        policyId = item.policyId;
        policy = _policies[policyId];
    }

    /// @notice Everything the contract owes: escrowed deposits + refund credits + withdrawable fees.
    function totalLiabilities() public view returns (uint256) {
        return totalEscrowed + totalRefundCredits + accruedFees;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Shared settlement for cancel/expire: deposit leaves escrow, fee accrues, remainder is credited.
    function _settleUnrented(Reservation storage r, uint256 reservationId, ReservationStatus finalStatus)
        private
        returns (uint256 refund, uint256 fee)
    {
        fee = r.cancellationFee;
        refund = r.deposit - fee;
        r.status = finalStatus;
        _releaseItem(r.itemId);
        totalEscrowed -= r.deposit;
        accruedFees += fee;
        _credit(r.renter, reservationId, refund);
    }

    function _credit(address beneficiary, uint256 reservationId, uint256 amount) private {
        if (amount == 0) return;
        refundCreditOf[beneficiary] += amount;
        totalRefundCredits += amount;
        emit RefundCredited(beneficiary, reservationId, amount);
    }

    function _releaseItem(uint256 itemId) private {
        Item storage item = _items[itemId];
        item.state = ItemState.Available;
        item.activeReservationId = 0;
    }

    function _requirePolicy(uint64 policyId) private view {
        if (policyId == 0 || policyId > policyCount) revert PolicyNotFound(policyId);
    }

    function _requireItem(uint256 itemId) private view returns (Item storage item) {
        item = _items[itemId];
        if (!item.exists) revert ItemNotFound(itemId);
    }

    function _requireReservation(uint256 reservationId) private view returns (Reservation storage r) {
        r = _reservations[reservationId];
        if (r.status == ReservationStatus.None) revert ReservationNotFound(reservationId);
    }
}
