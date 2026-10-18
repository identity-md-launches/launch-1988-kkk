import { createPublicClient, custom, type Address } from "viem";
import { RentalEscrowAbi } from "../abis/RentalEscrow.ts";
import { MockPaymentTokenAbi } from "../abis/MockPaymentToken.ts";
import { json, type Settings } from "./config.ts";
import type { Projection } from "./domain.ts";
import { readRpc } from "./transport.ts";
import { reconciliationEvents } from "./reconcile-events.ts";
export async function reconcile(data: Projection, config: Settings) {
  if (!data?.indexed || !data.complete)
    throw new Error("Cannot reconcile an incomplete projection");
  if (
    data.chainId !== config.chainId ||
    data.contractAddress !== config.contractAddress
  )
    throw new Error("Snapshot identity mismatch");
  const client = createPublicClient({
    transport: custom(
      {
        request: ({ method, params }) =>
          readRpc(config.rpcUrl, method, params as unknown[] | undefined),
      },
      { retryCount: 0 },
    ),
    cacheTime: 0,
  });
  if ((await client.getChainId()) !== config.chainId)
    throw new Error("RPC chain ID mismatch");
  const blockNumber = BigInt(data.indexed.number);
  const before = await client.getBlock({ blockNumber });
  if (before.number !== blockNumber || before.hash !== data.indexed.hash)
    throw new Error("Snapshot block hash is not canonical");
  const expected = await reconciliationEvents(client, config, before);
  const read = async (functionName: string, args: unknown[] = []) =>
    client.readContract({
      address: config.contractAddress,
      abi: RentalEscrowAbi,
      functionName,
      args,
      blockNumber,
    } as any) as Promise<any>;
  const errors: string[] = [];
  const equal = (label: string, a: unknown, b: unknown) => {
    if (json(a) !== json(b))
      errors.push(`${label}: indexed=${json(a)} chain=${json(b)}`);
  };
  const obj = (
    label: string,
    local: Record<string, unknown>,
    chain: Record<string, unknown>,
  ) => {
    for (const key of new Set([...Object.keys(local), ...Object.keys(chain)]))
      equal(
        `${label}.${key}`,
        typeof local[key] === "string" && String(local[key]).startsWith("0x")
          ? String(local[key]).toLowerCase()
          : local[key],
        typeof chain[key] === "string" && String(chain[key]).startsWith("0x")
          ? String(chain[key]).toLowerCase()
          : chain[key],
      );
  };
  equal(
    "itemCount",
    String(Object.keys(data.items).length),
    await read("itemCount"),
  );
  equal(
    "reservationCount",
    String(Object.keys(data.reservations).length),
    await read("reservationCount"),
  );
  equal(
    "policyCount",
    String(Object.keys(data.policies).length),
    await read("policyCount"),
  );
  for (const [id, item] of Object.entries(data.items))
    obj(`item ${id}`, item, await read("getItem", [BigInt(id)]));
  for (const [id, r] of Object.entries(data.reservations)) {
    obj(`reservation ${id}`, r, await read("getReservation", [BigInt(id)]));
    equal(
      `reference ${id}`,
      id,
      await read("reservationByRef", [r.renter, r.clientRef]),
    );
  }
  for (const [id, p] of Object.entries(data.policies))
    obj(`policy ${id}`, p, await read("getPolicy", [BigInt(id)]));
  const renters = new Set([
    ...Object.keys(data.credits),
    ...Object.values(data.reservations).map((r) => r.renter),
  ]);
  for (const address of renters)
    equal(
      `refund ${address}`,
      data.credits[address],
      await read("refundCreditOf", [address]),
    );
  equal(
    "sum of indexed credits",
    Object.values(data.credits).reduce(
      (sum, credit) => sum + BigInt(credit),
      0n,
    ),
    data.totals.refunds,
  );
  const identities = (
    label: string,
    local: Record<string, unknown>,
    canonical: Record<string, unknown>,
  ) => {
    for (const id of Object.keys(canonical))
      if (!Object.hasOwn(local, id)) errors.push(`Missing ${label} ${id}`);
    for (const id of Object.keys(local))
      if (!Object.hasOwn(canonical, id))
        errors.push(`Unexpected ${label} ${id}`);
  };
  identities("staff", data.staff, expected.staff);
  for (const [address, enabled] of Object.entries(expected.staff)) {
    equal(`staff ${address}`, data.staff[address], enabled);
    equal(
      `staff event/storage ${address}`,
      enabled,
      await read("isStaff", [address]),
    );
  }
  equal("admin", data.admin, String(await read("admin")).toLowerCase());
  const pending = String(await read("pendingAdmin")).toLowerCase();
  equal(
    "pendingAdmin",
    data.pendingAdmin,
    /^0x0{40}$/.test(pending) ? null : pending,
  );
  identities("fee request", data.feeRequests, expected.feeRequests);
  for (const [id, r] of Object.entries(expected.feeRequests)) {
    if (Object.hasOwn(data.feeRequests, id))
      obj(`fee ${id}`, data.feeRequests[id]!, r);
    const [recipient, amount, completed] = await read("feeWithdrawalById", [
      id,
    ]);
    equal(
      `fee event/storage ${id}`,
      { recipient: r.recipient, amount: r.amount, completed: r.completed },
      {
        recipient: recipient.toLowerCase(),
        amount: amount.toString(),
        completed,
      },
    );
  }
  equal("refundsPaid", data.totals.refundsPaid, expected.refundsPaid);
  equal("feesPaid", data.totals.feesPaid, expected.feesPaid);
  for (const [field, method] of [
    ["escrow", "totalEscrowed"],
    ["refunds", "totalRefundCredits"],
    ["fees", "accruedFees"],
    ["liabilities", "totalLiabilities"],
  ] as const)
    equal(field, data.totals[field], await read(method));
  const token = (await read("token")) as Address;
  const balance = await client.readContract({
    address: token,
    abi: MockPaymentTokenAbi,
    functionName: "balanceOf",
    args: [config.contractAddress],
    blockNumber,
  });
  if (balance < BigInt(data.totals.liabilities))
    errors.push("Token balance is below liabilities");
  const after = await client.getBlock({ blockNumber });
  if (after.number !== blockNumber || after.hash !== before.hash)
    errors.push("Chain reorganized during reconciliation");
  if (errors.length)
    throw new Error(
      `RECONCILIATION FAILED at ${blockNumber}:\n${errors.join("\n")}`,
    );
  return {
    ok: true,
    blockNumber: blockNumber.toString(),
    blockHash: before.hash,
    tokenBalance: balance.toString(),
    liabilities: data.totals.liabilities,
    surplus: (balance - BigInt(data.totals.liabilities)).toString(),
  };
}
