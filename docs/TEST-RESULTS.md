# Test results actually obtained

Machine: Linux x86_64, Foundry 1.8.3 (`cae51ad`), solc 0.8.26, EVM `cancun`.
Date: 2026-10-16. All commands run from the repository root with no `.env`.

## forge build

```
$ forge build --force
Compiler run successful with warnings:
```

The only solc warning comes from a scratch file under `test/scratch/` (not delivered).
Lint warnings in `src/` were addressed (see `foundry.toml` `[lint]` for the one excluded
category, `block-timestamp`, which expiry logic requires). Remaining lint notes are in test
files only (`environment-read-across-mutation`: `block.timestamp` read before a `vm.warp`,
which is the intended pattern there).

## forge fmt --check

```
$ forge fmt --check
$ echo $?
0
```

## forge test (verifier seed)

```
$ FOUNDRY_FUZZ_SEED=0xa85ca939c64936ae8ea823718cfe66ec12c31ec61aa4224f74167592b3e17548 forge test
Ran 5 test suites in 3.14s (4.41s CPU time): 64 tests passed, 0 failed, 0 skipped (64 total tests)
```

Per suite:

| Suite | Tests | Result |
|---|---|---|
| `test/RentalEscrow.t.sol:RentalEscrowTest` | 47 unit | 47 passed |
| `test/RentalEscrowFuzz.t.sol:RentalEscrowFuzzTest` | 9 fuzz × 256 runs | 9 passed |
| `test/invariant/RentalEscrowInvariant.t.sol:RentalEscrowInvariantTest` | 8 invariants, 64 runs × depth 48 = 3072 calls, 0 reverts | 8 passed |
| `test/MockPaymentToken.t.sol:MockPaymentTokenTest` | 3 unit + 1 fuzz | 4 passed |
| `test/Scripts.t.sol:ScriptsTest` | 3 unit | 3 passed |

The same result was obtained without the seed (random inputs) on several runs.

Full list of unit tests:

```
[PASS] test_adminHandover_cancelPending()
[PASS] test_adminHandover_twoStep()
[PASS] test_cancel_afterCheckoutReverts()
[PASS] test_cancel_boundary_lastSecondOkExactExpiryRejected()
[PASS] test_cancel_creditsDepositMinusFee()
[PASS] test_cancel_onlyRenter()
[PASS] test_cancel_twiceReverts()
[PASS] test_cancel_unknownReservation()
[PASS] test_cancel_withFullFeePolicyCreditsNothing()
[PASS] test_cancel_withZeroFeePolicyCreditsEverything()
[PASS] test_checkOut_afterCancelReverts()
[PASS] test_checkOut_boundary_rejectedAtExpiry()
[PASS] test_checkOut_byStaff()
[PASS] test_checkOut_twiceReverts()
[PASS] test_checkOut_unauthorizedCallers()
[PASS] test_confirmReturn_creditsFullDeposit()
[PASS] test_confirmReturn_requiresRentedStatus()
[PASS] test_confirmReturn_twiceReverts_singleCredit()
[PASS] test_confirmReturn_unauthorized()
[PASS] test_constructor_revertsOnZeroAddresses()
[PASS] test_constructor_setsTokenAndAdmin()
[PASS] test_createPolicy_validation()
[PASS] test_delistingDuringReservation_doesNotBreakLifecycle()
[PASS] test_expire_byAnyoneAtExpiry()
[PASS] test_expire_cancelledOrUnknownReverts()
[PASS] test_expire_longAfterExpiryStillWorksOnce()
[PASS] test_expire_rentedItemsNeverExpire()
[PASS] test_fullLifecycle_itemReusedAcrossManyRentals()
[PASS] test_items_adminManagement()
[PASS] test_policyChange_doesNotAffectExistingReservation()
[PASS] test_reserve_competing_secondRenterRejected()
[PASS] test_reserve_feeOnTransferTokenIsRejected()
[PASS] test_reserve_happyPath()
[PASS] test_reserve_insufficientAllowanceOrBalanceTakesNothing()
[PASS] test_reserve_rejectsStalePolicyQuote()
[PASS] test_reserve_rejectsUnknownOrDelistedItem()
[PASS] test_reserve_rejectsZeroRef()
[PASS] test_reserve_retryWithSameRefRevertsAndNamesReservation()
[PASS] test_reserve_sameRefDifferentRentersAreIndependent()
[PASS] test_setStaff_onlyAdmin()
[PASS] test_staffRevocation_isImmediate()
[PASS] test_views_revertOnUnknownReservation()
[PASS] test_withdrawFees_adminOnlyAndBounded()
[PASS] test_withdrawFees_cannotReachEscrowedDeposits()
[PASS] test_withdrawRefund_accumulatesAcrossReservations()
[PASS] test_withdrawRefund_isPerBeneficiary()
[PASS] test_withdrawRefund_paysOnceOnly()
[PASS] test_deploy_rejectsZeroConfig()
[PASS] test_deploy_wiresTokenAndEscrow()
[PASS] test_seed_createsDemoStateAndFundsRenter()
[PASS] test_fixedSupplyMintedToHolder()
[PASS] test_metadata()
[PASS] test_rejectsZeroHolder()
```

