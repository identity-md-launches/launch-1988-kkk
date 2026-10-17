# Final local check results

Date: 2026-10-17. Results below are from the final source/test tree, not copied from the
previous delivery. No scratch Solidity tests are part of this inventory or build.

## Exact tools and configuration

| Tool | Version actually used |
|---|---|
| forge, cast, anvil | 1.8.5, commit `51a52c59cffd940f76eddd0b4bb1791aa4b5ac7f`, dist build |
| Solidity | `0.8.26+commit.8a97fa7a` (verified in the built escrow's compiler metadata) |
| Python (demo receipt assertions) | 3.12.3 |
| Bash (demo) | 5.2.21(1)-release |
| Existing vendored forge-std / OpenZeppelin Contracts | v1.9.7 / v5.1.0; unchanged |

The existing `foundry.toml` remains unchanged: solc 0.8.26, Cancun, optimizer 200 runs,
no via-IR, no FFI or filesystem permissions, 256 fuzz runs, 64 invariant runs at depth 48,
and `fail_on_revert = true`. No dependencies were added or changed.

## Checks run and results

| Check | Actual result |
|---|---|
| `forge build --force` | exit 0; 46 files compiled with Solc 0.8.26; compiler successful |
| `forge build` | exit 0 |
| `forge fmt` on the changed Solidity files | completed successfully |
| `forge fmt --check` | exit 0; no formatting diff |
| Full `forge test` with the seed below | exit 0; all 85 individual tests/invariants pass |
| `forge test --list --json` | exit 0; inventory totals 85 individual functions across 7 suites |
| `bash -n script/demo.sh` | exit 0 |
| `script/demo.sh` | exit 0; local Anvil deployment, seed, rental/refund flows, fee retries and final accounting passed |

The forced build emitted four existing `environment-read-across-mutation` lint warnings
about `block.timestamp` around `vm.warp` in `test/RentalEscrow.t.sol` (three) and
`test/RentalEscrowFuzz.t.sol` (one). No Solidity compiler warnings or source-contract lint
warnings were emitted. These test-only notes did not fail the build.

The focused `WithdrawalRecoveryTest` suite also passed before the full run, using the same seed.
The full final run used:

```bash
FOUNDRY_FUZZ_SEED=0x447c6d16f6b8f650c2df614a0c8806cd5c423244a0b73be68e845fcb6b8b2fbd forge test
```

Actual runner footer:

```text
Ran 7 test suites in 6.75s (11.02s CPU time): 78 tests passed, 0 failed, 0 skipped (78 total tests)
```

**Count correction:** the original tree contains 71 individual tests/invariants
(47 + 9 + 8 + 4 + 3), although the earlier report said 64. Foundry 1.8.5 groups the eight
invariants into a single runner result. The final tree contains **85 individual functions**:
66 unit/regression tests, 11 fuzz tests and 8 invariants. Its runner footer therefore reports
78 results (77 unit/fuzz tests plus the one group of eight invariants), not 85. All original
71 functions remain; the 14 additions are 13 withdrawal-recovery tests and one harness regression.

| Suite | Individual functions | Final result |
|---|---:|---|
| `RentalEscrowTest` | 47 unit | all pass |
| `RentalEscrowFuzzTest` | 9 fuzz | all pass, 256 runs each |
| `MockPaymentTokenTest` | 3 unit + 1 fuzz | all pass, fuzz 256 runs |
| `ScriptsTest` | 3 unit | all pass |
| `WithdrawalRecoveryTest` | 12 unit + 1 fuzz | all pass, fuzz 256 runs |
| `RentalEscrowHandlerTest` | 1 unit | pass |
| `RentalEscrowInvariantTest` | 8 invariants | all pass together: 64 runs, 3,072 handler calls, 0 reverts |
| **Total** | **85** | **0 failures, 0 skipped** |

## Maintenance regressions and preserved coverage

| Requirement | Evidence |
|---|---|
| Earn 10 dds, request 5 dds, retry without paying twice; fresh ID pays remaining 5 | `test_feeRetry_tenEarnedFiveRequestedPaysOnce_newIdPaysRemainder`; real new-nonce transactions in the demo |
| Durable lookup, indexed request ID/recipient event, no second payout event | result assertions and event assertions in the same regression; original fee-event assertion updated |
| Same ID with different recipient or amount | `test_feeRetry_conflictingRecipientRejected`, `test_feeRetry_conflictingAmountRejected`, arbitrary-ID/payload fuzz test |
| Completed ID stays protected when more fees accrue | `test_feeRetry_oldIdProtectedAfterNewFeesAccrue` |
| Failed transfer leaves ID unused and preserves fees, live deposits and refund credits | false-return and token-revert rollback tests; both retry the same ID successfully after clearing the simulated token failure |
| Insufficient fees do not consume the request | `test_feeWithdrawal_insufficientFeesDoesNotConsumeId` |
| Admin handover retains results, rejects old/pending admin calls and allows a fresh ID | `test_feeRetry_survivesAdminHandover` |
| Missing ID and old ABI cannot bypass deduplication | nonzero-ID and legacy-selector regressions |
| Refund call after a new settlement pays only the new credit | `test_refundRecovery_interveningSettlementPaysOnlyNewAggregateCredit`: cancellation 45 dds then return 50 dds; event totals reconcile, a third call with no credit reverts |
| Item checkout projection agrees with reservation and `getItem` | retained `test_checkOut_byStaff` asserts `ItemCheckedOut`, both `Rented` states and unchanged active ID; `invariant_oneActiveReservationPerItem` checks ongoing agreement |
| Existing rental/accounting behavior | all original unit/fuzz/invariant tests retained: competing reserves, exact deposits, policy snapshots, boundaries, authorization/revocation, settlement-once, refund aggregation, fee bounds, conservation |

The first run on the original code with the required seed found an existing harness overflow:
`cancel(uint256.max, false)` evaluated `reservationSeed + 1` before selecting a renter. The
minimal failing sequence was reserve, then cancel with that maximum seed. Reducing the seed
modulo renter count before adding fixes the test driver without changing escrow behavior.
`test_cancel_maximumSeedDoesNotOverflowHandler` reproduces that sequence and verifies that the
non-renter cancellation is rejected normally. The final full seeded invariant run passes;
`fail_on_revert` was not weakened. The handler's fee call now supplies a unique request ID
for each intended new withdrawal, preserving its original fee-bound and conservation checks.

## Local Anvil demo evidence

`script/demo.sh` started and stopped its own local Anvil. It used only the repository's
well-known development accounts. Its receipt assertions checked successful transactions and
forced the duplicate/conflict fee attempts to be mined at distinct sender nonces with status
0 and no surviving logs. The script prints each transaction hash, sender nonce and status.

| Action | Sender | Nonce | Receipt status |
|---|---|---:|---|
| Withdraw 50 dds from returned reservation | renter | 2 | 1 |
| After another reservation cancels, withdraw its new 45 dds credit | renter | 6 | 1 |
| Withdraw another 45 dds cancellation credit | renter | 10 | 1 |
| First fee ID pays 5 dds out of 10 earned | admin | 9 | 1 |
| Same ID/payload in another transaction | admin | 10 | 0; no logs, 5 dds fees still accrued |
| Same ID, conflicting recipient | admin | 11 | 0; no logs, 5 dds fees still accrued |
| Fresh ID pays remaining 5 dds | admin | 12 | 1 |

Both fee lookups returned the original recipient, amount `5000000` and `completed = true`.
The duplicate reservation, competing reservation, empty-credit refund and fee overdraw
preflight checks also rejected as expected. Final assertions and output:

```text
== final accounting
   escrow token balance: 0
   totalLiabilities:     0
   renter balance:       990000000 [9.9e8]  (started with 1000000000, paid two 5000000 fees)
== demo complete
== stopping anvil
```

## Final per-function inventory

Generated from `forge test --list --json` and cross-checked against the 85 individual PASS
lines in the full seeded run. Fuzz iteration counts and invariant calls are not counted as
additional tests.

### `test/MockPaymentToken.t.sol:MockPaymentTokenTest` (4)

```text
testFuzz_transferConservesSupply
test_fixedSupplyMintedToHolder
test_metadata
test_rejectsZeroHolder
```

### `test/RentalEscrow.t.sol:RentalEscrowTest` (47)

```text
test_adminHandover_cancelPending
test_adminHandover_twoStep
test_cancel_afterCheckoutReverts
test_cancel_boundary_lastSecondOkExactExpiryRejected
test_cancel_creditsDepositMinusFee
test_cancel_onlyRenter
test_cancel_twiceReverts
test_cancel_unknownReservation
test_cancel_withFullFeePolicyCreditsNothing
test_cancel_withZeroFeePolicyCreditsEverything
test_checkOut_afterCancelReverts
test_checkOut_boundary_rejectedAtExpiry
test_checkOut_byStaff
test_checkOut_twiceReverts
test_checkOut_unauthorizedCallers
test_confirmReturn_creditsFullDeposit
test_confirmReturn_requiresRentedStatus
test_confirmReturn_twiceReverts_singleCredit
test_confirmReturn_unauthorized
test_constructor_revertsOnZeroAddresses
test_constructor_setsTokenAndAdmin
test_createPolicy_validation
test_delistingDuringReservation_doesNotBreakLifecycle
test_expire_byAnyoneAtExpiry
test_expire_cancelledOrUnknownReverts
test_expire_longAfterExpiryStillWorksOnce
test_expire_rentedItemsNeverExpire
test_fullLifecycle_itemReusedAcrossManyRentals
test_items_adminManagement
test_policyChange_doesNotAffectExistingReservation
test_reserve_competing_secondRenterRejected
test_reserve_feeOnTransferTokenIsRejected
test_reserve_happyPath
test_reserve_insufficientAllowanceOrBalanceTakesNothing
test_reserve_rejectsStalePolicyQuote
test_reserve_rejectsUnknownOrDelistedItem
test_reserve_rejectsZeroRef
test_reserve_retryWithSameRefRevertsAndNamesReservation
test_reserve_sameRefDifferentRentersAreIndependent
test_setStaff_onlyAdmin
test_staffRevocation_isImmediate
test_views_revertOnUnknownReservation
test_withdrawFees_adminOnlyAndBounded
test_withdrawFees_cannotReachEscrowedDeposits
test_withdrawRefund_accumulatesAcrossReservations
test_withdrawRefund_isPerBeneficiary
test_withdrawRefund_paysOnceOnly
```

### `test/RentalEscrowFuzz.t.sol:RentalEscrowFuzzTest` (9)

```text
testFuzz_competingReservations
testFuzz_duplicateActionsSettleOnce
testFuzz_expiryBoundary_cancelVsExpire
testFuzz_feeWithdrawalBounded
testFuzz_policyChangeDoesNotLeak
testFuzz_refundRetries
testFuzz_rentedNeverExpires
testFuzz_reserve_exactDepositAndSnapshot
testFuzz_unauthorizedCallersRejected
```

### `test/Scripts.t.sol:ScriptsTest` (3)

```text
test_deploy_rejectsZeroConfig
test_deploy_wiresTokenAndEscrow
test_seed_createsDemoStateAndFundsRenter
```

### `test/WithdrawalRecovery.t.sol:WithdrawalRecoveryTest` (13)

```text
testFuzz_feeRetry_arbitraryIdAmountAndConflictingPayload
test_feeLookup_unusedRequest
test_feeRetry_conflictingAmountRejected
test_feeRetry_conflictingRecipientRejected
test_feeRetry_oldIdProtectedAfterNewFeesAccrue
test_feeRetry_survivesAdminHandover
test_feeRetry_tenEarnedFiveRequestedPaysOnce_newIdPaysRemainder
test_feeWithdrawal_falseTransferRollsBackAndSameIdCanRetry
test_feeWithdrawal_insufficientFeesDoesNotConsumeId
test_feeWithdrawal_legacySelectorCannotBypassRequestId
test_feeWithdrawal_requiresNonzeroId
test_feeWithdrawal_revertedTransferRollsBackAndSameIdCanRetry
test_refundRecovery_interveningSettlementPaysOnlyNewAggregateCredit
```

### `test/invariant/RentalEscrowHandler.t.sol:RentalEscrowHandlerTest` (1)

```text
test_cancel_maximumSeedDoesNotOverflowHandler
```

### `test/invariant/RentalEscrowInvariant.t.sol:RentalEscrowInvariantTest` (8)

```text
invariant_adminUnchanged
invariant_balanceCoversLiabilities
invariant_balanceEqualsLiabilities
invariant_conservationOfDeposits
invariant_oneActiveReservationPerItem
invariant_refundCreditsSum
invariant_reservationHistoryIsConsistent
invariant_settlementTotalsMatch
```

## Scope and checks not performed

All requested maintenance requirements are complete. Source, local tests, local demo and
documentation only; no public deployment, traded token, pool or website was created.
No token source, supply or public-chain token state was changed.

Slither, Mythril, long fuzz campaigns beyond the configured runs, mutation testing and an
independent adversarial review were not run in this iteration. No historical mutation-run
claims from the previous report are presented as checks of this final tree. Passing these
local checks is not an independent security audit.
