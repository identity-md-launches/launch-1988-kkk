# Rental event indexer — local development trial

This is a read-only event backend for the existing `RentalEscrow` ABI, including
`FeesWithdrawn(bytes32,address,uint256)`. It uses **Ponder 0.18.2** and a persistent
local **PGlite 0.2.13** directory. No database account, Docker, key or hosted service
is required. Production Ponder requires PostgreSQL and separate hosting; this trial
validates neither. No contract or existing Foundry dependency/configuration was changed.

## Runtime and clean-checkout installation

Supported offline target: **Linux x64, glibc, Node.js 24.x, npm 11.x, GNU tar and xz**.
Tested versions: Node 24.21.0, npm 11.19.0, Foundry 1.8.3, Solidity 0.8.26.
Put `forge`, `cast`, and `anvil` on PATH. Alternatively, set `ANVIL_BIN` to an Anvil
executable for the harness. The compiler remains pinned by the existing root
`foundry.toml`. Build the existing contracts first:

```sh
forge build
forge fmt --check
FOUNDRY_FUZZ_SEED=0xc6b413a08f5d387af6fe6349ea383bd6478498761e5e040031705165958de293 forge test
cd indexer
node --no-use-env-proxy scripts/install.mjs
npm run abi:check
npm run typecheck
npm test
node --no-use-env-proxy --test tests/install.test.mjs
npm run test:acceptance
```

`install.mjs` verifies the archive, unchanged package/lockfile hashes, safe archive paths,
and every retained file's SHA-256. It installs the committed `vendor/runtime.tar.xz`
without npm, network access, lifecycle scripts or services. Install into a fresh directory;
an existing `node_modules` is refused. `--check` verifies the archive without installing.
All dependencies needed by the documented commands are present; **no network is needed**.
Original licence/notice files and package metadata are retained. No submodules.

This is a compact distribution of this application, not a complete npm package cache.
`package.json` and `package-lock.json` remain unchanged. The packer verifies original
registry SHA-512 integrities, then retains byte-identical runtime files, declarations,
licences and database assets. `vendor/manifest.json` lists omissions by package/reason;
`.data/runtime-inventory.json` records every included hash and excluded path after install.
Unused upstream tests, source maps, duplicate builds, optional PostgreSQL extensions,
blob-transaction data and browser-build binaries are omitted. See
[`vendor/README.md`](vendor/README.md) for scope and reproducible regeneration.

`npm run dev` uses `scripts/runtime.mjs`: Node 24 loads TypeScript and Ponder's own virtual
modules; the original Ponder 0.18.2 validators, database, sync engine, rollback and HTTP
server execute unchanged. This version-specific bootstrap replaces Vite's loading step.
It supports this PGlite application and requires a restart after source edits. It is not
the upstream `ponder dev` CLI, has no hot reload, and does not support arbitrary Vite
plugins or general-purpose package APIs. New imports require rebuilding the runtime
selection and rerunning all checks. Direct upstream CLI commands are not supported by
the compact offline distribution. No dependency version or upstream source was patched.

Node's environment-proxy handling is disabled for local scripts so loopback traffic
stays local. The backend transport rejects non-loopback URLs, redirects and non-read RPC methods.

To regenerate ABIs reproducibly after an authorized contract change:

```sh
# Repository root
forge build
cd indexer
npm run abi:generate
npm run abi:check
```

`abi:check` compares the committed TypeScript constants byte-for-byte with the current
Foundry artifacts; it fails on drift. It does not download an ABI or modify contracts.

## Demo, restart, and cleanup

```sh
cd indexer
npm run demo
```

The demo runs the real acceptance scenarios, then leaves its isolated Anvil, read-only
RPC proxy, and query API running on **127.0.0.1** using automatically selected free ports.
It deploys only the existing `MockPaymentToken` and `RentalEscrow` contracts, funds
synthetic renters from Anvil's public development accounts, and prints the API URL
and generated configuration path. No existing chain, funded wallet, or public RPC is used.

At the demo prompt:

```text
restart
reconcile
quit
```

`restart` stops only this harness's indexer child, starts it again with the **same**
database, and waits for catch-up. `reconcile` compares that indexed snapshot to contract
reads at its block. `quit` or Ctrl-C stops only processes the harness started and retains
its database/logs under `.data/trial-*/`. An unattended demo/restart check is:

```sh
npm run demo -- --commands=restart,reconcile,quit
```

While the demo remains running, another terminal can use the printed API URL and config:

```sh
RENTAL_CONFIG=/absolute/path/printed/by/demo/config.json npm run reconcile
curl --noproxy '*' http://127.0.0.1:PRINTED_API_PORT/sync
```

For an independently managed **local** chain and the existing deployed escrow:

1. Copy `config.example.json` to your own JSON file and fill in the actual deployment
   receipt's address and block, RPC URL, and a new database directory.
2. Run `RENTAL_CONFIG=/absolute/path/to/config.json npm run dev`.
3. Ctrl-C and repeat that exact command to restart with the same database while the
   chain remains running. Do not run two instances against one database.