Fuzz tests (256 runs each):

```
[PASS] testFuzz_competingReservations(address,address,bytes32,bytes32)
[PASS] testFuzz_duplicateActionsSettleOnce(uint8,uint64)
[PASS] testFuzz_expiryBoundary_cancelVsExpire(uint256,uint256,uint64,uint64)
[PASS] testFuzz_feeWithdrawalBounded(uint256,uint8,uint8)
[PASS] testFuzz_policyChangeDoesNotLeak(uint256,uint256,uint64,uint256,uint256,uint64,bool)
[PASS] testFuzz_refundRetries(uint8,bool)
[PASS] testFuzz_rentedNeverExpires(uint256,uint256,uint64,uint64)
[PASS] testFuzz_reserve_exactDepositAndSnapshot(uint256,uint256,uint64,bytes32)
[PASS] testFuzz_unauthorizedCallersRejected(address,uint8)
[PASS] testFuzz_transferConservesSupply(address,uint256)
```

Invariants (handler: 4 renters, 2 staff, 4 items on 3 policies; actions: reserve, replay of
a used clientRef, cancel by renter/non-renter, checkOut by staff/renter, confirmReturn,
expire, warp up to 2 h, withdrawRefund, withdrawFees of arbitrary amounts, new policy
assignment, listing toggles, staff toggles):

```
[PASS] invariant_adminUnchanged
[PASS] invariant_balanceCoversLiabilities        balance >= escrowed + credits + fees
[PASS] invariant_balanceEqualsLiabilities        balance == escrowed + credits + fees
[PASS] invariant_conservationOfDeposits          deposited == refunds paid + fees paid + liabilities
[PASS] invariant_oneActiveReservationPerItem     <= 1 live reservation per item, item state agrees
[PASS] invariant_refundCreditsSum                sum(refundCreditOf) == totalRefundCredits
[PASS] invariant_reservationHistoryIsConsistent  settled once, snapshots immutable, rented never expires
[PASS] invariant_settlementTotalsMatch           credits/fees produced == paid + outstanding
 RentalEscrowInvariantTest invariants (runs: 64, calls: 3072, reverts: 0)
```

## Coverage of the requested validation list

