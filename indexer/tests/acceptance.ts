import assert from "node:assert/strict";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { createInterface } from "node:readline";
import { RentalEscrowAbi as rentalAbi } from "../abis/RentalEscrow.ts";
import { MockPaymentTokenAbi as tokenAbi } from "../abis/MockPaymentToken.ts";
import { parseSettings, rpc, json } from "../shared/config.ts";
import { reconcile } from "../shared/reconcile.ts";
import {
  chain,
  port,
  run,
  stop,
  cleanup,
  until,
  proxy,
  indexerRoot,
  key,
  get,
  assertAnvil,
} from "./harness.ts";
import type { ChildProcess } from "node:child_process";
const trial = resolve(indexerRoot, ".data", `trial-${Date.now()}`);
mkdirSync(trial, { recursive: true });
const evidence: {
  name: string;
  milliseconds: number;
  details: unknown;
}[] = [];
let prox: Awaited<ReturnType<typeof proxy>> | undefined;
let indexer: ChildProcess | undefined;
let interrupted = false;
async function interrupt(code: number) {
  if (interrupted) return;
  interrupted = true;
  await cleanup();
  if (prox) await prox.close().catch(() => {});
  process.exit(code);
}
process.once("SIGINT", () => void interrupt(130));
process.once("SIGTERM", () => void interrupt(143));

