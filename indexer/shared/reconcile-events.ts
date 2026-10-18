import { decodeEventLog, type PublicClient, type Block } from "viem";
import { RentalEscrowAbi } from "../abis/RentalEscrow.ts";
import type { Settings } from "./config.ts";
import type { FeeRequest } from "./domain.ts";

// Deliberately independent of the projection, its reducer, and the history table.
// The caller's read-only transport normalizes exact duplicates and rejects conflicts
// before viem formats logs. Decode explicitly: getContractEvents can omit bad logs.
export async function reconciliationEvents(
  client: PublicClient,
  config: Settings,
  indexedBlock: Block,
) {
  const end = indexedBlock.number;
  const start = BigInt(config.deploymentBlock);
  if (end === null || start > end)
    throw new Error("Reconciliation block precedes configured deployment");
  const headers = new Map<bigint, Block>([[end, indexedBlock]]);
  const staff: Record<string, boolean> = {};
  const feeRequests: Record<string, FeeRequest> = {};
  let refundsPaid = 0n;
  let feesPaid = 0n;
  let deploymentSeen = false;
  const hash = /^0x[0-9a-fA-F]{64}$/;
  // Match the indexer's bounded RPC range; never request a latest/pending boundary.
  for (let from = start; from <= end; from += 20n) {
    const to = from + 19n < end ? from + 19n : end;
    const logs = await client.getLogs({
      address: config.contractAddress,
      fromBlock: from,
      toBlock: to,
    });
    for (const log of logs) {
      if (
        log.blockNumber === null ||
        log.blockNumber < from ||
        log.blockNumber > to ||
        log.address.toLowerCase() !== config.contractAddress ||
        log.removed ||
        !hash.test(log.blockHash ?? "") ||
        !hash.test(log.transactionHash ?? "") ||
        !Number.isSafeInteger(log.logIndex) ||
        log.logIndex! < 0 ||
        !Number.isSafeInteger(log.transactionIndex) ||
        log.transactionIndex! < 0
      )
        throw new Error("Inconsistent reconciliation log metadata/range");
    }
    logs.sort((a, b) =>
      a.blockNumber! < b.blockNumber!
        ? -1
        : a.blockNumber! > b.blockNumber!
          ? 1
          : a.logIndex! - b.logIndex!,
    );
    for (const log of logs) {
      let header = headers.get(log.blockNumber!);
      if (!header) {
        header = await client.getBlock({ blockNumber: log.blockNumber! });
        headers.set(log.blockNumber!, header);
      }
      if (
        header.number !== log.blockNumber ||
        header.hash !== log.blockHash ||
        header.transactions[log.transactionIndex!] !== log.transactionHash
      )
        throw new Error(
          "Reconciliation log is not in its canonical block/transaction",
        );
      const event = decodeEventLog({
        abi: RentalEscrowAbi,
        topics: log.topics,
        data: log.data,
        strict: true,
      });
      switch (event.eventName) {
        case "AdminTransferred":
          if (/^0x0{40}$/i.test(event.args.previousAdmin)) {
            if (deploymentSeen || log.blockNumber !== start)
              throw new Error("Inconsistent escrow deployment event");
            deploymentSeen = true;
          }
          break;
        case "StaffUpdated":
          // Revoked accounts remain records with enabled=false; absence differs.
          staff[event.args.account.toLowerCase()] = event.args.enabled;
          break;
        case "FeesWithdrawn": {
          const id = event.args.requestId.toLowerCase();
          if (feeRequests[id])
            throw new Error(`Conflicting fee request events for ${id}`);
          if (event.args.amount === 0n)
            throw new Error("Invalid zero fee payment event");
          feeRequests[id] = {
            recipient: event.args.to.toLowerCase(),
            amount: event.args.amount.toString(),
            completed: true,
            transactionHash: log.transactionHash!,
          };
          feesPaid += event.args.amount;
          break;
        }
        case "RefundWithdrawn":
          if (event.args.amount === 0n)
            throw new Error("Invalid zero refund payment event");
          refundsPaid += event.args.amount;
          break;
      }
    }
  }
  if (!deploymentSeen)
    throw new Error(
      "Missing escrow constructor event at configured deployment block",
    );
  return { staff, feeRequests, refundsPaid, feesPaid };
}
