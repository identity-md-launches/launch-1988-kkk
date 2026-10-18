# Reconciliation completeness repair

Local verification date: 2026-10-18. This continues delivered commit
`14b7205477fc0b98d11f761f429c848a1b328316`. Source and local test delivery only.

The former reconciler enumerated fee requests and staff from the snapshot under test,
so deleting a record could evade checking. It also left `feesPaid` and `refundsPaid`
unchecked. The repair independently scans canonical escrow events from the configured
deployment block through the snapshot's indexed block. It compares both membership
directions and values, sums actual historical payments with `bigint`, and cross-checks
fee/staff events against storage at that same block. The projection reducer and rental
rules are unchanged. See [the precise guarantees and limits](../indexer/README.md#same-block-reconciliation).

`shared/reconcile-events.ts` is a separate event audit, not a replay of the projection
or its history table. Its input is only configuration, the anchored block and the
read-only RPC client. It uses the existing transport's duplicate/conflict checks and
read-method allowlist, strict ABI decoding, canonical block/transaction checks, bounded
consecutive ranges, and the constructor event as a deployment-boundary check. Existing
current-obligation, token-balance, donation and before/after block-hash checks remain.

## Scope and installation restrictions

No contract, existing Solidity test, deployment script, ABI, Foundry configuration,
dependency version, dependency archive, lockfile, framework or CI file was changed.
SHA-256 comparison confirmed 337 existing contract/test/script/config/dependency/ABI
files unchanged. The backend remains read-only; only the existing guarded harness uses
unlocked public Anvil development accounts on isolated chain 31337. Services bind to
literal loopback. No keys, public-chain transactions, hosting or paid services are used.

The assignment protects `node_modules/`. Installation and all generated backend data
were therefore confined to its expressly permitted `test/scratch/` test area. The
existing installer and installer tests ran unchanged against an exact source copy,
using only the committed archive. Changes to delivered sources were copied into that
test copy before the final checks. No dependency installation is part of the change.

## Actual commands and tools

Commands below were run from the repository root. Output redirection only kept logs
under `test/scratch/reconciliation/`; no environment/configuration files were edited.

```sh
forge --version
anvil --version
cast --version
node --version
npm --version
tar --version
xz --version
forge build
FOUNDRY_FUZZ_SEED=0xbe52dbff4856726889961e0a0e282e7034542c0d1442fa79b4e1fb66b03a544b forge test
forge fmt --check

mkdir -p test/scratch/reconciliation
cp -a indexer test/scratch/reconciliation/indexer
node --no-use-env-proxy test/scratch/reconciliation/indexer/scripts/install.mjs
node --no-use-env-proxy --test test/scratch/reconciliation/indexer/tests/install.test.mjs
npm_config_update_notifier=false npm --prefix test/scratch/reconciliation/indexer run abi:check
npm_config_update_notifier=false npm --prefix test/scratch/reconciliation/indexer run typecheck
npm_config_update_notifier=false npm --prefix test/scratch/reconciliation/indexer test
npm_config_update_notifier=false npm --prefix test/scratch/reconciliation/indexer run format:check
npm_config_update_notifier=false npm --prefix test/scratch/reconciliation/indexer run test:acceptance
npm_config_update_notifier=false npm --prefix test/scratch/reconciliation/indexer run demo -- --commands=restart,reconcile,quit
```

The scratch installation's pinned Prettier executable formatted only the changed
TypeScript files. ABI check compared existing generated ABIs to the Foundry artifacts.
Compiler metadata, package versions and preserved-file hashes were read locally.

| Component | Actual version |
|---|---|
| forge / cast / anvil | 1.8.3, commit `cae51ad458f6abb64852b7709eb784352429825d` |
| Solidity (artifact metadata) | `0.8.26+commit.8a97fa7a` |
| Node / npm | 24.21.0 / 11.19.0 |
| GNU tar / xz | 1.35 / 5.4.5 |
| Ponder / PGlite | 0.18.2 / 0.2.13 |
| viem / Hono | 2.57.7 / 4.13.13 |
| TypeScript / Prettier / @types/node | 5.9.3 / 3.6.2 / 24.10.1 |

## Results

| Check | Result |
|---|---|
| `forge build` | PASS; 46 files compiled with pinned Solc 0.8.26 |
| `forge test`, required seed | PASS; all 85 existing individual checks, 0 failures/skips |
| `forge fmt --check` | PASS; Solidity unchanged |
| Offline installation | PASS; 8,860 verified existing runtime files |
| Installer checks | PASS; all 4 unchanged success/failure tests |
| Backend unit tests | PASS; original 8 plus 1 new independent event audit test |
| Typecheck / ABI check / backend formatting | PASS |
| Final live A–F and new reconciliation checks | PASS; real local Anvil transactions, CLI and read-only source fault proxy |
| Demo / same-database restart / reconciliation / cleanup | PASS; exit 0, same database and block/hash after restart |

Foundry reports 78 runner results across seven suites: its single invariant runner
prints PASS for all eight individual invariants (64 runs, depth 48, 3,072 calls, no
handler reverts). Fuzz functions ran 256 cases each. No tests were removed or weakened.
Existing timestamp/warp lint warnings remain; there were no compilation failures.
The added unit fixture checks payment sums above JavaScript's safe integer range and
ordering of staff changes within one block. Live tests use the unchanged fixed-supply
mock token, so these extreme amounts are unit coverage, not live transaction coverage.

The first expanded live run passed A–F and all ten CLI corruption cases but failed a
new source-fault test's diagnostic assertion: changing every log's block number created
conflicting positions before the intended range validation. The fault fixture was
corrected to move one log only; the rejection assertion was retained. No production
check was relaxed. Full final rerun results and measured evidence are recorded below.

The final acceptance command exited 0. Its ten separately corrupted snapshots each
failed both direct reconciliation and the real CLI (exit 1); matching data and a valid
revocation exited 0. Every rejection preserved both projection and history, and the
direct function preserved its input. The four requested failures have their actual
CLI diagnostics recorded in
[`reconciliation-acceptance.json`](../indexer/evidence/reconciliation-acceptance.json).
The other cases cover an incorrect current escrow total, unexpected fee and disabled
staff records, and incorrect staff state, fee amount and payment transaction hash.

That same run rejected eleven independent RPC source faults, verified both block-hash
guards and a wrong deployment boundary, and accepted reversed/duplicate logs across
six consecutive bounded ranges. After later refund/fee payments and staff revocation,
both the retained historical snapshot and the current snapshot reconciled. Removing
the now-revoked staff record also failed. A–F retained donation surplus 123 and verified
actual restart, crash recovery, outage recovery, orphan removal and a separate rebuild.

The separate demo command also exited 0 after repeating all acceptance and fault checks,
then executing `restart,reconcile,quit`. The restarted projection reconciled at block
116, with token balance **13,000,123**, liabilities **13,000,000**, and surplus **123**.
Its block hash matched the snapshot before restart. The harness completed its owned
process cleanup. Measured run data and the post-restart result are in
[`reconciliation-demo.json`](../indexer/evidence/reconciliation-demo.json).
[`reconciliation-checks.json`](../indexer/evidence/reconciliation-checks.json) records
versions, results, the exact fuzz seed and hashes of the tested implementation/test files.

## Operational responsibilities and coverage limits

Operators supply the actual local deployment receipt's escrow address and block,
loopback RPC, chain ID, database directory and API port. The test harness generates
these from its own disposable deployment; no usable fabricated deployment settings
are supplied. The constructor event must be included. Keep the chain and historical
state/logs available across restarts. Startup's existing deployment/genesis/code-hash
identity guard and database lock remain unchanged. Do not mix deployments in one DB.

Investigate errors and status lag, allow canonical catch-up after a short reorg, then
rerun reconciliation. The command exits nonzero on errors and never repairs storage.
The configured rollback window is 120 seconds of chain timestamps. Ponder's existing
dev-mode restart rebuilds the projection in the same database; this remains replay
recovery, not incremental resumption. Latest data remains provisional.

Reconciliation depends on complete, honest local RPC history and historical state.
It does not verify receipt inclusion proofs or prove that an RPC has returned every
event. A consistently dishonest provider or silently omitted refund history can defeat
event-only checks. `/history`, its ordering/pagination, `eventCount`, `lastEvent`, cursor
timestamp and arbitrary schema fields are not fully audited by this command. It does
not establish token transfer history, donation provenance, pending/reverted intentions,
off-chain payments, or future/finalized correctness. Full scans grow with history.

Not run or approved: public deployment/RPC, funded wallets, production PostgreSQL or
hosting, deep reorgs/resets, large-history/load benchmarks, other runtime platforms,
Slither/Mythril, independent security audit or production release approval. All requested
local checks completed; no requested local implementation or validation remains partial.
