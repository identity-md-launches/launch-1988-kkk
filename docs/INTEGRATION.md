# Integration guide for the browser interface and backend

The contracts are the source of truth; the backend indexes events and the UI reads views and
sends transactions. Amounts are token base units (6 decimals: 1 dds = `1_000_000`). Times are
unix seconds (`uint64`). Ids are sequential and start at 1 (`0` means "none").

## Contract surface

### RentalEscrow – state machine

```
ReservationStatus: None(0) Reserved(1) Rented(2) Cancelled(3) Expired(4) Returned(5)
ItemState:         Available(0) Reserved(1) Rented(2)

reserve        : Available item  -> Reserved   (renter, before: approve deposit)
cancel         : Reserved        -> Cancelled  (renter, t <  expiresAt)   credit deposit-fee
expire         : Reserved        -> Expired    (anyone, t >= expiresAt)   credit deposit-fee
checkOut       : Reserved        -> Rented     (staff,  t <  expiresAt)
confirmReturn  : Rented          -> Returned   (staff)                    credit deposit
withdrawRefund : credit -> tokens               (beneficiary)
```

### Views

| Function | Returns |
|---|---|
| `quote(itemId)` | `(policyId, Policy{deposit, cancellationFee, reservationWindow})` for the *next* reservation |
| `getItem(itemId)` | `Item{exists, listed, state, policyId, activeReservationId, metadataURI}` |
| `getReservation(id)` | `Reservation{itemId, renter, policyId, createdAt, expiresAt, status, deposit, cancellationFee, clientRef}` |
| `getPolicy(policyId)` | `Policy` |
| `reservationByRef(renter, clientRef)` | reservation id or `0` |
| `refundCreditOf(addr)` | withdrawable credit |
| `isStaff(addr)`, `admin()`, `pendingAdmin()` | roles |
| `itemCount()`, `policyCount()`, `reservationCount()` | counters, ids are `1..count` |
| `totalEscrowed()`, `totalRefundCredits()`, `accruedFees()`, `totalLiabilities()` | accounting |

Views revert with `ItemNotFound`, `PolicyNotFound`, `ReservationNotFound` for unknown ids.

### Transactions

| Function | Caller | Notes |
|---|---|---|
| `reserve(itemId, expectedPolicyId, clientRef) -> reservationId` | renter | `clientRef != 0`, unique per renter; `expectedPolicyId` from `quote` |
| `cancel(reservationId)` | renter | before expiry |
| `expire(reservationId)` | anyone | at or after expiry |
| `checkOut(reservationId)` | staff | before expiry |
| `confirmReturn(reservationId)` | staff | |
| `withdrawRefund() -> amount` | beneficiary | whole credit, reverts if zero |
| `setStaff(addr, bool)` | admin | |
| `createPolicy(deposit, fee, window) -> policyId` | admin | `deposit > 0`, `fee <= deposit`, `window > 0` |
| `addItem(policyId, metadataURI) -> itemId` | admin | listed on creation |
| `setItemPolicy(itemId, policyId)`, `setItemListed(itemId, bool)`, `setItemMetadata(itemId, uri)` | admin | |
| `withdrawFees(to, amount)` | admin | `amount <= accruedFees` |
| `transferAdmin(addr)`, `acceptAdmin()` | admin / pending admin | two-step |

### Custom errors

```
NotAdmin() NotPendingAdmin() NotStaff() NotRenter() ZeroAddress() ZeroAmount() InvalidPolicy()
PolicyNotFound(uint64 policyId)
ItemNotFound(uint256 itemId)
ItemNotListed(uint256 itemId)
ItemNotAvailable(uint256 itemId, uint256 activeReservationId)
PolicyMismatch(uint64 expected, uint64 actual)
ClientRefRequired()
ClientRefAlreadyUsed(bytes32 clientRef, uint256 reservationId)
ReservationNotFound(uint256 reservationId)
InvalidReservationStatus(uint256 reservationId, uint8 current)
ReservationExpiredAlready(uint256 reservationId, uint64 expiresAt)
ReservationNotExpired(uint256 reservationId, uint64 expiresAt)
DepositMismatch(uint256 expected, uint256 received)
NothingToWithdraw()
InsufficientFees(uint256 requested, uint256 available)
```

Decode reverts with the ABI in `out/RentalEscrow.sol/RentalEscrow.json` (after `forge build`)
or `cast 4byte-decode`. `ClientRefAlreadyUsed` and `ItemNotAvailable` carry the id the UI
should show.

## Events

Every state change emits exactly one domain event (plus `RefundCredited` when a settlement
produces a credit). `indexed` fields are marked `*`.

