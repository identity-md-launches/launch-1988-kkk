import { ponder } from "ponder:registry";
import { projection, history } from "ponder:schema";
import { initial, apply, eventNames } from "../shared/domain.ts";
import { settings, json } from "../shared/config.ts";
const config = settings();
for (const name of eventNames) {
  ponder.on(`Rental:${name}`, async ({ event, context }) => {
    const id = `${config.chainId}:${config.contractAddress}:${event.transaction.hash}:${event.log.logIndex}`;
    const seen = await context.db.find(history, { id });
    if (seen) {
      if (seen.blockHash !== event.block.hash)
        throw new Error("Replay changed block hash without rollback");
      return; // Application guard; Ponder also deduplicates RPC ingestion.
    }
    const decoded = {
      name,
      args: JSON.parse(json(event.args)),
      block: {
        number: event.block.number.toString(),
        hash: event.block.hash,
        timestamp: event.block.timestamp.toString(),
      },
      transactionHash: event.transaction.hash,
      transactionIndex: event.transaction.transactionIndex,
      logIndex: event.log.logIndex,
    };
    await context.db.insert(history).values({
      id,
      chainId: config.chainId,
      contractAddress: config.contractAddress,
      blockNumber: event.block.number,
      blockHash: event.block.hash,
      transactionHash: event.transaction.hash,
      transactionIndex: event.transaction.transactionIndex,
      logIndex: event.log.logIndex,
      event: decoded,
    });
    const old = await context.db.find(projection, { id: "rental" });
    const value = apply(
      old?.value ?? initial(config.chainId, config.contractAddress),
      decoded,
    );
    await context.db
      .insert(projection)
      .values({ id: "rental", value })
      .onConflictDoUpdate({ value });
  });
}
ponder.on("Cursor:block", async ({ event, context }) => {
  const old = await context.db.find(projection, { id: "rental" });
  const value = old?.value ?? initial(config.chainId, config.contractAddress);
  value.indexed = {
    number: event.block.number.toString(),
    hash: event.block.hash,
    timestamp: event.block.timestamp.toString(),
  };
  value.complete = true;
  await context.db
    .insert(projection)
    .values({ id: "rental", value })
    .onConflictDoUpdate({ value });
});
