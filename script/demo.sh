#!/usr/bin/env bash
# Local end-to-end demo against Anvil.
#
# Starts Anvil (unless ANVIL_URL points at a running node), deploys the mock token and the escrow,
# seeds policies/items/staff, then walks one reservation through checkout, return and refund, and a
# second one through cancellation and fee withdrawal. Every step prints the cast command it ran.
#
# Requirements: foundry (forge, cast, anvil) on PATH. Nothing leaves this machine.
#
# Usage:
#   script/demo.sh                      # start a throwaway anvil on 127.0.0.1:8545, run, stop it
#   ANVIL_URL=http://127.0.0.1:8545 script/demo.sh   # use an already running anvil
#
# The keys below are Anvil's well-known development keys. They have no value anywhere else.
set -euo pipefail

cd "$(dirname "$0")/.."

ADMIN_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # account 0
ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
STAFF_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d   # account 1
STAFF=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
RENTER_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # account 2
RENTER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

STARTED_ANVIL=0
if [[ -z "${ANVIL_URL:-}" ]]; then
  ANVIL_URL=http://127.0.0.1:8545
  echo "== starting anvil on $ANVIL_URL"
  anvil --silent --port 8545 &
  ANVIL_PID=$!
  STARTED_ANVIL=1
  trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
  for _ in $(seq 1 50); do
    if cast chain-id --rpc-url "$ANVIL_URL" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
fi
export ETH_RPC_URL="$ANVIL_URL"

run() { echo "+ $*"; "$@"; }
send() { # send <key> <to> <sig> [args...]  -> prints tx status
  local key=$1; shift
  local out
  out=$(cast send --private-key "$key" --json "$@")
  echo "$out" | sed -E 's/.*"status":"(0x[0-9a-f]+)".*/   status=\1/'
}

echo "== deploying (admin = token holder = $ADMIN)"
DEPLOY_OUT=$(ESCROW_ADMIN=$ADMIN forge script script/Deploy.s.sol:Deploy --rpc-url "$ANVIL_URL" \
  --private-key "$ADMIN_KEY" --broadcast -vv 2>&1)
TOKEN=$(echo "$DEPLOY_OUT" | sed -nE 's/.*MockPaymentToken: (0x[0-9a-fA-F]{40}).*/\1/p' | head -1)
ESCROW=$(echo "$DEPLOY_OUT" | sed -nE 's/.*RentalEscrow: +(0x[0-9a-fA-F]{40}).*/\1/p' | head -1)
[[ -n "$TOKEN" && -n "$ESCROW" ]] || { echo "$DEPLOY_OUT"; echo "deploy failed"; exit 1; }
echo "   token  = $TOKEN"
echo "   escrow = $ESCROW"

echo "== seeding (staff = $STAFF, renter = $RENTER funded with 1,000 dds)"
ESCROW=$ESCROW TOKEN=$TOKEN STAFF=$STAFF RENTER=$RENTER forge script script/Seed.s.sol:Seed \
  --rpc-url "$ANVIL_URL" --private-key "$ADMIN_KEY" --broadcast -vv 2>&1 | grep -E "policy id|item ids|staff:|renter funded" | sed 's/^/   /'

echo "== token facts"
run cast call "$TOKEN" "name()(string)"
run cast call "$TOKEN" "symbol()(string)"
run cast call "$TOKEN" "decimals()(uint8)"
run cast call "$TOKEN" "totalSupply()(uint256)"

echo "== quote for item 1 (policyId, (deposit, cancellationFee, reservationWindow))"
run cast call "$ESCROW" "quote(uint256)(uint64,(uint256,uint256,uint64))" 1

echo "== renter approves the deposit and reserves item 1 with clientRef keccak('order-1')"
REF1=$(cast keccak "order-1")
send "$RENTER_KEY" "$TOKEN" "approve(address,uint256)" "$ESCROW" 50000000
send "$RENTER_KEY" "$ESCROW" "reserve(uint256,uint64,bytes32)" 1 1 "$REF1"
echo "   reservation id by ref: $(cast call "$ESCROW" "reservationByRef(address,bytes32)(uint256)" "$RENTER" "$REF1")"
echo "   totalEscrowed: $(cast call "$ESCROW" "totalEscrowed()(uint256)")"

echo "== retrying the same reservation request reverts (no duplicate deposit)"
if cast send --private-key "$RENTER_KEY" "$ESCROW" "reserve(uint256,uint64,bytes32)" 1 1 "$REF1" >/dev/null 2>&1; then
  echo "   UNEXPECTED: retry succeeded"; exit 1
else
  echo "   retry rejected as expected (ClientRefAlreadyUsed)"
fi

echo "== a second renter cannot reserve the same item"
if cast send --private-key "$ADMIN_KEY" "$ESCROW" "reserve(uint256,uint64,bytes32)" 1 1 "$(cast keccak other)" >/dev/null 2>&1; then
  echo "   UNEXPECTED: competing reservation succeeded"; exit 1
else
  echo "   competing reservation rejected as expected (ItemNotAvailable)"
fi

echo "== staff checks the item out, time passes, staff confirms return"
send "$STAFF_KEY" "$ESCROW" "checkOut(uint256)" 1
run cast rpc evm_increaseTime 172800 >/dev/null
run cast rpc evm_mine >/dev/null
send "$STAFF_KEY" "$ESCROW" "confirmReturn(uint256)" 1
echo "   refund credit of renter: $(cast call "$ESCROW" "refundCreditOf(address)(uint256)" "$RENTER")"

echo "== renter withdraws the refund (second withdrawal reverts)"
send "$RENTER_KEY" "$ESCROW" "withdrawRefund()"
if cast send --private-key "$RENTER_KEY" "$ESCROW" "withdrawRefund()" >/dev/null 2>&1; then
  echo "   UNEXPECTED: second withdrawal succeeded"; exit 1
else
  echo "   second withdrawal rejected as expected (NothingToWithdraw)"
fi

echo "== second reservation on item 2, cancelled by the renter: fee is kept"
REF2=$(cast keccak "order-2")
send "$RENTER_KEY" "$TOKEN" "approve(address,uint256)" "$ESCROW" 50000000
send "$RENTER_KEY" "$ESCROW" "reserve(uint256,uint64,bytes32)" 2 1 "$REF2"
send "$RENTER_KEY" "$ESCROW" "cancel(uint256)" 2
echo "   refund credit: $(cast call "$ESCROW" "refundCreditOf(address)(uint256)" "$RENTER")   accrued fees: $(cast call "$ESCROW" "accruedFees()(uint256)")"
send "$RENTER_KEY" "$ESCROW" "withdrawRefund()"

echo "== admin withdraws the earned fee; trying more than earned reverts"
if cast send --private-key "$ADMIN_KEY" "$ESCROW" "withdrawFees(address,uint256)" "$ADMIN" 5000001 >/dev/null 2>&1; then
  echo "   UNEXPECTED: over-withdrawal succeeded"; exit 1
else
  echo "   over-withdrawal rejected as expected (InsufficientFees)"
fi
send "$ADMIN_KEY" "$ESCROW" "withdrawFees(address,uint256)" "$ADMIN" 5000000

echo "== final accounting"
echo "   escrow token balance: $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$ESCROW")"
echo "   totalLiabilities:     $(cast call "$ESCROW" "totalLiabilities()(uint256)")"
echo "   renter balance:       $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$RENTER")  (started with 1000000000, paid one 5000000 fee)"
echo "== demo complete"
if [[ $STARTED_ANVIL -eq 1 ]]; then echo "== stopping anvil"; fi
