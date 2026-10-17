import { rpc } from "./config.ts";
const readMethods = new Set([
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
export function normalizeLogs(logs: unknown): unknown {
  if (!Array.isArray(logs))
    throw new Error("eth_getLogs did not return an array");
  const seen = new Map<string, string>();
  const unique = [];
  for (const log of logs) {
    const position = `${log.blockNumber}:${log.logIndex}`;
    // Compare all canonical payload fields, not just transaction hash. Conflicting
    // responses fail closed; an exact overlap is safe to discard before Ponder validation.
    const payload = JSON.stringify([
      log.address,
      log.blockHash,
      log.blockNumber,
      log.transactionHash,
      log.transactionIndex,
      log.logIndex,
      log.data,
      log.topics,
      log.removed ?? false,
    ]);
    const previous = seen.get(position);
    if (previous !== undefined) {
      if (previous !== payload)
        throw new Error(`Conflicting RPC logs at ${position}`);
      continue;
    }
    seen.set(position, payload);
    unique.push(log);
  }
  return unique;
}
export async function readRpc(
  url: string,
  method: string,
  params: unknown[] = [],
): Promise<any> {
  if (!readMethods.has(method))
    throw new Error(`Backend transport refuses non-read RPC method ${method}`);
  const result = await rpc(url, method, params, {
    "x-rental-ingestion": "true",
  });
  return method === "eth_getLogs" ? normalizeLogs(result) : result;
}
