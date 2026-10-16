# Equipment rental escrow (Solidity / Foundry)

Smart-contract foundation for a small equipment-rental application: a deposit escrow
(`RentalEscrow`) paid in a six-decimal ERC-20, a mock payment token (`MockPaymentToken`,
name `kkk`, symbol `dds`, fixed supply 1,000,000), unit/fuzz/invariant tests, Anvil
deployment and seed scripts, and integration documentation for the browser interface and
backend that will be added later.

Source delivery only. Nothing here deploys to a public chain, launches a traded token or
creates a pool.

## Layout

```
foundry.toml                 compiler pin (solc 0.8.26), fuzz/invariant settings, no ffi, no fs access
remappings.txt               forge-std/ and @openzeppelin/contracts/ -> lib/
src/RentalEscrow.sol         the escrow
src/MockPaymentToken.sol     kkk / dds, 6 decimals, 1,000,000 supply
script/Deploy.s.sol          deploys token + escrow (env-driven run(), testable deploy(cfg))
script/Seed.s.sol            staff, two policies, three items, funds a demo renter
script/demo.sh               full local walk-through on Anvil using cast
test/RentalEscrow.t.sol      unit tests (47)
test/RentalEscrowFuzz.t.sol  property/fuzz tests (9)
test/invariant/              handler + 8 stateful invariants
test/MockPaymentToken.t.sol  token tests (4, one fuzz)
test/Scripts.t.sol           deploy/seed logic exercised without env or broadcast (3)
docs/INTEGRATION.md          events, ABI surface, idempotency and recovery for the UI/backend
docs/TEST-RESULTS.md         results actually obtained on this machine
lib/forge-std                vendored, v1.9.7 (plain files)
lib/openzeppelin-contracts   vendored, v5.1.0, contracts/ only (plain files)
```

No git submodules are used; the verifier can build with no network.

## Dependency versions

| Component | Version |
|---|---|
| Foundry (forge / cast / anvil) | 1.8.3 (commit `cae51ad`) |
| solc | 0.8.26 (pinned in `foundry.toml`), EVM `cancun` |
| forge-std | v1.9.7 |
| OpenZeppelin Contracts | v5.1.0 (`ERC20`, `SafeERC20`, `ReentrancyGuard`, `IERC20`) |

## Setup, build, test

```bash
# Foundry 1.8.x: https://getfoundry.sh (forge installs solc 0.8.26 on first build)
forge build
forge test                                   # unit + fuzz + invariant, ~5 s
forge fmt --check
# reproduce the verifier's fuzz inputs exactly:
FOUNDRY_FUZZ_SEED=0xa85ca939c64936ae8ea823718cfe66ec12c31ec61aa4224f74167592b3e17548 forge test
# longer runs:
forge test --fuzz-runs 5000
forge test --match-path "test/invariant/*" -vv
```

## Local demo (Anvil)

One command runs the entire flow and stops its own Anvil afterwards:

```bash
script/demo.sh
# or against a node you already run:
ANVIL_URL=http://127.0.0.1:8545 script/demo.sh
```

It deploys, seeds, reserves item 1, shows that a retry and a competing reservation are
rejected, checks out, returns, withdraws the refund (twice: second reverts), cancels a second
reservation with a fee, and withdraws the fee as admin. Expected output is reproduced in
`docs/TEST-RESULTS.md`.

Manual equivalent:

```bash
anvil                                    # terminal 1

# terminal 2 (Anvil account 0 = admin = token holder)
export ETH_RPC_URL=http://127.0.0.1:8545
export ADMIN_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ESCROW_ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  forge script script/Deploy.s.sol:Deploy --rpc-url $ETH_RPC_URL --private-key $ADMIN_KEY --broadcast
# note the printed addresses, then:
ESCROW=<escrow> TOKEN=<token> \
  forge script script/Seed.s.sol:Seed --rpc-url $ETH_RPC_URL --private-key $ADMIN_KEY --broadcast
```