| Requirement | Where |
|---|---|
| competing reservations | `test_reserve_competing_secondRenterRejected`, `testFuzz_competingReservations`, `invariant_oneActiveReservationPerItem` |
| duplicate actions | `test_*_twiceReverts*`, `test_reserve_retryWithSameRefRevertsAndNamesReservation`, `testFuzz_duplicateActionsSettleOnce`, handler `reserveDuplicateRef` |
| unauthorized callers | `test_*_unauthorized*`, `test_cancel_onlyRenter`, `testFuzz_unauthorizedCallersRejected`, handler `checkOutByStranger` / non-renter cancel |
| staff revocation | `test_staffRevocation_isImmediate`, handler `toggleStaff` with call-time checks |
| exact expiry boundaries | `test_cancel_boundary_lastSecondOkExactExpiryRejected`, `test_checkOut_boundary_rejectedAtExpiry`, `test_expire_byAnyoneAtExpiry`, `testFuzz_expiryBoundary_cancelVsExpire` |
| policy changes during existing reservations | `test_policyChange_doesNotAffectExistingReservation`, `testFuzz_policyChangeDoesNotLeak`, snapshot checks in `invariant_reservationHistoryIsConsistent` |
| refund retries | `test_withdrawRefund_paysOnceOnly`, `testFuzz_refundRetries`, handler `withdrawRefund` |
| accounting conservation | `invariant_balanceCoversLiabilities`, `invariant_balanceEqualsLiabilities`, `invariant_conservationOfDeposits`, `_assertConservation()` in unit/fuzz tests |
| exact deposit / fee-on-transfer | `test_reserve_feeOnTransferTokenIsRejected`, `testFuzz_reserve_exactDepositAndSnapshot` |
| admin cannot reach deposits/credits | `test_withdrawFees_adminOnlyAndBounded`, `test_withdrawFees_cannotReachEscrowedDeposits`, `testFuzz_feeWithdrawalBounded`, handler `withdrawFees` |

## Mutation sanity check (scratch, not delivered)

Five bugs were injected one at a time into `src/RentalEscrow.sol` and the suites re-run; the
source was restored byte-for-byte afterwards.

| Injected bug | Caught by |
|---|---|
| fees never accrue on cancel/expire | 3 invariants (`balanceEqualsLiabilities`, `conservationOfDeposits`, `settlementTotalsMatch`) |
| `cancel` ignores reservation status | `invariant_oneActiveReservationPerItem`, `invariant_reservationHistoryIsConsistent` ("settled twice") |
| expire boundary `<=` instead of `<` | 2 unit boundary tests + 2 fuzz tests |
| `onlyStaff` removed from `checkOut` | 2 unit tests, 1 fuzz test, handler assertion inside the invariant run |
| refund credit not zeroed on withdraw | handler assertion ("refund with credit reverted") inside the invariant run |

A separate scratch test confirmed that a failing assertion inside the invariant handler fails
the run under the delivered configuration (`fail_on_revert = true`); with the default
`fail_on_revert = false` it would have been silently swallowed, which is why the config pins it.

## Local demo on Anvil

```
$ script/demo.sh
== starting anvil on http://127.0.0.1:8545
== deploying (admin = token holder = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
   token  = 0x5FbDB2315678afecb367f032d93F642f64180aa3
   escrow = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
== seeding (staff = 0x7099...79C8, renter = 0x3C44...93BC funded with 1,000 dds)
     standard policy id: 1
     premium policy id:  2
     item ids: 1 2 3
== token facts
"kkk" / "dds" / 6 / 1000000000000
== quote for item 1 (policyId, (deposit, cancellationFee, reservationWindow))
1
(50000000, 5000000, 3600)
== renter approves the deposit and reserves item 1 with clientRef keccak('order-1')
   reservation id by ref: 1
   totalEscrowed: 50000000
== retrying the same reservation request reverts (no duplicate deposit)
   retry rejected as expected (ClientRefAlreadyUsed)
== a second renter cannot reserve the same item
   competing reservation rejected as expected (ItemNotAvailable)
== staff checks the item out, time passes, staff confirms return
   refund credit of renter: 50000000
== renter withdraws the refund (second withdrawal reverts)
   second withdrawal rejected as expected (NothingToWithdraw)
== second reservation on item 2, cancelled by the renter: fee is kept
   refund credit: 45000000   accrued fees: 5000000
== admin withdraws the earned fee; trying more than earned reverts
   over-withdrawal rejected as expected (InsufficientFees)
== final accounting
   escrow token balance: 0
   totalLiabilities:     0
   renter balance:       995000000  (started with 1000000000, paid one 5000000 fee)
== demo complete
```

## Checks that could not run

- Slither and Mythril: not installed on this machine, not run.
- Long fuzz campaigns (e.g. 10,000+ runs per test, hours of invariant depth): not run within
  the task's time budget; the commands are in the README.
- Explorer verification, multisig handover, public deployment: out of scope (source only).
