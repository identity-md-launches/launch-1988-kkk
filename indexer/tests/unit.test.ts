import test from "node:test";
import assert from "node:assert/strict";
import { apply, initial, type RentalEvent } from "../shared/domain.ts";
import { localUrl, parseSettings, json } from "../shared/config.ts";
import {
  encodeEventTopics,
  type Block,
  type PublicClient,
  type Hex,
} from "viem";
import { RentalEscrowAbi } from "../abis/RentalEscrow.ts";
import { reconciliationEvents } from "../shared/reconcile-events.ts";
// Public synthetic Anvil development addresses, used only in unit fixtures.
const admin = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
const renter = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8";
const escrow = "0x5fbdb2315678afecb367f032d93f642f64180aa3";
function fixture(deposit = "50000000", fee = "5000000") {
  let state = initial(31337, escrow);
  let n = 0;
  const emit = (name: string, args: Record<string, unknown>) => {
    n++;
    const e: RentalEvent = {
      name,
      args,
      block: {
        number: String(n),
        hash: `0x${n.toString(16).padStart(64, "0")}`,
        timestamp: "100",
      },
      transactionHash: `0x${n.toString(16).padStart(64, "0")}`,
      transactionIndex: 0,
      logIndex: 0,
    };
    state = apply(state, e);
    return state;
  };
  emit("AdminTransferred", { newAdmin: admin });
  emit("PolicyCreated", {
    policyId: "1",
    deposit,
    cancellationFee: fee,
    reservationWindow: "120",
  });
  emit("ItemAdded", {
    itemId: "1",
    policyId: "1",
    metadataURI: "synthetic://unit",
  });
  emit("ReservationCreated", {
    reservationId: "1",
    itemId: "1",
    renter,
    policyId: "1",
    deposit,
    cancellationFee: fee,
    expiresAt: "220",
    clientRef: `0x${"1".repeat(64)}`,
  });
  return { emit, get: () => state };
}
test("checkout retains active reservation, and later policy does not mutate accepted terms", () => {
  const f = fixture();
  f.emit("PolicyCreated", {
    policyId: "2",
    deposit: "90000000",
    cancellationFee: "9000000",
    reservationWindow: "10",
  });
  f.emit("ItemPolicyUpdated", {
    itemId: "1",
    oldPolicyId: "1",
    newPolicyId: "2",
  });
  const s = f.emit("ItemCheckedOut", {
    reservationId: "1",
    itemId: "1",
    staff: admin,
  });
  assert.equal(s.items["1"]!.state, 2);
  assert.equal(s.items["1"]!.activeReservationId, "1");
  assert.equal(s.reservations["1"]!.deposit, "50000000");
  assert.equal(s.reservations["1"]!.expiresAt, "220");
});
test("settlement credits only from RefundCredited and subtracts actual withdrawal amount", () => {
  const f = fixture();
  f.emit("RefundCredited", {
    beneficiary: renter,
    reservationId: "1",
    amount: "45000000",
  });
  let s = f.emit("ReservationCancelled", {
    reservationId: "1",
    itemId: "1",
    renter,
    refund: "45000000",
    fee: "5000000",
  });
  assert.equal(s.totals.refunds, "45000000");
  assert.equal(s.totals.fees, "5000000");
  assert.equal(s.totals.escrow, "0");
  // The reducer follows actual event amounts; it never infers the payment from the current credit.
  s = f.emit("RefundWithdrawn", { beneficiary: renter, amount: "20000000" });
  assert.equal(s.credits[renter], "25000000");
  assert.equal(s.totals.refundsPaid, "20000000");
});
test("zero-refund full-fee cancellation requires no credit event", () => {
  const f = fixture("5", "5");
  const s = f.emit("ReservationCancelled", {
    reservationId: "1",
    itemId: "1",
    renter,
    refund: "0",
    fee: "5",
  });
  assert.equal(s.totals.refunds, "0");
  assert.equal(s.totals.fees, "5");
});
test("uint256 values serialize without floating-point loss", () => {
  const maximum = ((1n << 256n) - 1n).toString();
  const f = fixture(maximum, "0");
  const output = JSON.parse(json(f.get()));
  assert.equal(output.totals.escrow, maximum);
  assert.equal(output.reservations["1"].deposit, maximum);
});
test("duplicate/out-of-order domain events fail unless ingestion deduplication removes them first", () => {
  const f = fixture();
  assert.throws(
    () =>
      apply(f.get(), {
        name: "StaffUpdated",
        args: { account: admin, enabled: true },
        block: { number: "1", hash: "0x1", timestamp: "100" },
        transactionHash: "0x1",
        transactionIndex: 0,
        logIndex: 0,
      }),
    /order/,
  );
});
test("immutable policy, invalid settlement and negative accounting fail loudly", () => {
  const f = fixture();
  assert.throws(
    () =>
      f.emit("PolicyCreated", {
        policyId: "1",
        deposit: "5",
        cancellationFee: "1",
        reservationWindow: "10",
      }),
    /immutable/,
  );
  assert.throws(
    () =>
      f.emit("ReservationCancelled", {
        reservationId: "1",
        itemId: "1",
        renter,
        refund: "0",
        fee: "5000000",
      }),
    /terms/,
  );
  assert.throws(
    () => f.emit("RefundWithdrawn", { beneficiary: renter, amount: "1" }),
    /Negative/,
  );
});
test("read-only local configuration rejects external RPC, credentials, placeholders and fractional IDs", () => {
  for (const url of [
    "https://mainnet.example",
    "http://localhost:8545",
    "http://127.0.0.1.evil.example",
    "http://user:password@127.0.0.1",
    "http://127.0.0.1/?key=secret",
  ])
    assert.throws(() => localUrl(url));
  const config = {
    rpcUrl: "http://127.0.0.1:8545",
    chainId: 31337,
    contractAddress: escrow,
    deploymentBlock: 2,
    databaseDirectory: ".data/unit",
    apiPort: 42069,
  };
  assert.equal(parseSettings(config).chainId, 31337);
  assert.throws(() => parseSettings({ ...config, chainId: 1.5 }));
  assert.throws(() =>
    parseSettings({ ...config, contractAddress: "REPLACE_ME" }),
  );
  assert.throws(() =>
    parseSettings({ ...config, contractAddress: `0x${"0".repeat(40)}` }),
  );
  assert.throws(() =>
    parseSettings({ ...config, databaseDirectory: "memory://" }),
  );
});
import { normalizeLogs, readRpc } from "../shared/transport.ts";
test("RPC overlaps are normalized; conflicting logs and transaction methods fail closed", async () => {
  const log = {
    address: escrow,
    blockHash: "0x1",
    blockNumber: "0x1",
    transactionHash: "0x2",
    transactionIndex: "0x0",
    logIndex: "0x0",
    data: "0x",
    topics: [],
    removed: false,
  };
  assert.deepEqual(normalizeLogs([log, { ...log }]), [log]);
  assert.throws(
    () => normalizeLogs([log, { ...log, data: "0x1234" }]),
    /Conflicting RPC logs/,
  );
  await assert.rejects(
    () => readRpc("http://127.0.0.1:8545", "eth_sendTransaction"),
    /refuses/,
  );
});

