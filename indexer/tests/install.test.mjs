import { test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  copyFileSync,
  readFileSync,
  writeFileSync,
  existsSync,
  symlinkSync,
  rmSync,
} from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fixture = () => {
  mkdirSync(resolve(root, ".data"), { recursive: true });
  const dir = mkdtempSync(resolve(root, ".data/install-test-"));
  for (const path of [
    "package.json",
    "package-lock.json",
    "scripts/install.mjs",
    "vendor/manifest.json",
    "vendor/runtime.tar.xz",
    "vendor/runtime.sha256",
    "vendor/runtime-selection.json",
  ]) {
    mkdirSync(dirname(resolve(dir, path)), { recursive: true });
    copyFileSync(resolve(root, path), resolve(dir, path));
  }
  return dir;
};
const install = (dir, ...args) =>
  spawnSync(
    process.execPath,
    ["--no-use-env-proxy", resolve(dir, "scripts/install.mjs"), ...args],
    { encoding: "utf8", timeout: 30000 },
  );
const rejected = (result, pattern) => {
  assert.equal(result.error, undefined);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, pattern);
};

test("clean offline installation verifies files and refuses overwriting an existing install", () => {
  const dir = fixture();
  try {
    const checked = install(dir, "--check");
    assert.equal(checked.status, 0, checked.stderr);
    assert.equal(existsSync(resolve(dir, "node_modules")), false);
    const result = install(dir);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      JSON.parse(readFileSync(resolve(dir, "node_modules/ponder/package.json")))
        .version,
      "0.18.2",
    );
    assert.ok(
      existsSync(
        resolve(dir, "node_modules/@electric-sql/pglite/dist/postgres.wasm"),
      ),
    );
    assert.ok(existsSync(resolve(dir, "node_modules/.bin/tsc")));
    writeFileSync(resolve(dir, "node_modules/owner-sentinel"), "preserve");
    rejected(install(dir), /node_modules already exists/);
    assert.equal(
      readFileSync(resolve(dir, "node_modules/owner-sentinel"), "utf8"),
      "preserve",
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("corrupted archives fail before extraction", () => {
  const dir = fixture();
  try {
    const path = resolve(dir, "vendor/runtime.tar.xz");
    const data = readFileSync(path);
    data[100] ^= 1;
    writeFileSync(path, data);
    rejected(install(dir), /archive checksum mismatch/);
    assert.equal(existsSync(resolve(dir, "node_modules")), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("dependency lock drift fails visibly", () => {
  const dir = fixture();
  try {
    const path = resolve(dir, "package-lock.json");
    writeFileSync(path, readFileSync(path, "utf8") + "\n");
    rejected(install(dir), /does not match package-lock.json/);
    assert.equal(existsSync(resolve(dir, "node_modules")), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("even a checksummed archive cannot install symlinks", () => {
  const dir = fixture();
  try {
    const input = resolve(dir, "input");
    mkdirSync(resolve(input, "packages"), { recursive: true });
    symlinkSync("../../outside", resolve(input, "packages/escape"));
    const path = resolve(dir, "vendor/runtime.tar.xz");
    const packed = spawnSync(
      "tar",
      ["-cJf", path, "-C", input, "packages/escape"],
      { encoding: "utf8" },
    );
    assert.equal(packed.status, 0, packed.stderr);
    const hash = createHash("sha256").update(readFileSync(path)).digest("hex");
    const manifestPath = resolve(dir, "vendor/manifest.json");
    const manifest = JSON.parse(readFileSync(manifestPath));
    manifest.archiveSha256 = hash;
    writeFileSync(manifestPath, JSON.stringify(manifest));
    writeFileSync(
      resolve(dir, "vendor/runtime.sha256"),
      hash + "  runtime.tar.xz\n",
    );
    rejected(install(dir), /only regular files/);
    assert.equal(existsSync(resolve(dir, "node_modules")), false);
    assert.equal(existsSync(resolve(dir, "outside")), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
