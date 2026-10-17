# Compact offline application runtime

`runtime.tar.xz` is a **7,542,204-byte** distribution of this rental application's
runtime and development checks, replacing the rejected 40,050,000-byte npm cache.
The aggregate SHA-256 is in `runtime.sha256` and `manifest.json`. Node 24, GNU tar
and xz install it with no registry access, npm invocation, account, or lifecycle script:

```sh
node --no-use-env-proxy scripts/install.mjs --check
node --no-use-env-proxy scripts/install.mjs
```

Use a fresh checkout/directory: the installer refuses existing `node_modules`.
It verifies the unchanged package/lockfile hashes, the reviewed module selection,
archive checksum, regular-file-only paths, and every retained file's SHA-256.
It writes the full file/exclusion inventory to `.data/runtime-inventory.json`.
Runtime files are **byte-identical** to their original locked registry packages.
The packer validates every original tarball's SHA-512 against the unchanged lockfile.
All original package metadata, licences and notices are retained, including the
PGlite WASM/data files and TypeScript declarations needed by this application.

The supported commands are the ABI check/generation, TypeScript check, unit and
installer tests, formatting check, local demo/indexing/restart, live acceptance suite,
and reconciliation documented in the indexer README. Linux x64/glibc, Node 24.21.0,
npm 11.19.0, GNU tar 1.34 and xz 5.2.5 were tested.

This is **not a complete npm cache or a general-purpose installation of each package**.
The lockfile is unchanged; no dependency was upgraded, downgraded, or source-patched.
`manifest.json` lists all 176 cached package entries, their source/integrity/version,
and file exclusion counts/reasons. There are 25 absent optional platform entries.
The archive retains 8,860 files. `runtime-selection.json` lists the 2,716 runtime
modules observed across real tests, reconciliation, TypeScript and formatting commands.
Declarations and notices are also retained regardless of runtime module coverage.

Excluded files include upstream tests/examples, source maps, duplicate source/CJS
builds, unused compiler server/localizations, optional PostgreSQL extensions, KZG
blob-transaction data, and modules outside this application's tested import graph.
Ponder's Vite/Rolldown/Lightning CSS browser-build toolchain is not required by the
compact runner. `scripts/runtime.mjs` instead loads the application's TypeScript with
Node 24 and Ponder's own virtual-module factory, then invokes the **original Ponder
0.18.2 validation, database, indexing, reorg and HTTP modules**. It uses dev database
semantics (projection rebuild on restart) but has no hot reload. Restart after edits.
This bootstrap depends on private Ponder interfaces and is not an upstream CLI mode.
Direct `ponder` CLI, arbitrary Vite plugins, unused library APIs, and alternative
formatter languages are not supported by this application-scoped distribution.

## Reproduce the distribution

No download occurs in the generator. Given an isolated npm content-addressed cache
containing the original tarballs named by `package-lock.json`, run from `indexer/`:

```sh
node --no-use-env-proxy scripts/vendor-cache.mjs /absolute/path/to/isolated/npm-cache
node --no-use-env-proxy scripts/install.mjs --check
```

Generation requires Python 3.10+ with its standard `lzma` library (tested 3.10.12).
`vendor-runtime.py` verifies registry integrities, applies explicit pruning rules,
requires every selected runtime module to survive, writes per-file hashes and exact
exclusions, and emits sorted USTAR records with zero timestamps/owners and XZ preset
9/extreme compression. Two independent rebuilds in the repair produced identical
archive/checksum/manifest files. The original cache is a maintainer input, not needed
for installing or running the delivered application. No user npm cache/config is read.

When application imports or tool requirements change, repeat real runtime tracing
against a complete isolated install, review the selection, regenerate and test a
**fresh offline install**. Do not assume coverage makes arbitrary future imports work.
To collect only project dependency paths (no source, environment or RPC data):

```sh
# In an isolated complete copy of indexer/, after installing its locked graph:
NODE_OPTIONS="--import $PWD/scripts/trace-modules.mjs" npm test
NODE_OPTIONS="--import $PWD/scripts/trace-modules.mjs" npm run typecheck
NODE_OPTIONS="--import $PWD/scripts/trace-modules.mjs" npm run format:check
NODE_OPTIONS="--import $PWD/scripts/trace-modules.mjs" npm run test:acceptance
```

The recorder writes relative dependency paths to `.data/module-trace/*.jsonl`.
Sort their union into `vendor/runtime-selection.json` (two-space JSON, final newline),
review changes, regenerate, and run every documented check from a new offline copy.
Do not edit protected package/lockfiles as part of a bundle regeneration.

The installer tests exercise success, archive corruption, lock drift, refusing to
overwrite an install, and rejecting a checksummed symlink archive before extraction.
No runtime data, installed node_modules tree, credentials, or submodules are delivered.