const measure = async (name: string, fn: () => Promise<unknown>) => {
  const start = performance.now();
  const details = await fn();
  const row = {
    name,
    milliseconds: Math.round(performance.now() - start),
    details,
  };
  evidence.push(row);
  console.log(json(row));
};
try {
  const anvilPort = await port();
  const apiPort = await port();
  const url = `http://127.0.0.1:${anvilPort}`;
  const anvil = run(
    process.env.ANVIL_BIN ?? "anvil",
    [
      "--host",
      "127.0.0.1",
      "--port",
      String(anvilPort),
      "--chain-id",
      "31337",
      "--silent",
    ],
    resolve(trial, "anvil.log"),
  );
  await until(
    "isolated Anvil",
    async () => {
      if (anvil.exitCode !== null) throw new Error("Anvil exited");
      await assertAnvil(url);
      return true;
    },
    15000,
  );
  const c = await chain(url);
  const token = await c.deploy("MockPaymentToken", [c.admin]);
  const rental = await c.deploy("RentalEscrow", [token.address, c.admin]);
  const tx = (
    name: string,
    args: unknown[] = [],
    account = c.admin,
    success = true,
  ) => c.send(rental.address, rentalAbi, name, args, account, success);
  const tokenTx = (name: string, args: unknown[], account = c.admin) =>
    c.send(token.address, tokenAbi, name, args, account);
  await tx("setStaff", [c.staff, true]);
  await tx("createPolicy", [50000000n, 5000000n, 120n]);
  for (let i = 1; i <= 4; i++)
    await tx("addItem", [1n, `synthetic://equipment/${i}`]);
  await tokenTx("transfer", [c.renter, 5000000000n]);
  const reserve = async (
    item: bigint,
    policy: bigint,
    deposit: bigint,
    label: string,
  ) => {
    await tokenTx("approve", [rental.address, deposit], c.renter);
    await tx("reserve", [item, policy, key(label)], c.renter);
  };
  prox = await proxy(url);
  const raw = {
    rpcUrl: prox.url,
    chainId: 31337,
    contractAddress: rental.address,
    deploymentBlock: rental.block,
    databaseDirectory: resolve(trial, "database"),
    apiPort,
    reorgWindow: 120,
  };
  const config = parseSettings(raw);
  const configFile = resolve(trial, "config.json");
  writeFileSync(configFile, json(raw) + "\n");
  const base = `http://127.0.0.1:${apiPort}`;
  const start = () =>
    run(
      process.execPath,
      ["scripts/start.mjs"],
      resolve(trial, "indexer.log"),
      { RENTAL_CONFIG: configFile },
    );
  const synced = async (label = "indexer catch-up", timeout = 60000) =>
    until(
      label,
      async () => {
        if (indexer?.exitCode !== null && indexer?.exitCode !== undefined)
          throw new Error(`Indexer exited; see ${trial}/indexer.log`);
        const s = await get(base, "/snapshot");
        const head = await c.publicClient.getBlock();
        return s.status.current && s.data?.indexed?.hash === head.hash
          ? s
          : false;
      },
      timeout,
    );
  const check = async () => {
    const s = await synced();
    return reconcile(s.data, config);
  };
  await measure("startup", async () => {
    indexer = start();
    return (await synced()).status;
  });
  await measure("A lifecycle and original terms", async () => {
    await reserve(1n, 1n, 50000000n, "returned");
    await tx("createPolicy", [80000000n, 9000000n, 180n]);
    await tx("setItemPolicy", [1n, 2n]);
    await tx("checkOut", [1n], c.staff);
    let s = await synced();
    assert.equal(s.data.items["1"].state, 2);
    assert.equal(s.data.items["1"].activeReservationId, "1");
    assert.equal(s.data.reservations["1"].deposit, "50000000");
    assert.equal(s.data.reservations["1"].policyId, "1");
    assert.equal(
      (await get(base, "/reservations/1")).reservation.cancellationFee,
      "5000000",
    );
    assert.ok(
      !(await get(base, "/equipment/available")).items.some(
        (i: any) => i.id === "1",
      ),
    );
    await tx("setStaff", [c.staff, false]);
    await tx("confirmReturn", [1n], c.staff, false);
    s = await synced();
    assert.equal(s.data.staff[c.staff.toLowerCase()], false);
    assert.equal(s.data.reservations["1"].status, 2);
    await tx("setStaff", [c.staff, true]);
    await tx("confirmReturn", [1n], c.staff);
    await tx("withdrawRefund", [], c.renter);
    await reserve(2n, 1n, 50000000n, "cancelled");
    await tx("cancel", [2n], c.renter);
    await reserve(3n, 1n, 50000000n, "expired");
    await rpc(url, "evm_increaseTime", [121]);
    await rpc(url, "evm_mine");
    await tx("expire", [3n], c.nextAdmin);
    const request = key("fee-one"),
      request2 = key("fee-two");
    await tx("withdrawFees", [request, c.admin, 5000000n]);
    await tx("withdrawFees", [request, c.admin, 5000000n], c.admin, false);
    await tx("withdrawFees", [request, c.staff, 5000000n], c.admin, false);
    await tx("withdrawFees", [request, c.admin, 4000000n], c.admin, false);
    await tx("withdrawFees", [request2, c.admin, 5000000n]);
    await tx("setItemListed", [4n, false]);
    await tx("setItemMetadata", [4n, "synthetic://equipment/updated"]);
    await tx("transferAdmin", [c.nextAdmin]);
    await tx("acceptAdmin", [], c.nextAdmin);
    await tx("transferAdmin", [c.admin], c.nextAdmin);
    await tx("acceptAdmin");
    s = await synced();
    assert.equal(s.data.reservations["2"].status, 3);
    assert.equal(s.data.reservations["3"].status, 4);
    assert.deepEqual(s.data.totals, {
      escrow: "0",
      refunds: "90000000",
      fees: "0",
      liabilities: "90000000",
      refundsPaid: "50000000",
      feesPaid: "10000000",
    });
    const renterHistory = await get(base, `/renters/${c.renter}`);
    assert.equal(renterHistory.refundCredit, "90000000");
    assert.ok(
      renterHistory.activity.some(
        (row: any) =>
          row.event.name === "RefundWithdrawn" &&
          row.event.args.amount === "50000000",
      ),
    );
    assert.ok(
      renterHistory.activity.some(
        (row: any) => row.event.name === "ItemCheckedOut",
      ),
    );
    assert.equal(
      (await get(base, `/fees/${request}`)).request.amount,
      "5000000",
    );
    assert.equal(Object.keys(s.data.feeRequests).length, 2);
    await tx("withdrawRefund", [], c.renter);
    await tx("withdrawRefund", [], c.renter, false);
    // Direct token donation is surplus, never a fabricated accounting obligation.
    await tokenTx("transfer", [rental.address, 123n]);
    await reserve(1n, 2n, 80000000n, "active-new-terms");
    const result = await check();
    assert.equal(result.surplus, "123");
    const before = await synced();
    const corrupted = structuredClone(before.data);
    corrupted.totals.escrow = "1";
    await assert.rejects(
      () => reconcile(corrupted, config),
      /RECONCILIATION FAILED/,
    );
    const missingTerms = structuredClone(before.data);
    delete missingTerms.reservations["1"].deposit;
    await assert.rejects(
      () => reconcile(missingTerms, config),
      /RECONCILIATION FAILED/,
    );
    const missingCredit = structuredClone(before.data);
    delete missingCredit.credits[c.renter.toLowerCase()];
    await assert.rejects(
      () => reconcile(missingCredit, config),
      /RECONCILIATION FAILED/,
    );
    assert.deepEqual((await synced()).data, before.data);
    writeFileSync(
      resolve(trial, "example-reservation.json"),
      json(await get(base, "/reservations/1")) + "\n",
    );
    writeFileSync(resolve(trial, "example-snapshot.json"), json(before) + "\n");
    return result;
  });
  await measure("C duplicate logs through real RPC ingestion", async () => {
    const s = await synced();
    const events = (await get(base, "/history?limit=1000")).events;
    const logs = await rpc<any[]>(url, "eth_getLogs", [
      {
        address: rental.address,
        fromBlock: `0x${rental.block.toString(16)}`,
        toBlock: `0x${BigInt(s.data.indexed.number).toString(16)}`,
      },
    ]);
    assert.ok(prox!.state.duplicatedLogs > 0);
    assert.equal(new Set(events.map((e: any) => e.id)).size, events.length);
    assert.equal(events.length, logs.length);
    assert.equal(s.data.eventCount, String(logs.length));
    return {
      duplicatedRpcLogs: prox!.state.duplicatedLogs,
      canonicalLogs: logs.length,
      indexedHistory: events.length,
      reconciliation: await check(),
    };
  });
  await measure("B stopped activity and same-database restart", async () => {
    await stop(indexer!);
    const marker = readFileSync(
      resolve(config.databaseDirectory, "identity.json"),
      "utf8",
    );
    await tx("cancel", [4n], c.renter);
    await tx("setItemListed", [4n, true]);
    for (let i = 0; i < 12; i++)
      await tx("setItemMetadata", [4n, `synthetic://offline/${i}`]);
    const begin = performance.now();
    indexer = start();
    const s = await synced();
    assert.equal(
      readFileSync(resolve(config.databaseDirectory, "identity.json"), "utf8"),
      marker,
    );
    assert.equal(s.data.items["4"].metadataURI, "synthetic://offline/11");
    assert.equal(s.data.reservations["4"].status, 3);
    return {
      catchUpMs: Math.round(performance.now() - begin),
      databaseReused: true,
      reconciliation: await check(),
    };
  });
  await measure(
    "B abrupt termination during catch-up and recovery",
    async () => {
      await stop(indexer!);
      for (let i = 0; i < 45; i++)
        await tx("setItemMetadata", [4n, `synthetic://crash/${i}`]);
      prox!.state.delayMs = 100;
      const head = await c.publicClient.getBlockNumber();
      indexer = start();
      const partial = await until(
        "persisted partial projection before abrupt termination",
        async () => {
          const value = await get(base, "/snapshot");
          const number = value.data?.indexed?.number;
          return number &&
            BigInt(number) > BigInt(rental.block) &&
            BigInt(number) < head &&
            !value.status.current
            ? value
            : false;
        },
        45000,
      );
      const atKill = partial.status;
      await stop(indexer!, true);
      prox!.state.delayMs = 0;
      const begin = performance.now();
      indexer = start();
      const s = await synced("crash recovery", 90000);
      assert.equal(s.data.items["4"].metadataURI, "synthetic://crash/44");
      return {
        catchUpMs: Math.round(performance.now() - begin),
        statusAtKill: atKill,
        reconciliation: await check(),
      };
    },
  );
  await measure("D RPC outage while chain advances", async () => {
    const priorFailures = prox!.state.ingestionOutages;
    prox!.state.outage = true;
    const stale = await get(base, "/sync");
    assert.equal(stale.current, false);
    assert.ok(stale.connectionError);
    await tx("setItemMetadata", [4n, "synthetic://during-outage"]);
    const still = await get(base, "/snapshot");
    assert.equal(still.status.current, false);
    assert.ok(still.status.connectionError);
    assert.notEqual(
      still.data.items["4"].metadataURI,
      "synthetic://during-outage",
    );
    await until(
      "Ponder ingestion observes RPC outage",
      async () => prox!.state.ingestionOutages > priorFailures,
      10000,
    );
    prox!.state.outage = false;
    const begin = performance.now();
    const s = await synced();
    assert.equal(s.data.items["4"].metadataURI, "synthetic://during-outage");
    return {
      catchUpMs: Math.round(performance.now() - begin),
      outageStatus: stale,
      ingestionFailures: prox!.state.ingestionOutages - priorFailures,
      reconciliation: await check(),
    };
  });
  await measure("E short reorganization", async () => {
    const original = await synced();
    const snapshot = await rpc<string>(url, "evm_snapshot");
    await reserve(2n, 1n, 50000000n, "orphan");
    await tx("cancel", [5n], c.renter);
    const orphanRequest = key("orphan-fee");
    await tx("withdrawFees", [orphanRequest, c.admin, 1000000n]);
    const branch = await synced();
    assert.equal(branch.data.reservations["5"].status, 3);
    assert.ok(branch.data.feeRequests[orphanRequest]);
    const orphanIds = (await get(base, "/history?limit=1000")).events
      .filter(
        (e: any) =>
          BigInt(e.blockNumber) > BigInt(original.data.indexed.number),
      )
      .map((e: any) => e.id);
    assert.equal(await rpc(url, "evm_revert", [snapshot]), true);
    await rpc(url, "evm_increaseTime", [1]);
    await tx("setItemMetadata", [2n, "synthetic://canonical-branch"]);
    for (let i = 0; i < 6; i++) await rpc(url, "evm_mine");
    const s = await synced("canonical branch after reorg");
    assert.equal(s.data.reservations["5"], undefined);
    assert.equal(s.data.feeRequests[orphanRequest], undefined);
    assert.deepEqual(s.data.totals, original.data.totals);
    assert.equal(s.data.items["2"].state, 0);
    const ids = (await get(base, "/history?limit=1000")).events.map(
      (e: any) => e.id,
    );
    for (const id of orphanIds) assert.ok(!ids.includes(id));
    return {
      orphanedBlocks: Number(
        BigInt(branch.data.indexed.number) -
          BigInt(original.data.indexed.number),
      ),
      reorgWindowSeconds: config.reorgWindow,
      removedHistory: orphanIds.length,
      reconciliation: await check(),
    };
  });
  await measure(
    "F independent empty-database rebuild at common block",
    async () => {
      const original = await synced();
      const originalHistory = (await get(base, "/history?limit=1000")).events;
      await stop(indexer!);
      const rebuild = { ...raw, databaseDirectory: resolve(trial, "rebuild") };
      writeFileSync(configFile, json(rebuild) + "\n");
      const begin = performance.now();
      indexer = start();
      const other = await synced("empty database rebuild");
      assert.deepEqual(other.data, original.data);
      assert.deepEqual(
        (await get(base, "/history?limit=1000")).events,
        originalHistory,
      );
      const rebuildMs = Math.round(performance.now() - begin);
      const result = await reconcile(other.data, parseSettings(rebuild));
      await stop(indexer!);
      writeFileSync(configFile, json(raw) + "\n");
      indexer = start();
      await synced();
      return {
        rebuildMs,
        commonBlock: original.data.indexed,
        domainAndHistoryEqual: true,
        reconciliation: result,
      };
    },
  );
  await measure("configuration and read-only negative checks", async () => {
    await stop(indexer!);
    await assert.rejects(() => assertAnvil("http://example.com"), /loopback/);
    const wrongPort = await port();
    const wrongUrl = `http://127.0.0.1:${wrongPort}`;
    const wrongChain = run(
      process.env.ANVIL_BIN ?? "anvil",
      [
        "--host",
        "127.0.0.1",
        "--port",
        String(wrongPort),
        "--chain-id",
        "31338",
        "--silent",
      ],
      resolve(trial, "wrong-chain.log"),
    );
    await until(
      "unexpected-chain Anvil ready",
      async () => await rpc<string>(wrongUrl, "eth_chainId"),
      15000,
    );
    await assert.rejects(() => chain(wrongUrl), /chain ID 31337/);
    await stop(wrongChain);
    const bad = { ...raw, rpcUrl: url, chainId: 31338 };
    writeFileSync(configFile, json(bad) + "\n");
    const result = spawnSync(
      process.execPath,
      ["--no-use-env-proxy", "scripts/start.mjs"],
      {
        cwd: indexerRoot,
        env: { ...process.env, RENTAL_CONFIG: configFile },
        encoding: "utf8",
        timeout: 10000,
      },
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /chain ID/);
    const other = await c.deploy("RentalEscrow", [token.address, c.admin]);
    writeFileSync(
      configFile,
      json({
        ...raw,
        rpcUrl: url,
        contractAddress: other.address,
        deploymentBlock: other.block,
      }) + "\n",
    );
    const mismatch = spawnSync(
      process.execPath,
      ["--no-use-env-proxy", "scripts/start.mjs"],
      {
        cwd: indexerRoot,
        env: { ...process.env, RENTAL_CONFIG: configFile },
        encoding: "utf8",
        timeout: 10000,
      },
    );
    assert.notEqual(mismatch.status, 0);
    assert.match(mismatch.stderr, /Database identity mismatch/);
    writeFileSync(configFile, json(raw) + "\n");
    indexer = start();
    await synced();
    const response = await fetch(prox!.url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: json({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_sendTransaction",
        params: [],
      }),
    });
    assert.equal(response.status, 403);
    return {
      databaseMismatchRejected: true,
      readOnlyMethods: [...prox!.state.methods].sort(),
    };
  });
  await measure(
    "reconciliation CLI success and mismatch exit status",
    async () => {
      const execute = async (api: string, log: string) => {
        const command = run(
          process.execPath,
          ["--no-use-env-proxy", "scripts/reconcile.ts", api],
          resolve(trial, log),
          { RENTAL_CONFIG: configFile },
        );
        await until(
          "reconciliation command exit",
          async () => command.exitCode !== null,
          15000,
        );
        return {
          code: command.exitCode,
          output: readFileSync(resolve(trial, log), "utf8"),
        };
      };
      const success = await execute(base, "reconcile-success.log");
      assert.equal(success.code, 0);
      assert.match(success.output, /"ok":true/);
      const original = await synced();
      const damaged = structuredClone(original);
      damaged.data.totals.escrow = "123456";
      const api = createServer((_, res) => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(json(damaged));
      });
      await new Promise<void>((r) => api.listen(0, "127.0.0.1", r));
      const address = api.address();
      assert.ok(address && typeof address !== "string");
      let failure;
      try {
        failure = await execute(
          `http://127.0.0.1:${address.port}`,
          "reconcile-mismatch.log",
        );
      } finally {
        api.closeAllConnections();
        await new Promise<void>((r) => api.close(() => r()));
      }
      assert.equal(failure.code, 1);
      assert.match(failure.output, /RECONCILIATION FAILED/);
      assert.deepEqual((await synced()).data, original.data);
      return {
        successExit: success.code,
        mismatchExit: failure.code,
        originalProjectionUnchanged: true,
      };
    },
  );
  const final = await synced();
  writeFileSync(
    resolve(trial, "evidence.json"),
    json({ result: "passed", evidence, final }) + "\n",
  );
  console.log(`PASS: local acceptance A–F. Evidence: ${trial}/evidence.json`);
  if (process.argv.includes("--demo")) {
    console.log(
      `Demo API: ${base}\nConfig: ${configFile}\nReconcile: RENTAL_CONFIG=${configFile} npm run reconcile\nCommands: restart, reconcile, quit. Ctrl-C stops this demo's children; database is retained.`,
    );
    const command = async (line: string) => {
      if (line === "restart") {
        await stop(indexer!);
        indexer = start();
        await synced();
        console.log("Restarted with the SAME database; projection rebuilt.");
      } else if (line === "reconcile") console.log(json(await check()));
      else if (line !== "quit")
        throw new Error("Commands: restart, reconcile, quit");
    };
    const commands = process.argv
      .find((a) => a.startsWith("--commands="))
      ?.slice("--commands=".length);
    if (commands) {
      for (const line of commands.split(",")) {
        if (line === "quit") break;
        await command(line);
      }
    } else {
      const input = createInterface({
        input: process.stdin,
        output: process.stdout,
      });
      const end = () => input.close();
      process.once("SIGINT", end);
      process.once("SIGTERM", end);
      for await (const line of input) {
        if (line.trim() === "quit") {
          input.close();
          break;
        }
        await command(line.trim());
      }
      process.removeListener("SIGINT", end);
      process.removeListener("SIGTERM", end);
    }
  }
} catch (e) {
  writeFileSync(
    resolve(trial, "evidence.json"),
    json({ result: "failed", error: String(e), evidence }) + "\n",
  );
  console.error(e);
  process.exitCode = 1;
} finally {
  await cleanup();
  if (prox) await prox.close();
}
