export type Policy = {
  deposit: string;
  cancellationFee: string;
  reservationWindow: string;
};
export type Item = {
  exists: boolean;
  listed: boolean;
  state: number;
  policyId: string;
  activeReservationId: string;
  metadataURI: string;
};
export type Reservation = {
  itemId: string;
  renter: string;
  policyId: string;
  createdAt: string;
  expiresAt: string;
  status: number;
  deposit: string;
  cancellationFee: string;
  clientRef: string;
};
export type FeeRequest = {
  recipient: string;
  amount: string;
  completed: boolean;
  transactionHash: string;
};
export type Cursor = {
  number: string;
  hash: string;
  timestamp: string;
};
export type Projection = {
  chainId: number;
  contractAddress: string;
  admin: string | null;
  pendingAdmin: string | null;
  policies: Record<string, Policy>;
  items: Record<string, Item>;
  reservations: Record<string, Reservation>;
  staff: Record<string, boolean>;
  credits: Record<string, string>;
  feeRequests: Record<string, FeeRequest>;
  totals: {
    escrow: string;
    refunds: string;
    fees: string;
    liabilities: string;
    refundsPaid: string;
    feesPaid: string;
  };
  eventCount: string;
  lastEvent: {
    block: string;
    transaction: number;
    log: number;
  } | null;
  indexed: Cursor | null;
  complete: boolean;
};
export type RentalEvent = {
  name: string;
  args: Record<string, unknown>;
  block: Cursor;
  transactionHash: string;
  transactionIndex: number;
  logIndex: number;
};
export const eventNames = [
  "AdminTransferStarted",
  "AdminTransferred",
  "StaffUpdated",
  "PolicyCreated",
  "ItemAdded",
  "ItemPolicyUpdated",
  "ItemListingUpdated",
  "ItemMetadataUpdated",
  "ReservationCreated",
  "ReservationCancelled",
  "ReservationExpired",
  "ItemCheckedOut",
  "ItemReturned",
  "RefundCredited",
  "RefundWithdrawn",
  "FeesWithdrawn",
] as const;
export function initial(chainId: number, contractAddress: string): Projection {
  return {
    chainId,
    contractAddress,
    admin: null,
    pendingAdmin: null,
    policies: {},
    items: {},
    reservations: {},
    staff: {},
    credits: {},
    feeRequests: {},
    totals: {
      escrow: "0",
      refunds: "0",
      fees: "0",
      liabilities: "0",
      refundsPaid: "0",
      feesPaid: "0",
    },
    eventCount: "0",
    lastEvent: null,
    indexed: null,
    complete: false,
  };
}
function add(value: string, delta: bigint): string {
  const result = BigInt(value) + delta;
  if (result < 0n) throw new Error("Negative accounting obligation");
  return result.toString();
}
export function apply(previous: Projection, event: RentalEvent): Projection {
  const s = structuredClone(previous);
  const p = s.lastEvent;
  if (
    p &&
    (BigInt(event.block.number) < BigInt(p.block) ||
      (event.block.number === p.block &&
        (event.transactionIndex < p.transaction ||
          (event.transactionIndex === p.transaction &&
            event.logIndex <= p.log))))
  )
    throw new Error("Non-canonical event order");
  const a = event.args;
  const str = (key: string): string => {
    if (a[key] === undefined) throw new Error(`Missing ${key}`);
    return String(a[key]);
  };
  const addr = (key: string) => str(key).toLowerCase();
  const amount = (key: string) => BigInt(str(key));
  const item = () => {
    const i = s.items[str("itemId")];
    if (!i) throw new Error("Missing item");
    return i;
  };
  const reservation = () => {
    const r = s.reservations[str("reservationId")];
    if (!r) throw new Error("Missing reservation");
    return r;
  };
  switch (event.name) {
    case "AdminTransferred":
      s.admin = addr("newAdmin");
      s.pendingAdmin = null;
      break;
    case "AdminTransferStarted":
      s.pendingAdmin = /^0x0{40}$/i.test(str("pendingAdmin"))
        ? null
        : addr("pendingAdmin");
      break;
    case "StaffUpdated":
      s.staff[addr("account")] = a.enabled === true;
      break;
    case "PolicyCreated": {
      const id = str("policyId");
      if (s.policies[id]) throw new Error("Policy is immutable");
      s.policies[id] = {
        deposit: str("deposit"),
        cancellationFee: str("cancellationFee"),
        reservationWindow: str("reservationWindow"),
      };
      break;
    }
    case "ItemAdded": {
      const id = str("itemId");
      if (s.items[id]) throw new Error("Item already exists");
      if (!s.policies[str("policyId")]) throw new Error("Unknown policy");
      s.items[id] = {
        exists: true,
        listed: true,
        state: 0,
        policyId: str("policyId"),
        activeReservationId: "0",
        metadataURI: str("metadataURI"),
      };
      break;
    }
    case "ItemPolicyUpdated":
      if (
        item().policyId !== str("oldPolicyId") ||
        !s.policies[str("newPolicyId")]
      )
        throw new Error("Policy transition mismatch");
      item().policyId = str("newPolicyId");
      break;
    case "ItemListingUpdated":
      item().listed = a.listed === true;
      break;
    case "ItemMetadataUpdated":
      item().metadataURI = str("metadataURI");
      break;
    case "ReservationCreated": {
      const id = str("reservationId");
      if (s.reservations[id] || item().state !== 0)
        throw new Error("Reservation conflict");
      const policy = s.policies[str("policyId")];
      if (
        !policy ||
        policy.deposit !== str("deposit") ||
        policy.cancellationFee !== str("cancellationFee") ||
        item().policyId !== str("policyId") ||
        BigInt(event.block.timestamp) + BigInt(policy.reservationWindow) !==
          amount("expiresAt")
      )
        throw new Error("Accepted policy mismatch");
      s.reservations[id] = {
        itemId: str("itemId"),
        renter: addr("renter"),
        policyId: str("policyId"),
        createdAt: event.block.timestamp,
        expiresAt: str("expiresAt"),
        status: 1,
        deposit: str("deposit"),
        cancellationFee: str("cancellationFee"),
        clientRef: str("clientRef"),
      };
      item().state = 1;
      item().activeReservationId = id;
      s.credits[addr("renter")] ??= "0";
      s.totals.escrow = add(s.totals.escrow, amount("deposit"));
      break;
    }
    case "ItemCheckedOut": {
      const r = reservation();
      if (r.status !== 1 || item().activeReservationId !== str("reservationId"))
        throw new Error("Invalid checkout");
      r.status = 2;
      item().state = 2;
      break; // Active reservation deliberately retained.
    }
    case "ReservationCancelled":
    case "ReservationExpired":
    case "ItemReturned": {
      const r = reservation();
      const returned = event.name === "ItemReturned";
      if (
        r.status !== (returned ? 2 : 1) ||
        item().activeReservationId !== str("reservationId")
      )
        throw new Error("Invalid settlement");
      const fee = returned ? 0n : amount("fee");
      if (
        fee !== (returned ? 0n : BigInt(r.cancellationFee)) ||
        amount("refund") + fee !== BigInt(r.deposit)
      )
        throw new Error("Settlement terms mismatch");
      r.status = returned ? 5 : event.name === "ReservationCancelled" ? 3 : 4;
      item().state = 0;
      item().activeReservationId = "0";
      s.totals.escrow = add(s.totals.escrow, -BigInt(r.deposit));
      s.totals.fees = add(s.totals.fees, fee);
      // RefundCredited alone changes credits. It precedes this domain event on chain.
      break;
    }
    case "RefundCredited": {
      const address = addr("beneficiary");
      const r = reservation();
      if (r.renter !== address || amount("amount") <= 0n)
        throw new Error("Invalid credit");
      s.credits[address] = add(s.credits[address] ?? "0", amount("amount"));
      s.totals.refunds = add(s.totals.refunds, amount("amount"));
      break;
    }
    case "RefundWithdrawn": {
      const address = addr("beneficiary");
      const paid = amount("amount");
      s.credits[address] = add(s.credits[address] ?? "0", -paid);
      s.totals.refunds = add(s.totals.refunds, -paid);
      s.totals.refundsPaid = add(s.totals.refundsPaid, paid);
      break;
    }
    case "FeesWithdrawn": {
      const id = str("requestId");
      if (s.feeRequests[id]) throw new Error("Duplicate fee request");
      s.feeRequests[id] = {
        recipient: addr("to"),
        amount: str("amount"),
        completed: true,
        transactionHash: event.transactionHash,
      };
      s.totals.fees = add(s.totals.fees, -amount("amount"));
      s.totals.feesPaid = add(s.totals.feesPaid, amount("amount"));
      break;
    }
    default:
      throw new Error(`Unhandled event ${event.name}`);
  }
  s.totals.liabilities = (
    BigInt(s.totals.escrow) +
    BigInt(s.totals.refunds) +
    BigInt(s.totals.fees)
  ).toString();
  s.eventCount = add(s.eventCount, 1n);
  s.lastEvent = {
    block: event.block.number,
    transaction: event.transactionIndex,
    log: event.logIndex,
  };
  s.complete = false;
  return s;
}
