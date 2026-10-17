import { Hono } from "hono";
import { db } from "ponder:api";
import { projection, history } from "ponder:schema";
import { asc, eq, and, or, inArray, lte, sql } from "ponder";
import { isAddress } from "viem";
import { settings, json } from "../../shared/config.ts";
import { status } from "../../shared/status.ts";
const config = settings();
const app = new Hono();
const snapshot = async () =>
  (await db.select().from(projection).where(eq(projection.id, "rental")))[0]
    ?.value ?? null;
app.use("*", async (c, next) => {
  c.header("Cache-Control", "no-store");
  await next();
});
app.get("/sync", async (c) =>
  c.body(json(await status(await snapshot(), config)), 200, {
    "Content-Type": "application/json",
  }),
);
app.get("/snapshot", async (c) => {
  const data = await snapshot();
  return c.body(json({ status: await status(data, config), data }), 200, {
    "Content-Type": "application/json",
  });
});
app.get("/equipment/available", async (c) => {
  const data = await snapshot();
  return c.body(
    json({
      status: await status(data, config),
      items: Object.entries(data?.items ?? {})
        .filter(([, i]) => i.listed && i.state === 0)
        .map(([id, item]) => ({
          id,
          ...item,
          policy: data?.policies[item.policyId],
        })),
    }),
    200,
    { "Content-Type": "application/json" },
  );
});
app.get("/reservations/:id", async (c) => {
  const id = c.req.param("id");
  if (!/^[1-9][0-9]*$/.test(id))
    return c.json({ error: "Invalid reservation ID" }, 400);
  const data = await snapshot();
  const reservation = data?.reservations[id] ?? null;
  return c.body(
    json({ status: await status(data, config), reservation }),
    reservation ? 200 : 404,
    { "Content-Type": "application/json" },
  );
});
app.get("/renters/:address", async (c) => {
  const address = c.req.param("address").toLowerCase();
  if (!isAddress(address)) return c.json({ error: "Invalid renter" }, 400);
  const data = await snapshot();
  const reservations = Object.entries(data?.reservations ?? {})
    .filter(([, r]) => r.renter === address)
    .map(([id, r]) => ({ id, ...r }));
  const offset = Number(c.req.query("offset") ?? "0"),
    limit = Number(c.req.query("limit") ?? "100");
  if (
    !Number.isSafeInteger(offset) ||
    offset < 0 ||
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    limit > 1000
  )
    return c.json({ error: "offset >= 0; 1 <= limit <= 1000" }, 400);
  const activity = await db
    .select()
    .from(history)
    .where(
      and(
        lte(history.blockNumber, BigInt(data?.indexed?.number ?? "0")),
        or(
          sql`lower(${history.event}->'args'->>'beneficiary') = ${address}`,
          inArray(
            sql`${history.event}->'args'->>'reservationId'`,
            reservations.map((r) => r.id),
          ),
        ),
      ),
    )
    .orderBy(
      asc(history.blockNumber),
      asc(history.transactionIndex),
      asc(history.logIndex),
    )
    .limit(limit)
    .offset(offset);
  return c.body(
    json({
      status: await status(data, config),
      address,
      refundCredit: data?.credits[address] ?? "0",
      reservations,
      activity,
      offset,
      limit,
    }),
    200,
    { "Content-Type": "application/json" },
  );
});
app.get("/fees/:requestId", async (c) => {
  const id = c.req.param("requestId").toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(id))
    return c.json({ error: "Invalid bytes32 request ID" }, 400);
  const data = await snapshot();
  const request = data?.feeRequests[id] ?? null;
  return c.body(
    json({ status: await status(data, config), request }),
    request ? 200 : 404,
    { "Content-Type": "application/json" },
  );
});
app.get("/history", async (c) => {
  const offset = Number(c.req.query("offset") ?? "0"),
    limit = Number(c.req.query("limit") ?? "100");
  if (
    !Number.isSafeInteger(offset) ||
    offset < 0 ||
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    limit > 1000
  )
    return c.json({ error: "offset >= 0; 1 <= limit <= 1000" }, 400);
  const data = await snapshot();
  const events = await db
    .select()
    .from(history)
    .where(lte(history.blockNumber, BigInt(data?.indexed?.number ?? "0")))
    .orderBy(
      asc(history.blockNumber),
      asc(history.transactionIndex),
      asc(history.logIndex),
    )
    .limit(limit)
    .offset(offset);
  // Pagination is live/provisional; use a quiescent common block for multi-page audits.
  return c.body(
    json({ status: await status(data, config), events, offset, limit }),
    200,
    { "Content-Type": "application/json" },
  );
});
export default app;