4. Stop the process before archiving its directory. Keep chain state alive across
   restarts; creating a new Anvil chain normally requires a separate database directory.

The example address is deliberately invalid until replaced; no fabricated usable
contract address is supplied. The demo generates the real parameters automatically.
`deploymentBlock` must include the escrow constructor's `AdminTransferred` event.
The startup guard pins chain ID, genesis hash, deployment block/hash, deployed code
hash, contract address, and reorg-window setting in `databaseDirectory/identity.json`.
A mismatch fails rather than mixing deployments. It never silently deletes a database.
A process lock rejects simultaneous use; stale lock PIDs are checked, never killed.

### Recovery semantics

**The compact runner uses Ponder's `dev` database mode, which rebuilds projection/history
tables on startup**, even when the persistent
PGlite directory is reused. With `cacheRpcRequests: false`, it fetches chain data again.
Thus the demonstrated recovery is deterministic replay into the same database, **not
incremental projection resumption**. The acceptance test separately checks normal restart,
SIGKILL after a visible partial catch-up checkpoint, and a new empty database rebuild.
It never deletes the original database to make recovery pass.

The harness refuses transactions unless the URL uses a literal loopback host, the RPC
reports Anvil, and chain ID is exactly 31337. That guard runs before every deployment
and transaction. It uses unlocked public Anvil development accounts; there is no wallet
key in backend configuration or source. The production-facing source (`src/`, `shared/`,
`ponder.config.ts`, reconciliation and startup scripts) does not submit transactions.

## Configuration

`RENTAL_CONFIG` is the only configuration-file selector. The file is JSON, not a secret
store. `.env.example` documents it; creating an actual `.env` file is unnecessary.

| Field | Meaning |
|---|---|
| `rpcUrl` | Plain HTTP on `127.0.0.1` or `[::1]`; no credentials, query, fragment or redirects |
| `chainId` | Positive safe integer, default 31337; must match RPC (harness always requires 31337) |
| `contractAddress` | Existing escrow address from its local deployment receipt |
| `deploymentBlock` | Non-negative safe integer; includes constructor event |
| `databaseDirectory` | Persistent directory; PGlite lives in its `pglite/` child |
| `apiPort` | Loopback API port, 1024–65535; default 42069 |
| `reorgWindow` | Ponder rollback window in chain-timestamp seconds, 1–600; default/tested 120 |

Relative file/directory paths are relative to the `indexer/` working directory.
API host binding is deliberately fixed to loopback. No deployment command runs on install.

## Queries and exact values

All domain endpoints are GET-only. Amounts, uint256 IDs, timestamps and block numbers
are decimal **strings**; state enums/log positions are small integers. Values never pass
through floating-point arithmetic. Payments are in the mock token's 6-decimal base units.
Every domain response includes a freshly evaluated `status` and `Cache-Control: no-store`.

| Endpoint | Result |
|---|---|
| `/equipment/available` | Listed items with state Available, and current quote policy |
| `/reservations/1` | Accepted policy/deposit/fee/created/expiry terms and current reservation status |
| `/renters/0x…` | Renter's reservations, lifecycle/payment activity and outstanding refund credit |
| `/fees/0x…` | Completed bytes32 request result, recipient, actual amount and transaction hash |
| `/snapshot` | One consistent domain projection including roles, policies, credits and totals |
| `/history?offset=0&limit=100` | Canonically ordered decoded event history; maximum page size 1000 |
| `/sync` | Indexed block/hash, current observed head/hash, lag, connection error and finality window |

Unknown reservations/fee IDs return 404; malformed inputs return 400. A missing fee
result is not evidence that a pending transaction failed. Renter results include reservations and paginated `activity` (use `offset`/`limit`);
payment events also remain inspectable in `/history` as `RefundCredited`,
`RefundWithdrawn`, and `FeesWithdrawn`. History rows carry chain ID, escrow address,
block number/hash, transaction hash/index and log index. No submitted transaction intent
or off-chain payment status is invented.

Example available-equipment request:

```sh
curl --noproxy '*' "$API/equipment/available"
curl --noproxy '*' "$API/reservations/1"
curl --noproxy '*' "$API/renters/$RENTER"
curl --noproxy '*' "$API/fees/$REQUEST_ID"
curl --noproxy '*' "$API/history?offset=0&limit=100"
```

The checked-in `evidence/` contains actual synthetic API responses and acceptance results.
During an outage, `/sync` reports `current: false`, `connectionError`, and no pretend live
head/lag. During catch-up it reports positive lag. A mismatched indexed block hash reports
an error. Framework `/health`, `/ready` and `/status` are **not freshness indicators**.

### Provisional versus finalized

`current: true` means this snapshot matched the latest canonical block observed during
that request. It is not an eternal assertion: another block can arrive immediately.
Latest state is normally `projectionFinality: "provisional"`. Ponder retains rollback
information over the configured chain-timestamp window. `finalizedThroughTimestamp`
shows the timestamp threshold, **not a proof of consensus finality**. A projection older
than that threshold is labelled `finalized-within-configured-window`; operators must
choose a suitable finality policy for any future real chain integration.