Script environment variables (all local-only; defaults are Anvil's well-known accounts):

| Script | Variable | Meaning | Default |
|---|---|---|---|
| Deploy | `ESCROW_ADMIN` | escrow administrator | Anvil account 0 |
| Deploy | `TOKEN_HOLDER` | receives the 1,000,000 dds supply | `ESCROW_ADMIN` |
| Seed | `ESCROW`, `TOKEN` | addresses printed by Deploy | required |
| Seed | `STAFF` | granted staff permission | Anvil account 1 |
| Seed | `RENTER` | demo renter | Anvil account 2 |
| Seed | `RENTER_FUNDING` | base units transferred to the renter | 1,000,000,000 (1,000 dds) |

Seed creates policy 1 (50 dds deposit, 5 dds fee, 1 h window), policy 2 (200 dds deposit,
20 dds fee, 30 min window), items 1 and 2 on policy 1 and item 3 on policy 2.

## Example interactions (cast)

Amounts are token base units: 50 dds = `50000000`.

```bash
# what will the next reservation of item 1 cost? -> (policyId, (deposit, fee, window))
cast call $ESCROW "quote(uint256)(uint64,(uint256,uint256,uint64))" 1

# renter: approve exactly the deposit, reserve with an idempotency key
REF=$(cast keccak "order-1")
cast send --private-key $RENTER_KEY $TOKEN  "approve(address,uint256)" $ESCROW 50000000
cast send --private-key $RENTER_KEY $ESCROW "reserve(uint256,uint64,bytes32)" 1 1 $REF
cast call $ESCROW "reservationByRef(address,bytes32)(uint256)" $RENTER $REF      # -> reservation id

# renter: cancel before expiry (deposit - fee credited) / anyone: expire at or after expiry
cast send --private-key $RENTER_KEY $ESCROW "cancel(uint256)" 1
cast send --private-key $ANY_KEY    $ESCROW "expire(uint256)" 1

# staff: physical handover and return
cast send --private-key $STAFF_KEY $ESCROW "checkOut(uint256)" 1
cast send --private-key $STAFF_KEY $ESCROW "confirmReturn(uint256)" 1

# renter: pull the refund credit
cast call $ESCROW "refundCreditOf(address)(uint256)" $RENTER
cast send --private-key $RENTER_KEY $ESCROW "withdrawRefund()"

# admin
cast send --private-key $ADMIN_KEY $ESCROW "setStaff(address,bool)" $STAFF true
cast send --private-key $ADMIN_KEY $ESCROW "createPolicy(uint256,uint256,uint64)" 50000000 5000000 3600
cast send --private-key $ADMIN_KEY $ESCROW "addItem(uint64,string)" 1 "ipfs://..."
cast send --private-key $ADMIN_KEY $ESCROW "setItemPolicy(uint256,uint64)" 1 2
cast send --private-key $ADMIN_KEY $ESCROW "setItemListed(uint256,bool)" 1 false
cast send --private-key $ADMIN_KEY $ESCROW "withdrawFees(address,uint256)" $TREASURY 5000000

# accounting
cast call $ESCROW "totalEscrowed()(uint256)"
cast call $ESCROW "totalRefundCredits()(uint256)"
cast call $ESCROW "accruedFees()(uint256)"
cast call $ESCROW "totalLiabilities()(uint256)"       # must be <= token.balanceOf(escrow)
```

## Behaviour (the ten rules, as implemented)

1. **One active reservation per item.** `Item.state` is `Available`, `Reserved` or `Rented`
   and `activeReservationId` points at the live reservation. `reserve` requires `Available`.
2. **Atomic exact deposit.** `reserve` records the reservation, then pulls exactly
   `policy.deposit` with `safeTransferFrom` and checks the balance delta. Any shortfall
   (allowance, balance, fee-on-transfer) reverts the whole call, so no partial state exists.
3. **Snapshots.** Each reservation stores `policyId`, `deposit`, `cancellationFee` and
   `expiresAt = createdAt + reservationWindow`. Policies are immutable versions; admins change
   an item's policy pointer with `setItemPolicy`, which affects only later reservations.
   Callers pass the policy id they quoted; `PolicyMismatch` protects them from a change that
   lands between quote and transaction.
4. **Cancel before expiry.** Renter only, status `Reserved`, `block.timestamp < expiresAt`.
   Credit `deposit - cancellationFee`; fee accrues to the admin.
5. **Check out before expiry.** Staff only, same window, status becomes `Rented`.
6. **Expire at or after expiry.** Anyone, status `Reserved`, `block.timestamp >= expiresAt`.
   Same credit and fee as cancel; the credit goes to the renter, not the caller. `Rented`
   reservations can never be expired.
7. **Return.** Staff only, status `Rented`. Full deposit credited, item `Available`.
8. **Pull refunds.** `withdrawRefund` pays the caller's whole credit and zeroes it first.
   Each reservation has exactly one terminal transition, so a deposit is credited once.
9. **Admin powers.** Items, staff, policies, fee withdrawal (`withdrawFees` is capped by
   `accruedFees`, never by the token balance). Staff checks are evaluated at call time, so
   revocation is immediate. Two-step admin handover.
10. **Idempotency.** `reserve` takes a caller-chosen non-zero `clientRef`, unique per renter.
    Replaying it reverts with `ClientRefAlreadyUsed(ref, reservationId)`; every other
    transition is guarded by status, and `withdrawRefund` reverts when the credit is zero.
    Recovery procedure: `docs/INTEGRATION.md`, "Uncertain transaction outcome".

Exact boundary: at `t == expiresAt` cancel and checkOut revert and expire succeeds; at
`t == expiresAt - 1` the reverse.

## Accounting

```
totalLiabilities() = totalEscrowed + totalRefundCredits + accruedFees  <=  token.balanceOf(escrow)
```

`totalEscrowed` is the sum of deposits of `Reserved`/`Rented` reservations. On settlement a
deposit leaves `totalEscrowed` and is split into a refund credit and a fee. Tokens only leave
through `withdrawRefund` (bounded by the caller's credit) and `withdrawFees` (bounded by
`accruedFees`). The invariant suite asserts equality, the weaker `>=` form, and conservation
against ghost totals.

## Deployment parameters

| Contract | Constructor argument | Value |
|---|---|---|
| `MockPaymentToken` | `initialHolder` | address receiving the fixed 1,000,000 dds supply |
| `RentalEscrow` | `token_` | the payment token address (not called in the constructor) |
| `RentalEscrow` | `admin_` | the administrator; never the deployer by default |

Both constructors take plain addresses only, make no external calls and have no owner that
defaults to `msg.sender`. Name/symbol/decimals/supply are compiled constants.

### After launch (operational responsibilities)

- **Admin** grants staff with `setStaff`, creates at least one policy with `createPolicy`
  and lists items with `addItem`. Until a policy and item exist nothing can be reserved.
- **Admin** withdraws fees with `withdrawFees(to, amount)` and rotates itself with
  `transferAdmin` / `acceptAdmin`. Losing the admin key freezes administration (not funds:
  renters can still cancel/expire/withdraw, staff can still check out and return).
- **Staff** are the trusted signal for physical handover (`checkOut`) and return
  (`confirmReturn`). The contract cannot verify the physical world; a staff member who
  confirms a return that did not happen releases the deposit.
- **Anyone** (typically the backend) calls `expire` for reservations past `expiresAt`. No
  one is paid for this; the backend should run it on a schedule.
- **Renters** need an ERC-20 approval of at least the quoted deposit before `reserve`, and
  must call `withdrawRefund` themselves; credits are never pushed.

## Trust assumptions

- The admin is trusted to configure sensible policies and to honour fee withdrawal rules.
  It cannot reach escrowed deposits or refund credits by any code path.
- Staff are trusted for physical facts. A malicious staff member can return an item early
  (refund in full) or refuse to check out (renter can cancel at a fee, or wait for expiry).
  Staff cannot move tokens to themselves.
- The payment token is a well-behaved ERC-20 (no fee-on-transfer, no rebasing, no
  blocklist). Fee-on-transfer is detected and rejected at reserve time. A blocklist or paused
  token would make the affected withdrawals revert; funds would wait, not be lost.
- Expiry uses `block.timestamp`. A builder can shift it by a few seconds, which is
  immaterial at the minute/hour windows policies use. Do not set windows of a few seconds.
- No pause, no upgrade, no sweep of surplus. Tokens sent directly to the contract are stuck
  (by design: the admin must not be able to pull "surplus" that an accounting bug could
  misclassify).

## Known limitations

- Deposit is the only economic lever: there is no rental price, late fee or partial
  withholding on damaged returns. A damaged item still gets a full deposit credit once staff
  confirm the return. A `Disputed` state is the natural next step.
- Reservations have no planned end date; a rental ends when staff confirm the return.
- Items are not enumerable on-chain beyond `itemCount` and sequential ids; the backend should
  index `ItemAdded` events.
- `clientRef` uniqueness is per renter and permanent: a cancelled reservation's ref cannot be
  reused. Generate a fresh random ref per request.
- A delisted item with an active reservation keeps that reservation until settled.
- Tests passing is not a security audit. Anything that holds other people's funds needs an
  independent adversarial review before release.

## Checks that could not run

- Slither / Mythril are not installed on the build machine and were not run.
- No public-chain deployment, explorer verification or multisig handover was performed
  (source-only delivery).
