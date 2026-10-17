// Maintainer-only rebuild from an explicit isolated cache; never downloads packages.
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
if (!process.argv[2])
  throw new Error(
    "Usage: node scripts/vendor-cache.mjs /path/to/isolated/npm-cache",
  );
const result = spawnSync(
  "python3",
  [
    fileURLToPath(new URL("./vendor-runtime.py", import.meta.url)),
    process.argv[2],
  ],
  { stdio: "inherit" },
);
if (result.status !== 0)
  throw new Error(`Vendor generation failed (${result.status})`);