The live test observes an orphan branch and reverts four blocks within the 120-second
window, then mines a distinct canonical branch. Ponder rolls back both onchain tables.
Deeper resets, changes before the deployment anchor, hostile RPC providers, and public
chain finality are not validated. Do not treat a development chain reset as a supported
production reorg. Stop, investigate the status/error, and use a separate directory for a
new deployment. History pagination is a live provisional view; freeze chain activity at
a common block for a multi-page audit. The single-row `/snapshot` is internally consistent.

## Accounting and replay design

`shared/domain.ts` applies the existing ABI in canonical order. Immutable policy rows
are never updated. Reservations store their original accepted values independently of
later item policy changes. Checkout makes the item Rented and retains its active ID.
Only settlement releases the item. Only `RefundCredited` increases credits; settlement
domain events move escrow and fees. Withdrawal events subtract their **actual** amounts.
Totals include escrow, outstanding refunds, accrued fees, liabilities, and historical
refund/fee payments. Donations are not inferred from token balance.

For this bounded local dataset, the domain is stored as one JSONB projection row, with
all amounts as decimal strings. This makes each API snapshot atomic and easy to audit.
It is intentionally not a production-scale relational indexing design: rewriting the
projection is O(total domain size). Event history is a separate Ponder onchain table.

Deduplication has three layers:

* Application transport removes exact repeated log payloads at one block/log position.
  Different payloads at that position fail visibly. The test proxy duplicates actual
  `eth_getLogs` responses in historical and live ingestion, not a mocked reducer call.
* Ponder validates RPC consistency, orders canonical events, deduplicates overlapping
  framework fetches, and rolls back its onchain tables for supported short reorgs.
* The handler guards history IDs `(chainId, contract, transactionHash, logIndex)` before
  applying accounting. A reused ID with a different block hash fails unless Ponder has
  already rolled it back. Primary keys provide an additional database uniqueness check.

## Same-block reconciliation

```sh
RENTAL_CONFIG=/absolute/path/to/config.json npm run reconcile
# Optional explicit loopback API base URL:
RENTAL_CONFIG=/absolute/path/to/config.json npm run reconcile -- http://127.0.0.1:42069
```

This reads `/snapshot` once and pins **all** contract/token calls to its indexed block
number, checking that block's hash before and after the reads. It compares item and
reservation counts/state/terms, immutable policies, reservation references, staff/admin,
refund credits, fee request results, escrow/refund/fee totals and total liabilities.
It accepts token balance **greater than** liabilities (donations), and rejects balance
below liabilities. It requires a complete, canonical snapshot; catch-up lag alone is not
an error because the comparison still uses the same historical block.

A mismatch prints `RECONCILIATION FAILED` and exits 1. It never patches the database with
latest chain reads. The acceptance suite checks both successful CLI exit 0 and a real
CLI exit 1 for a deliberately corrupted API snapshot, then confirms the actual projection
was not modified. The local RPC must retain historical state for the indexed block.

## Tests and evidence

`npm test` covers arithmetic, immutable terms, state transitions, duplicate/conflicting
logs, configuration rejection and lossless uint256 serialization. `npm run test:acceptance`
uses actual Anvil receipts and assertions against the running Ponder query API:

* A: reserve/checkout/return/cancel/expire, policy change, revoked staff failure, refund
  payments, fee retries/conflicts/new IDs, admin handover, metadata/listing and donations.
* B: stop, transact, restart the same database; then kill during visible partial catch-up
  and recover, retaining the original database directory.
* C: inject duplicates into real RPC log responses; compare unique history to canonical
  raw logs and reconcile exactly-once credits/fees.
* D: block RPC while Anvil continues, assert stale status and ingestion errors, create
  activity, restore RPC and verify catch-up.
* E: observe a branch, snapshot/revert Anvil, mine a different branch; verify orphaned
  reservation, refund/fee effects, fee request and history disappear, then reconcile.
* F: replay into a separate empty database and compare all domain data/history at the
  same block, then reopen the original database again.

All polling has deadlines. Individual RPC calls have 1.5-second timeouts; transactions
have 10-second receipt deadlines; catch-up is bounded to 60 seconds (90 after crash).
No real-time wait longer than the task budget is required. See
[`../docs/BACKEND-TRIAL.txt`](../docs/BACKEND-TRIAL.txt) for measured results and failures
encountered during development. Tests are evidence, not a security audit.

Official references used for this pinned implementation:
[Foundry integration and disabling RPC cache](https://ponder.sh/docs/guides/foundry),
[PGlite versus PostgreSQL](https://ponder.sh/docs/database),
[configuration / reorg window](https://ponder.sh/docs/api-reference/config),
[custom API endpoints](https://ponder.sh/docs/query/api-endpoints),
[CLI and dev mode](https://ponder.sh/docs/api-reference/ponder-cli).
The installed 0.18.2 source was also checked for RPC validation, event ordering, rollback,
and dev-mode projection recreation; no framework code was patched. The compact bootstrap
uses private, version-pinned Ponder interfaces and is application code, not an upstream
supported CLI mode. A Ponder upgrade requires review and full acceptance retesting.
