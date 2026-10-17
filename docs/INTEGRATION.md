# Integration guide for the browser interface and backend

The contracts are the source of truth; the backend indexes events and the UI reads views and
sends transactions. Amounts are token base units (6 decimals: 1 dds = `1_000_000`). Times are
unix seconds (`uint64`). Item, policy and reservation ids are sequential and start at 1
(`0` means "none"). Application keys (`clientRef`, fee `requestId`) are caller-chosen non-zero `bytes32`.

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
| `refundCreditOf(addr)` | current aggregate withdrawable credit |
| `feeWithdrawalById(requestId)` | `(address recipient, uint256 amount, bool completed)`; unused/reverted requests return `(0, 0, false)` |
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
| `withdrawRefund() -> amount` | beneficiary | whole credit **at execution**, reverts if zero; a later call may pay new credit |
| `setStaff(addr, bool)` | admin | |
| `createPolicy(deposit, fee, window) -> policyId` | admin | `deposit > 0`, `fee <= deposit`, `window > 0` |
| `addItem(policyId, metadataURI) -> itemId` | admin | listed on creation |
| `setItemPolicy(itemId, policyId)`, `setItemListed(itemId, bool)`, `setItemMetadata(itemId, uri)` | admin | |
| `withdrawFees(requestId, to, amount)` | admin | non-zero permanent request ID; positive amount bounded by `accruedFees`; same ID never pays again |
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
FeeWithdrawalIdRequired()
FeeWithdrawalAlreadyCompleted(bytes32 requestId, address recipient, uint256 amount)
FeeWithdrawalConflict(bytes32 requestId, address recipient, uint256 amount)
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
event FeesWithdrawn(bytes32* requestId, address* to, uint256 amount);
```

Suggested backend projection:

| Table | Built from |
|---|---|
| items | `ItemAdded`, `ItemPolicyUpdated`, `ItemListingUpdated`, `ItemMetadataUpdated`; current `state`/`activeReservationId` from `ReservationCreated` / `ItemCheckedOut` / `ReservationCancelled` / `ReservationExpired` / `ItemReturned` |
| policies | `PolicyCreated` (immutable rows) |
| reservations | `ReservationCreated` (one row, includes the full snapshot) then status updates from `ItemCheckedOut`, `ReservationCancelled`, `ReservationExpired`, `ItemReturned` |
| credits | `RefundCredited` (+), `RefundWithdrawn` (−); should equal `refundCreditOf` |
| staff / admin | `StaffUpdated`, `AdminTransferred` |
| fee withdrawals | `FeesWithdrawn`, keyed by `(chainId, escrowAddress, requestId)`; reconcile with `feeWithdrawalById` |

Apply the item and reservation projections together, in `(blockNumber, transactionIndex,
logIndex)` order, deduplicating logs by chain, contract, transaction hash and log index:

| Event | Item state | Item activeReservationId | Reservation status |
|---|---|---|---|
| `ItemAdded` | `Available` | `0` | no reservation |
| `ReservationCreated` | `Reserved` | event reservationId | `Reserved` |
| `ItemCheckedOut` | `Rented` | **retain event reservationId** | `Rented` |
| `ReservationCancelled` | `Available` | `0` | `Cancelled` |
| `ReservationExpired` | `Available` | `0` | `Expired` |
| `ItemReturned` | `Available` | `0` | `Returned` |

`ItemCheckedOut` does not free the item or clear its active reservation. Listing, metadata
and policy events leave these two state fields unchanged. Compare the projection against
`getItem(itemId)` and `getReservation(activeReservationId)` at the same confirmed block.
A rented item's reservation must be `Rented`; an available item's active id must be zero.

A reservation in `Reserved` status with `expiresAt <= now` is "expirable"; the backend should
submit `expire` for it (any key works) so the item frees up and the renter's credit appears.

Reorg handling: index with a confirmation depth and re-derive from events; nothing in the
contract depends on off-chain state.

## Idempotency and uncertain transaction outcome

There are two different kinds of retry:

- **Rebroadcast the identical signed transaction bytes:** the transaction hash and sender nonce
  are unchanged. It cannot execute twice on the canonical chain. An RPC timeout or an
  "already known" response says nothing about whether it has been mined.
- **Sign another transaction for the same application request:** a different sender nonce can
  let both transactions execute. Replacing a pending transaction at the **same sender and
  nonce** changes its hash, but only one such replacement can be included on the canonical
  chain. Contract request IDs, where supported, protect the application request independently
  of transaction hashes, nonces and replacement fees.

Before sending, persist `(chainId, escrowAddress, action, full payload, application request ID
if supported, sender, nonce)` and the signed transaction hash. Track every replacement hash.
For an unknown result, fetch receipts by hash, check receipt status, block number and block
hash, and reconcile the escrow's logs after the chosen confirmation depth. A status-0 receipt
means that transaction's state changes and logs reverted. A missing receipt is unresolved,
not proof of failure. If the sender nonce was consumed, find the mined transaction using that
sender and nonce (via the wallet's replacement tracking or indexed block transactions), then
inspect its receipt and payload; a nonce count alone cannot tell which action succeeded.
Roll back orphaned receipts and logs on a reorg, then reconcile again.

No mutable balance alone proves a particular withdrawal succeeded or failed. Use the
transaction's receipt/events and, for fees, the permanent request result described below.

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

`withdrawRefund()` has **no application request ID**. It withdraws the beneficiary's current
aggregate `refundCreditOf` at execution, zeros that credit before transfer, and emits
`RefundWithdrawn(beneficiary, amount)`. Each credited amount can be paid only once. If another
reservation settles between two calls, the later call can succeed and pay that **new** credit.
For example, the first call pays 45 dds from a cancellation, a later return credits 50 dds,
and a new transaction calling `withdrawRefund()` pays 50 dds. These are two distinct payouts.
If several reservations have credited refunds before a call executes, it pays their combined
outstanding credit. With no new credit, a later call reverts with `NothingToWithdraw`.

Recovery procedure:

1. Keep the original transaction hash, sender nonce, beneficiary and all replacement hashes.
   Rebroadcasting the identical signed bytes does not request a new payout.
2. Reconcile the canonical receipt and its escrow `RefundWithdrawn` log, checking beneficiary
   and amount. A confirmed successful payout is complete even if `refundCreditOf` is now
   positive because of a later settlement. Zero credit alone also cannot identify which
   transaction paid, or prove that any payout ever occurred.
3. Reconstruct the credit ledger from `RefundCredited(beneficiary, reservationId, amount)`
   and `RefundWithdrawn(beneficiary, amount)` in log order. Deduplicate by transaction hash
   and log index and apply reorg rollback. At a common confirmed block, credited amounts
   minus withdrawn amounts must equal `refundCreditOf`. A withdrawal event describes an
   aggregate payment, not a payout for one named reservation or an off-chain request ID.
4. If the original hash has no receipt and its nonce was consumed, locate and reconcile the
   replacement transaction. If still pending, keep its intent unresolved. Do not sign a
   different-nonce transaction solely because a credit read remains positive.
5. After reconciliation, submitting a new transaction authorizes withdrawal of whatever
   aggregate credit exists **when it executes**, including newly settled reservations. Record
   its own hash, nonce, receipt and event; never label that new payout as proof of the earlier
   attempt. A failed transfer restores the entire credit and emits no surviving payout log.

### withdrawFees

1. Generate a fresh non-zero random 32-byte `requestId` for each intended withdrawal and
   persist it with the recipient and amount **before signing**. Its namespace is the entire
   escrow, not the admin address. Keep it across retries, nonce replacements and admin handover.
   Do not derive it solely from recipient/amount (legitimate equal payments need distinct IDs),
   or generate a new ID for each transaction attempt.
2. Send `withdrawFees(requestId, to, amount)`. Success deducts only accrued fees, records
   `(recipient, amount, completed = true)` in `feeWithdrawalById(requestId)` and emits
   `FeesWithdrawn(requestId, to, amount)`, with request ID and recipient indexed.
3. For an uncertain result, query that lookup at a confirmed block and reconcile the matching
   event/receipt. A completed record with the intended payload establishes that the request
   was paid; the event identifies the successful transaction. **Do not infer success from
   `accruedFees()` or recipient token balances:** both can change for unrelated reasons.
4. A new transaction using a completed ID and identical payload reverts with
   `FeeWithdrawalAlreadyCompleted(requestId, originalRecipient, originalAmount)` before
   checking available fees. This deliberately signals "already completed" rather than
   producing a second successful payment receipt. It neither transfers tokens nor emits
   another `FeesWithdrawn`. Treat it as recovery information, then reconcile the original
   completed result. If either parameter differs, `FeeWithdrawalConflict` returns the original
   result and rejects the changed request; investigate the application's ID reuse.
5. An unused or failed request has `completed = false`. The first transaction might still be
   pending: consult hashes/nonces/receipts, but even a different-nonce retry with the **same ID
   and payload** cannot pay twice. Token reverts or false transfer returns roll back the ID,
   accrued-fee deduction and event; the same ID remains usable when the transfer can succeed.
6. IDs are permanent and never reset on `transferAdmin` / `acceptAdmin`. Only the current
   admin can submit any fee withdrawal, including a replay; the old admin can still read the
   public lookup. Hand over the application request ledger alongside operational control.
   A genuinely new withdrawal uses a new ID, even with the same recipient and amount.

### General rule for the backend

Treat the chain as the system of record. Persist the intent, payload and request ID first,
then sender nonce and transaction hashes, then reconcile receipts and events/views. Never mark
a reservation as created from the transaction hash alone; wait for `ReservationCreated` or a non-zero `reservationByRef`.

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

## Interface compatibility for this iteration

`withdrawFees(address,uint256)` is replaced by
`withdrawFees(bytes32,address,uint256)` (request ID first). There is no legacy overload: it
would bypass request deduplication. `FeesWithdrawn(address,uint256)` is replaced by
`FeesWithdrawn(bytes32,address,uint256)`, so its event signature/topic changes. Regenerate
client ABIs and update calldata, log filters and decoders together. The lookup, result struct
and three request errors are additive. Refund, reservation, item and administration ABIs
remain unchanged; item projection consumers must now apply the existing `ItemCheckedOut` event.

These are source changes to a non-upgradeable escrow, not an upgrade of any deployed contract.
No existing chain state or historical pre-change withdrawals are imported into this mapping.
This iteration performs only local tests and an Anvil demo; it changes no public deployment.
Constructor parameters and the payment token are unchanged.

## Read-only local indexer (this trial)

[`indexer/README.md`](../indexer/README.md) documents the implemented event consumer,
query endpoints and same-block reconciliation. Its backend never signs, submits transactions,
expires reservations, or pays refunds. The maintenance/intent-writing suggestions earlier
in this guide are responsibilities of a separate transaction-capable application; they are
**not** part of this read-only backend. Only its isolated synthetic Anvil test harness transacts.

Use the application `/sync` status and the status envelope on every domain response. Ponder's
built-in `/health`, `/ready`, and `/status` are framework diagnostics and do not establish
RPC connectivity or current canonical state. Latest domain state is provisional. The tested
rollback window is 120 seconds of chain timestamps, not 120 confirmations. No production
finality, remote RPC, PostgreSQL deployment or hosting is validated here.

The offline distribution uses the application's compact Node 24 bootstrap with original
Ponder 0.18.2 modules. Its dev database mode rebuilds projections on restart while retaining
the same PGlite directory; it does not incrementally resume projections or hot-reload edits.
Restart after changing source. The bootstrap depends on private Ponder interfaces, so upgrades
and new imports require rebuilding the scoped dependency bundle and rerunning acceptance tests.
