import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { isAddress, getAddress } from "viem";
export type Settings = {
  rpcUrl: string;
  chainId: number;
  contractAddress: `0x${string}`;
  deploymentBlock: number;
  databaseDirectory: string;
  apiPort: number;
  reorgWindow: number;
};
export function localUrl(value: string): URL {
  const url = new URL(value);
  if (
    url.protocol !== "http:" ||
    !["127.0.0.1", "[::1]"].includes(url.hostname) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    throw new Error(
      "RPC/API URL must be plain HTTP on literal loopback, without credentials, query or fragment",
    );
  }
  return url;
}
function integer(
  value: unknown,
  name: string,
  min: number,
  max: number,
): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < min ||
    value > max
  )
    throw new Error(`Invalid ${name}`);
  return value;
}
export function parseSettings(raw: unknown): Settings {
  if (!raw || typeof raw !== "object")
    throw new Error("Configuration must be an object");
  const v = raw as Record<string, unknown>;
  if (typeof v.rpcUrl !== "string") throw new Error("rpcUrl required");
  localUrl(v.rpcUrl);
  if (
    typeof v.contractAddress !== "string" ||
    !isAddress(v.contractAddress) ||
    /^0x0{40}$/i.test(v.contractAddress)
  )
    throw new Error("A deployed contractAddress is required");
  if (
    typeof v.databaseDirectory !== "string" ||
    !v.databaseDirectory.trim() ||
    v.databaseDirectory.includes("://")
  )
    throw new Error("A persistent databaseDirectory is required");
  return {
    rpcUrl: v.rpcUrl,
    chainId: integer(v.chainId ?? 31337, "chainId", 1, Number.MAX_SAFE_INTEGER),
    contractAddress: getAddress(
      v.contractAddress,
    ).toLowerCase() as `0x${string}`,
    deploymentBlock: integer(
      v.deploymentBlock,
      "deploymentBlock",
      0,
      Number.MAX_SAFE_INTEGER,
    ),
    databaseDirectory: resolve(v.databaseDirectory),
    apiPort: integer(v.apiPort ?? 42069, "apiPort", 1024, 65535),
    reorgWindow: integer(v.reorgWindow ?? 120, "reorgWindow", 1, 600),
  };
}
export function settings(): Settings {
  const path = process.env.RENTAL_CONFIG;
  if (!path)
    throw new Error(
      "RENTAL_CONFIG must name a JSON configuration; run npm run demo for synthetic local data",
    );
  return parseSettings(JSON.parse(readFileSync(resolve(path), "utf8")));
}
export async function rpc<T>(
  url: string,
  method: string,
  params: unknown[] = [],
  headers: Record<string, string> = {},
): Promise<T> {
  localUrl(url);
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal: AbortSignal.timeout(1500),
    redirect: "error",
  });
  if (!response.ok) throw new Error(`RPC HTTP ${response.status}`);
  const data = (await response.json()) as {
    result?: T;
    error?: {
      message: string;
    };
  };
  if (data.error || data.result === undefined)
    throw new Error(data.error?.message ?? "RPC missing result");
  return data.result;
}
export function json(value: unknown): string {
  return JSON.stringify(value, (_, v) =>
    typeof v === "bigint" ? v.toString() : v,
  );
}
