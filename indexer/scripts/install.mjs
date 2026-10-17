// Offline application-runtime bootstrap. No npm, network, lifecycle scripts or services.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  readFileSync,
  mkdirSync,
  mkdtempSync,
  existsSync,
  renameSync,
  symlinkSync,
  chmodSync,
  lstatSync,
  readdirSync,
  rmSync,
} from "node:fs";
import { dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
process.chdir(root);
if (
  process.platform !== "linux" ||
  process.arch !== "x64" ||
  !process.report.getReport().header.glibcVersionRuntime
)
  throw new Error("Offline runtime is validated on Linux x64 with glibc");
if (Number(process.versions.node.split(".")[0]) !== 24)
  throw new Error("Use Node.js 24.x (tested: 24.21.0)");
const digest = (data) => createHash("sha256").update(data).digest("hex");
const manifest = JSON.parse(
  readFileSync(resolve(root, "vendor/manifest.json")),
);
if (manifest.format !== "rental-application-runtime-v1")
  throw new Error("Unknown runtime format");
for (const [path, expected] of [
  ["package-lock.json", manifest.lockSha256],
  ["package.json", manifest.packageSha256],
  ["vendor/runtime-selection.json", manifest.selectionSha256],
])
  if (digest(readFileSync(resolve(root, path))) !== expected)
    throw new Error(`Vendored runtime does not match ${path}`);
const archive = resolve(root, "vendor/runtime.tar.xz");
const expected = readFileSync(resolve(root, "vendor/runtime.sha256"), "utf8")
  .trim()
  .split(/\s+/)[0];
if (
  digest(readFileSync(archive)) !== expected ||
  expected !== manifest.archiveSha256
)
  throw new Error("Vendored dependency archive checksum mismatch");
const run = (args) => {
  const result = spawnSync("tar", args, {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0)
    throw new Error(`tar failed (${result.status}): ${result.stderr}`);
  return result.stdout;
};
const paths = run(["-tJf", archive]).trim().split("\n");
if (
  new Set(paths).size !== paths.length ||
  paths.some(
    (path) =>
      (path !== "inventory.json" && !path.startsWith("packages/")) ||
      path.split("/").some((part) => !part || part === "." || part === "..") ||
      /[\\\x00-\x1f]/.test(path),
  )
)
  throw new Error("Unsafe runtime archive paths");
if (
  run(["-tvJf", archive])
    .trim()
    .split("\n")
    .some((line) => !line.startsWith("-"))
)
  throw new Error("Runtime archive must contain only regular files");
if (process.argv.includes("--check")) {
  console.log(
    `Runtime archive and dependency lock verified (${manifest.archiveBytes} bytes)`,
  );
  process.exit(0);
}
if (existsSync(resolve(root, "node_modules")))
  throw new Error(
    "node_modules already exists; install in a fresh checkout/directory",
  );
mkdirSync(resolve(root, ".data"), { recursive: true });
const stage = mkdtempSync(resolve(root, ".data/install-"));
try {
  run([
    "-xJf",
    archive,
    "--no-same-owner",
    "--no-same-permissions",
    "-C",
    stage,
  ]);
  const inventory = JSON.parse(readFileSync(resolve(stage, "inventory.json")));
  if (inventory.lockSha256 !== manifest.lockSha256)
    throw new Error("Inventory lock mismatch");
  const files = new Map(
    inventory.files.map(([path, hash, mode]) => [path, { hash, mode }]),
  );
  if (
    files.size !== inventory.files.length ||
    files.size !== manifest.retainedFileCount
  )
    throw new Error("Invalid file inventory");
  const extracted = readdirSync(resolve(stage, "packages"), {
    recursive: true,
  });
  let verified = 0;
  for (const path of extracted) {
    const full = resolve(stage, "packages", path);
    const stat = lstatSync(full);
    if (stat.isDirectory()) continue;
    const record = files.get(
      "node_modules/" + relative(resolve(stage, "packages"), full),
    );
    if (!stat.isFile() || !record || digest(readFileSync(full)) !== record.hash)
      throw new Error(`Runtime file integrity mismatch: ${path}`);
    chmodSync(full, record.mode);
    verified++;
  }
  if (verified !== files.size) throw new Error("Runtime archive is incomplete");
  const packages = resolve(stage, "packages");
  mkdirSync(resolve(packages, ".bin"));
  for (const [bin, path] of [
    ["tsc", "typescript/bin/tsc"],
    ["prettier", "prettier/bin/prettier.cjs"],
  ]) {
    chmodSync(resolve(packages, path), 0o755);
    symlinkSync("../" + path, resolve(packages, ".bin", bin));
  }
  renameSync(packages, resolve(root, "node_modules"));
  renameSync(
    resolve(stage, "inventory.json"),
    resolve(root, ".data/runtime-inventory.json"),
  );
  console.log(
    `Installed ${verified} verified runtime files offline. No services started. Run npm run abi:check, npm run typecheck, npm test.`,
  );
} finally {
  // Only remove the unique staging directory created by this installer.
  rmSync(stage, { recursive: true, force: true });
}
