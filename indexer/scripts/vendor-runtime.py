"""Reproducible, application-scoped distribution of unchanged registry files.

The lockfile stays the version authority. The reviewed module selection comes from
real acceptance/unit/typecheck/formatter runs; new imports require revalidation.
Only the explicitly supplied cache is read. Python's standard library suffices.
"""
import base64
import collections
import hashlib
import io
import json
import lzma
from pathlib import Path, PurePosixPath
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path(sys.argv[1]).resolve()
VENDOR = ROOT / "vendor"
lock_bytes = (ROOT / "package-lock.json").read_bytes()
lock = json.loads(lock_bytes)
selection_bytes = (VENDOR / "runtime-selection.json").read_bytes()
selected = set(json.loads(selection_bytes))
unused = {
    "vite", "rolldown", "lightningcss", "@rolldown/binding-linux-x64-gnu",
    "lightningcss-linux-x64-gnu", "@rolldown/pluginutils", "@oxc-project/types",
}


def exclude(package, relative):
    path = PurePosixPath(relative)
    name = path.name
    # Preserve exact metadata and legal notices even for unused package files.
    if name == "package.json" or any(s in name.lower() for s in ("license", "notice", "copying", "copyright")):
        return None
    full = package + "/" + relative
    # Some libraries call actual API modules "test" (e.g. viem's Anvil actions).
    # Runtime coverage and declarations take precedence over directory pruning.
    if full in selected or name.endswith((".d.ts", ".d.cts", ".d.mts")):
        return None
    if package.removeprefix("node_modules/") in unused:
        return "browser build toolchain; application TypeScript uses Node 24"
    if name.endswith(".map"):
        return "source map"
    if any(p in {"test", "tests", "__tests__", "perf", "benchmark", "benchmarks", "examples", ".github"} for p in path.parts):
        return "upstream test/example"
    if name.startswith(("CHANGELOG", "HISTORY")):
        return "upstream history"
    if package == "node_modules/typescript" and not (name.endswith(".d.ts") or relative in {"lib/tsc.js", "lib/_tsc.js", "bin/tsc"}):
        return "unused compiler API/server/localization"
    if package == "node_modules/@electric-sql/pglite" and name.endswith(".tar.gz"):
        return "optional PostgreSQL extension not used by this application"
    if package in {"node_modules/viem", "node_modules/ox"} and relative.startswith("_cjs/"):
        return "CommonJS duplicate; application uses ESM"
    if "trusted-setups" in path.parts:
        return "blob-transaction KZG data not used by read-only rental backend"
    if name.endswith(".ts") and not name.endswith(".d.ts") and package != "node_modules/ponder":
        return "duplicate TypeScript source"
    if name.endswith((".js", ".mjs", ".cjs")) and full not in selected and package != "node_modules/ponder":
        return "outside tested application runtime module graph"
    return None


files, packages, absent, exclusions = {}, [], [], []
for package, entry in sorted(lock["packages"].items()):
    if "integrity" not in entry:
        continue
    algorithm, encoded = entry["integrity"].split("-", 1)
    if algorithm != "sha512":
        raise ValueError("Unexpected integrity algorithm: " + package)
    digest = base64.b64decode(encoded).hex()
    cache_path = CACHE / "_cacache/content-v2/sha512" / digest[:2] / digest[2:4] / digest[4:]
    if not cache_path.exists():
        if not entry.get("optional"):
            raise ValueError("Missing required package: " + package)
        absent.append({"package": package, "version": entry["version"], "os": entry.get("os"), "cpu": entry.get("cpu"), "libc": entry.get("libc")})
        continue
    raw = cache_path.read_bytes()
    if hashlib.sha512(raw).hexdigest() != digest:
        raise ValueError("Registry integrity mismatch: " + package)
    counts = collections.Counter()
    kept = 0
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
        for member in archive:
            if member.isdir():
                continue
            path = PurePosixPath(member.name)
            if not member.isfile() or path.is_absolute() or ".." in path.parts or len(path.parts) < 2:
                raise ValueError("Unsafe registry entry: " + member.name)
            relative = str(PurePosixPath(*path.parts[1:]))
            reason = exclude(package, relative)
            full = package + "/" + relative
            if reason:
                exclusions.append([full, reason])
                counts[reason] += 1
                continue
            if full in files:
                raise ValueError("Duplicate archive entry: " + full)
            content = archive.extractfile(member).read()
            mode = 0o755 if member.mode & 0o111 else 0o644
            files[full] = (content, mode)
            kept += 1
    packages.append({"package": package, "version": entry["version"], "integrity": entry["integrity"], "source": entry["resolved"], "license": entry.get("license"), "retainedFiles": kept, "excludedFilesByReason": dict(counts)})

missing = selected - files.keys()
if missing:
    raise ValueError("Selection excludes a tested runtime module: " + repr(sorted(missing)))
manifest = {
    "format": "rental-application-runtime-v1",
    "scope": "Pinned rental application, Node 24; not a general npm package installation",
    "lockSha256": hashlib.sha256(lock_bytes).hexdigest(),
    "packageSha256": hashlib.sha256((ROOT / "package.json").read_bytes()).hexdigest(),
    "selectionSha256": hashlib.sha256(selection_bytes).hexdigest(),
    "packages": packages,
    "notCachedPlatformOptionalPackages": absent,
    "retainedFileCount": len(files),
}
inventory = {
    "lockSha256": manifest["lockSha256"],
    "files": [[p, hashlib.sha256(b).hexdigest(), mode] for p, (b, mode) in sorted(files.items())],
    "excludedFiles": exclusions,
}
payload = {"inventory.json": (json.dumps(inventory, separators=(",", ":")).encode() + b"\n", 0o644)}
payload.update({"packages/" + p.removeprefix("node_modules/"): data for p, data in files.items()})
VENDOR.mkdir(exist_ok=True)
target = VENDOR / "runtime.tar.xz"
with lzma.open(target, "wb", preset=9 | lzma.PRESET_EXTREME) as compressed:
    with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.USTAR_FORMAT) as archive:
        for name, (data, mode) in sorted(payload.items()):
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(data), mode, 0
            info.uid = info.gid = 0
            archive.addfile(info, io.BytesIO(data))
archive_bytes = target.read_bytes()
manifest["archiveSha256"] = hashlib.sha256(archive_bytes).hexdigest()
manifest["archiveBytes"] = len(archive_bytes)
(VENDOR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(VENDOR / "runtime.sha256").write_text(manifest["archiveSha256"] + "  runtime.tar.xz\n")
print(f"Verified {len(packages)} locked packages; retained {len(files)} original files; archive {len(archive_bytes)} bytes", flush=True)
