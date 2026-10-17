import { spawn } from "node:child_process";
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
  existsSync,
  openSync,
  closeSync,
  unlinkSync,
} from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { settings, rpc } from "../shared/config.ts";
import { keccak256, decodeEventLog } from "viem";
import { RentalEscrowAbi } from "../abis/RentalEscrow.ts";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
process.chdir(root);
const config = settings();
const dir = config.databaseDirectory;
mkdirSync(dir, { recursive: true });
const hexBlock = `0x${config.deploymentBlock.toString(16)}`;
const [chain, genesis, deployment, code, logs] = await Promise.all([
  rpc(config.rpcUrl, "eth_chainId"),
  rpc(config.rpcUrl, "eth_getBlockByNumber", ["0x0", false]),
  rpc(config.rpcUrl, "eth_getBlockByNumber", [hexBlock, false]),
  rpc(config.rpcUrl, "eth_getCode", [config.contractAddress, hexBlock]),
  rpc(config.rpcUrl, "eth_getLogs", [
    { address: config.contractAddress, fromBlock: hexBlock, toBlock: hexBlock },
  ]),
]);
if (BigInt(chain) !== BigInt(config.chainId))
  throw new Error("Configured chain ID does not match RPC");
if (!deployment || code === "0x")
  throw new Error("No contract at deployment block");
const constructor = logs.find((log) => {
  try {
    const decoded = decodeEventLog({
      abi: RentalEscrowAbi,
      data: log.data,
      topics: log.topics,
    });
    return (
      decoded.eventName === "AdminTransferred" &&
      /^0x0{40}$/i.test(decoded.args.previousAdmin)
    );
  } catch {
    return false;
  }
});
if (!constructor)
  throw new Error(
    "deploymentBlock must include the escrow constructor AdminTransferred event",
  );
const identity = {
  version: 1,
  chainId: config.chainId,
  contractAddress: config.contractAddress,
  deploymentBlock: config.deploymentBlock,
  deploymentHash: deployment.hash,
  genesisHash: genesis.hash,
  codeHash: keccak256(code),
  reorgWindow: config.reorgWindow,
};
const identityPath = resolve(dir, "identity.json");
if (existsSync(identityPath)) {
  if (
    JSON.stringify(JSON.parse(readFileSync(identityPath, "utf8"))) !==
    JSON.stringify(identity)
  )
    throw new Error(
      "Database identity mismatch: use a separate directory for this deployment/configuration",
    );
} else {
  writeFileSync(identityPath, JSON.stringify(identity, null, 2) + "\n", {
    flag: "wx",
  });
}
// Lock belongs only to our wrapper; a crash leaves a PID that is checked, never killed.
const lock = resolve(dir, "runner.lock");
if (existsSync(lock)) {
  const pid = Number(readFileSync(lock, "utf8"));
  let running = true;
  try {
    process.kill(pid, 0);
  } catch (e) {
    if (e.code === "ESRCH") running = false;
    else throw e;
  }
  if (running)
    throw new Error("Database is already in use; runner lock PID is alive");
  unlinkSync(lock);
}
const fd = openSync(lock, "wx");
writeFileSync(fd, String(process.pid));
closeSync(fd);
const child = spawn(
  process.execPath,
  ["--no-use-env-proxy", resolve(root, "scripts/runtime.mjs")],
  {
    cwd: root,
    stdio: "inherit",
    env: {
      ...process.env,
      PONDER_TELEMETRY_DISABLED: "1",
      PONDER_LOG_LEVEL: "info",
    },
  },
);
const stop = (signal) => child.kill(signal);
process.on("SIGTERM", () => stop("SIGTERM"));
process.on("SIGINT", () => stop("SIGINT"));
child.on("error", (e) => {
  console.error(e);
  process.exitCode = 1;
});
child.on("exit", (code) => {
  if (existsSync(lock) && readFileSync(lock, "utf8") === String(process.pid))
    unlinkSync(lock);
  process.exitCode = code ?? 1;
});
