import { spawn, type ChildProcess } from "node:child_process";
import { createServer as httpServer } from "node:http";
import { createServer } from "node:net";
import {
  createWriteStream,
  existsSync,
  mkdirSync,
  readFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Hex,
  type Abi,
  keccak256,
  stringToHex,
} from "viem";
import { anvil } from "viem/chains";
import { localUrl, rpc } from "../shared/config.ts";
export const indexerRoot = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "..",
);
export function repositoryRoot() {
  let path = indexerRoot;
  while (!existsSync(resolve(path, "foundry.toml"))) {
    const parent = dirname(path);
    if (parent === path) throw new Error("Foundry repository not found");
    path = parent;
  }
  return path;
}
export const children = new Set<ChildProcess>();
export async function port() {
  return new Promise<number>((resolve, reject) => {
    const s = createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const address = s.address();
      if (!address || typeof address === "string")
        throw new Error("Missing port");
      s.close(() => resolve(address.port));
    });
  });
}
export async function until<T>(
  label: string,
  fn: () => Promise<T | false>,
  timeout = 60000,
): Promise<T> {
  const start = performance.now();
  let last: unknown;
  while (performance.now() - start < timeout) {
    try {
      const value = await fn();
      if (value) return value;
    } catch (e) {
      last = e;
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  throw new Error(
    `Timeout (${timeout}ms): ${label}; last error: ${String(last)}`,
  );
}
export function run(
  command: string,
  args: string[],
  log: string,
  env: NodeJS.ProcessEnv = {},
) {
  mkdirSync(dirname(log), { recursive: true });
  const output = createWriteStream(log, { flags: "a" });
  const child = spawn(command, args, {
    cwd: indexerRoot,
    env: { ...process.env, NODE_USE_ENV_PROXY: "0", ...env },
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.add(child);
  child.stdout!.pipe(output);
  child.stderr!.pipe(output);
  child.once("error", (e) => output.write(String(e)));
  child.once("exit", () => {
    children.delete(child);
    output.end();
  });
  return child;
}
export async function stop(child: ChildProcess, abrupt = false) {
  if (!children.has(child) || !child.pid) return;
  const exited = new Promise<void>((r) => child.once("exit", () => r()));
  try {
    process.kill(-child.pid, abrupt ? "SIGKILL" : "SIGINT");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ESRCH") throw e;
  }
  await Promise.race([exited, new Promise<void>((r) => setTimeout(r, 6000))]);
  if (children.has(child)) {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {}
    await exited;
  }
}
export async function cleanup() {
  for (const child of [...children].reverse()) await stop(child);
}
export function artifact(name: string) {
  return JSON.parse(
    readFileSync(
      resolve(repositoryRoot(), `out/${name}.sol/${name}.json`),
      "utf8",
    ),
  ) as {
    abi: Abi;
    bytecode: {
      object: Hex;
    };
  };
}
export async function assertAnvil(url: string) {
  localUrl(url);
  const [chain, version] = await Promise.all([
    rpc<string>(url, "eth_chainId"),
    rpc<string>(url, "web3_clientVersion"),
  ]);
  if (BigInt(chain) !== 31337n || !version.toLowerCase().includes("anvil"))
    throw new Error(
      "Transactions require a disposable Anvil RPC with chain ID 31337",
    );
}
export async function chain(url: string) {
  await assertAnvil(url);
  const publicClient = createPublicClient({
    chain: anvil,
    transport: http(url, {
      timeout: 3000,
      retryCount: 0,
      fetchOptions: { redirect: "error" },
    }),
    cacheTime: 0,
    pollingInterval: 100,
  });
  const accounts = await rpc<Address[]>(url, "eth_accounts");
  const [admin, renter, staff, nextAdmin] = accounts;
  if (!admin || !renter || !staff || !nextAdmin)
    throw new Error("Anvil development accounts unavailable");
  const wallet = createWalletClient({
    chain: anvil,
    transport: http(url, {
      timeout: 3000,
      retryCount: 0,
      fetchOptions: { redirect: "error" },
    }),
  });
  const receipt = async (hash: Hex, success = true) => {
    const result = await publicClient.waitForTransactionReceipt({
      hash,
      timeout: 10000,
      pollingInterval: 100,
    });
    if ((result.status === "success") !== success)
      throw new Error(
        `Unexpected transaction status ${hash}: ${result.status}`,
      );
    if (!success && result.logs.length)
      throw new Error("Reverted transaction retained logs");
    return result;
  };
  const deploy = async (name: string, args: unknown[]) => {
    await assertAnvil(url);
    const a = artifact(name);
    const result = await receipt(
      await wallet.deployContract({
        account: admin,
        abi: a.abi,
        bytecode: a.bytecode.object,
        args,
        gas: 8000000n,
      }),
    );
    if (!result.contractAddress) throw new Error("Deployment missing address");
    return {
      address: result.contractAddress,
      block: Number(result.blockNumber),
    };
  };
  const send = async (
    address: Address,
    abi: Abi,
    functionName: string,
    args: unknown[],
    account: Address = admin,
    success = true,
  ) => {
    await assertAnvil(url);
    return receipt(
      await wallet.writeContract({
        address,
        abi,
        functionName,
        args,
        account,
        gas: 3000000n,
      }),
      success,
    );
  };
  return {
    publicClient,
    admin,
    renter,
    staff,
    nextAdmin,
    deploy,
    send,
    receipt,
  };
}
export const key = (name: string) =>
  keccak256(stringToHex(`synthetic-rental-trial:${name}`));
const allowed = new Set([
  "eth_chainId",
  "net_version",
  "web3_clientVersion",
  "eth_blockNumber",
  "eth_getBlockByNumber",
  "eth_getBlockByHash",
  "eth_getLogs",
  "eth_call",
  "eth_getCode",
  "eth_getBalance",
  "eth_getTransactionByHash",
  "eth_getTransactionReceipt",
  "eth_getBlockReceipts",
]);
export async function proxy(target: string) {
  localUrl(target);
  const state = {
    outage: false,
    duplicates: true,
    delayMs: 0,
    duplicatedLogs: 0,
    ingestionOutages: 0,
    requests: 0,
    methods: new Set<string>(),
  };
  const server = httpServer(async (req, res) => {
    if (req.method !== "POST") {
      res.writeHead(405);
      res.end();
      return;
    }
    if (state.outage) {
      if (req.headers["x-rental-ingestion"] === "true")
        state.ingestionOutages++;
      res.writeHead(503);
      res.end("synthetic RPC outage");
      return;
    }
    try {
      let body = "";
      for await (const chunk of req) {
        body += chunk;
        if (body.length > 1024 * 1024) throw new Error("RPC request too large");
      }
      const input = JSON.parse(body);
      const requests = Array.isArray(input) ? input : [input];
      if (requests.some((r) => !allowed.has(r.method))) {
        res.writeHead(403);
        res.end("Read-only RPC proxy");
        return;
      }
      for (const r of requests) {
        state.methods.add(r.method);
        state.requests++;
      }
      if (state.delayMs) await new Promise((r) => setTimeout(r, state.delayMs));
      const response = await fetch(target, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
        signal: AbortSignal.timeout(5000),
        redirect: "error",
      });
      const value = await response.json();
      const values = Array.isArray(value) ? value : [value];
      for (let i = 0; i < values.length; i++)
        if (
          requests[i]?.method === "eth_getLogs" &&
          state.duplicates &&
          Array.isArray(values[i].result)
        ) {
          state.duplicatedLogs += values[i].result.length;
          values[i].result = values[i].result.flatMap((log: unknown) => [
            log,
            log,
          ]);
        }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(Array.isArray(value) ? values : values[0]));
    } catch (e) {
      res.writeHead(502);
      res.end(String(e));
    }
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const a = server.address();
  if (!a || typeof a === "string") throw new Error("Missing proxy address");
  return {
    state,
    url: `http://127.0.0.1:${a.port}`,
    close: async () => {
      server.closeAllConnections();
      await new Promise<void>((r, reject) =>
        server.close((e) => (e ? reject(e) : r())),
      );
    },
  };
}
export async function get(base: string, path: string) {
  localUrl(base);
  const r = await fetch(base + path, { signal: AbortSignal.timeout(6000) });
  const data = await r.json();
  if (!r.ok)
    throw new Error(`API ${path} ${r.status}: ${JSON.stringify(data)}`);
  return data;
}
