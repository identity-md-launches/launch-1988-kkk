import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { rpc, type Settings } from "./config.ts";
import type { Projection } from "./domain.ts";
type Block = {
  number: string;
  hash: string;
  timestamp: string;
};
export async function status(s: Projection | null, config: Settings) {
  const base = {
    indexed: s?.indexed ?? null,
    complete: s?.complete ?? false,
    observedHead: null as null | {
      number: string;
      hash: string;
      timestamp: string;
    },
    lag: null as null | string,
    current: false,
    connectionError: null as null | string,
    checkedAt: new Date().toISOString(),
    projectionFinality: "provisional",
    reorgWindowSeconds: config.reorgWindow,
    finalizedThroughTimestamp: null as null | string,
  };
  try {
    const identity = JSON.parse(
      readFileSync(resolve(config.databaseDirectory, "identity.json"), "utf8"),
    );
    const [chain, head, deployment] = await Promise.all([
      rpc<string>(config.rpcUrl, "eth_chainId"),
      rpc<Block>(config.rpcUrl, "eth_getBlockByNumber", ["latest", false]),
      rpc<Block | null>(config.rpcUrl, "eth_getBlockByNumber", [
        `0x${config.deploymentBlock.toString(16)}`,
        false,
      ]),
    ]);
    if (!deployment || deployment.hash !== identity.deploymentHash)
      throw new Error(
        "Deployment anchor changed; stop and use a separate database for the new deployment",
      );
    if (BigInt(chain) !== BigInt(config.chainId))
      throw new Error("RPC chain ID changed");
    base.observedHead = {
      number: BigInt(head.number).toString(),
      hash: head.hash,
      timestamp: BigInt(head.timestamp).toString(),
    };
    base.finalizedThroughTimestamp = (
      BigInt(head.timestamp) > BigInt(config.reorgWindow)
        ? BigInt(head.timestamp) - BigInt(config.reorgWindow)
        : 0n
    ).toString();
    if (s?.indexed) {
      base.lag = (BigInt(head.number) - BigInt(s.indexed.number)).toString();
      const block = await rpc<Block | null>(
        config.rpcUrl,
        "eth_getBlockByNumber",
        [`0x${BigInt(s.indexed.number).toString(16)}`, false],
      );
      if (!block || block.hash !== s.indexed.hash)
        throw new Error(
          "Indexed block is no longer canonical; awaiting rollback or rebuild",
        );
      base.current = s.complete && base.lag === "0";
      base.projectionFinality =
        BigInt(s.indexed.timestamp) <= BigInt(base.finalizedThroughTimestamp)
          ? "finalized-within-configured-window"
          : "provisional";
    }
  } catch (e) {
    base.current = false;
    base.connectionError = e instanceof Error ? e.message : String(e);
  }
  return base;
}
