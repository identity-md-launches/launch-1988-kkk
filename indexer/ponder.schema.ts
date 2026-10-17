import { onchainTable } from "ponder";
import type { Projection, RentalEvent } from "./shared/domain.ts";
export const projection = onchainTable("projection", (p) => ({
  id: p.text().primaryKey(),
  value: p.jsonb().$type<Projection>().notNull(),
}));
export const history = onchainTable("history", (p) => ({
  id: p.text().primaryKey(),
  chainId: p.integer().notNull(),
  contractAddress: p.hex().notNull(),
  blockNumber: p.bigint().notNull(),
  blockHash: p.hex().notNull(),
  transactionHash: p.hex().notNull(),
  transactionIndex: p.integer().notNull(),
  logIndex: p.integer().notNull(),
  event: p.jsonb().$type<RentalEvent>().notNull(),
}));