test("independent event audit preserves large cumulative payments and orders same-block staff updates", async () => {
  // Synthetic ABI fixtures supplement the real Anvil tests (whose fixed token supply
  // is below Number.MAX_SAFE_INTEGER). No projection or history is provided here.
  const word = (value: bigint) =>
    `0x${value.toString(16).padStart(64, "0")}` as Hex;
  const block = {
    number: 2n,
    hash: word(10n),
    transactions: [word(11n)],
  } as Block;
  const logs: any[] = [];
  const emit = (
    name:
      | "AdminTransferred"
      | "StaffUpdated"
      | "FeesWithdrawn"
      | "RefundWithdrawn",
    args: any,
    value?: bigint,
  ) => {
    logs.push({
      address: escrow,
      blockNumber: block.number,
      blockHash: block.hash,
      transactionHash: block.transactions[0],
      transactionIndex: 0,
      logIndex: logs.length,
      removed: false,
      topics: encodeEventTopics({
        abi: RentalEscrowAbi,
        eventName: name,
        args,
      }),
      data: value === undefined ? "0x" : word(value),
    });
  };
  emit("AdminTransferred", {
    previousAdmin: `0x${"0".repeat(40)}`,
    newAdmin: admin,
  });
  const large = (1n << 200n) + 1n;
  emit("FeesWithdrawn", { requestId: word(1n), to: admin }, large);
  emit("RefundWithdrawn", { beneficiary: renter }, large + 2n);
  emit("StaffUpdated", { account: renter }, 1n);
  emit("FeesWithdrawn", { requestId: word(2n), to: admin }, 3n);
  emit("RefundWithdrawn", { beneficiary: renter }, 4n);
  emit("StaffUpdated", { account: renter }, 0n);
  const config = parseSettings({
    rpcUrl: "http://127.0.0.1:8545",
    contractAddress: escrow,
    deploymentBlock: 2,
    databaseDirectory: ".data/unit",
  });
  const client = {
    getLogs: async () => [...logs].reverse(),
    getBlock: async () => {
      throw new Error("Indexed header should be reused");
    },
  } as unknown as PublicClient;
  const result = await reconciliationEvents(client, config, block);
  assert.equal(result.feesPaid, large + 3n);
  assert.equal(result.refundsPaid, large + 6n);
  assert.equal(result.feeRequests[word(1n)]!.amount, large.toString());
  assert.deepEqual(result.staff, { [renter]: false });
});