```solidity
// configuration
event AdminTransferStarted(address* currentAdmin, address* pendingAdmin);
event AdminTransferred(address* previousAdmin, address* newAdmin);        // also at construction (from 0x0)
event StaffUpdated(address* account, bool enabled);
event PolicyCreated(uint64* policyId, uint256 deposit, uint256 cancellationFee, uint64 reservationWindow);
event ItemAdded(uint256* itemId, uint64* policyId, string metadataURI);
event ItemPolicyUpdated(uint256* itemId, uint64* oldPolicyId, uint64* newPolicyId);
event ItemListingUpdated(uint256* itemId, bool listed);
event ItemMetadataUpdated(uint256* itemId, string metadataURI);

// reservation lifecycle
event ReservationCreated(uint256* reservationId, uint256* itemId, address* renter,
                         uint64 policyId, uint256 deposit, uint256 cancellationFee,
                         uint64 expiresAt, bytes32 clientRef);
event ReservationCancelled(uint256* reservationId, uint256* itemId, address* renter, uint256 refund, uint256 fee);
event ReservationExpired(uint256* reservationId, uint256* itemId, address* renter, address caller, uint256 refund, uint256 fee);
event ItemCheckedOut(uint256* reservationId, uint256* itemId, address* staff);
event ItemReturned(uint256* reservationId, uint256* itemId, address* staff, uint256 refund);

// money
event RefundCredited(address* beneficiary, uint256* reservationId, uint256 amount);   // amount > 0 only
event RefundWithdrawn(address* beneficiary, uint256 amount);
event FeesWithdrawn(address* to, uint256 amount);
```

Suggested backend projection:

| Table | Built from |
|---|---|
| items | `ItemAdded`, `ItemPolicyUpdated`, `ItemListingUpdated`, `ItemMetadataUpdated`; current `state`/`activeReservationId` from `ReservationCreated` / `*Cancelled` / `*Expired` / `ItemReturned` |
| policies | `PolicyCreated` (immutable rows) |
| reservations | `ReservationCreated` (one row, includes the full snapshot) then status updates from `ItemCheckedOut`, `ReservationCancelled`, `ReservationExpired`, `ItemReturned` |
| credits | `RefundCredited` (+), `RefundWithdrawn` (−); should equal `refundCreditOf` |
| staff / admin | `StaffUpdated`, `AdminTransferred` |

A reservation in `Reserved` status with `expiresAt <= now` is "expirable"; the backend should
submit `expire` for it (any key works) so the item frees up and the renter's credit appears.

Reorg handling: index with a confirmation depth and re-derive from events; nothing in the
contract depends on off-chain state.

## Idempotency and uncertain transaction outcome

The contract guarantees that retries can never create duplicate deposits, reservations or
refunds. The UI/backend still needs to know *what happened* when a transaction's result is
unknown (timeout, dropped connection, replaced nonce). The procedure per action:

### reserve

1. Generate a fresh random 32-byte `clientRef` per user request (e.g. UUID v4 hashed with
   keccak256) and persist it **before** sending the transaction.
2. Send `reserve(itemId, quotedPolicyId, clientRef)`.
3. If the outcome is unknown, poll `reservationByRef(renter, clientRef)`:
   - non-zero: the reservation exists with that id; do not resend;
   - zero after the transaction is confirmed-failed or the nonce was consumed by something
     else: the request did not go through; it is safe to resend with the **same** ref.
4. Resending while the first is still pending is also safe: the second confirmation reverts
   with `ClientRefAlreadyUsed(ref, id)` and that error itself returns the id.

`ReservationCreated` carries the `clientRef`, so an indexer can join the on-chain reservation
to the originating request without any call.

### cancel / checkOut / confirmReturn / expire

These are status transitions. Read `getReservation(id).status`:

| Intended action | Already done if status is | Retry safe? |
|---|---|---|
| cancel | `Cancelled` | yes: a retry reverts with `InvalidReservationStatus` |
| expire | `Expired` | yes |
| checkOut | `Rented` (or `Returned`) | yes |
| confirmReturn | `Returned` | yes |

A retry can never apply twice because each terminal status is reached once and `Rented` is
only reachable from `Reserved`.

### withdrawRefund

Read `refundCreditOf(addr)`. Zero means the payout happened (or there never was one); a retry
reverts with `NothingToWithdraw`. The paid amount is in `RefundWithdrawn`.

### withdrawFees

Read `accruedFees()` before and after, or match the `FeesWithdrawn` event. The call is bounded
by `accruedFees`, so a duplicate that would overdraw reverts with `InsufficientFees`.

### General rule for the backend

Treat the chain as the system of record. Persist the intent (ref, action, id) first, then send,
then reconcile from events/views. Never mark a reservation as created from the transaction
hash alone; wait for `ReservationCreated` or a non-zero `reservationByRef`.

## Quoting and front-running

`quote(itemId)` returns the policy id and its parameters. Pass that policy id to `reserve`.
If the admin changes the item's policy between the quote and the inclusion of the
transaction, the call reverts with `PolicyMismatch(expected, actual)` instead of silently
taking a different deposit; re-quote and ask the user again.

## Allowances

Have the user approve exactly the quoted deposit (or a small multiple for repeat renters).
The contract pulls exactly `deposit`; any leftover allowance is never used by this contract.

## Units and display

| Field | Unit |
|---|---|
| `deposit`, `cancellationFee`, `refund`, `fee`, credits | token base units (10⁻⁶ dds) |
| `createdAt`, `expiresAt` | unix seconds |
| `reservationWindow` | seconds |

The refund on cancel/expire is `deposit - cancellationFee`, on return `deposit`. Show the
snapshotted values from the reservation, not the item's current policy.
