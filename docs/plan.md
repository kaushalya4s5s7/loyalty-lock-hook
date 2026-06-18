# Loyalty Lock Hook — Implementation Plan

> **For Claude:** Implement with TDD. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Uniswap v4 hook that charges a time-decaying exit fee on liquidity withdrawal, so that mercenary LPs who churn quickly are penalized and long-term ("sticky") LPs are rewarded.

**Architecture:** A single `BaseHook` contract. `afterAddLiquidity` records a liquidity-weighted deposit timestamp per position. `afterRemoveLiquidity` reads the position age and computes a fee that decays linearly from `MAX_FEE_BPS` (at age 0) to `0` (at `VEST_DURATION`). Phase 1 only *computes and reports* the fee (event + view) so the math and time-tracking are fully unit-testable with no value movement. Phase 2 (future) enables `afterRemoveLiquidityReturnDelta` to actually take the fee as a hook delta and `donate()` it to remaining LPs.

**Tech Stack:** Solidity ^0.8.26, Foundry (forge), Uniswap v4-core, v4-periphery (`BaseHook`), forge-std.

---

## Uniqueness / Demand basis

Validated against the 556-submission UHI Hook Directory: `"exit fee"` = 0 hits, `"early withdraw"` = 0, `"withdrawal fee"` = 1 (unrelated Harberger auction). The 4 "mercenary"-mention hooks all use *reward* mechanisms; none implements an exit-side penalty. On-theme with the workshop goal of sustainable, IL-shielded LP returns.

---

## Design decisions

| Concern | Decision |
|---|---|
| Position key | `keccak256(poolId, sender, tickLower, tickUpper, salt)`. Note: v4 `sender` is the router/PositionManager. Acceptable for v1. |
| Multiple adds | Liquidity-weighted blended timestamp: `(L0*t0 + Ladd*now)/(L0+Ladd)`. |
| Decay curve | Linear. `feeBps(age) = MAX_FEE_BPS * (VEST - min(age,VEST)) / VEST`. |
| Fee base (v1) | Reported on the notional liquidity removed; no tokens moved in Phase 1. |
| Permissions | Phase 1: `afterAddLiquidity`, `afterRemoveLiquidity` only. |

---

## File structure

- `src/LoyaltyLockHook.sol` — the hook contract (Phase 1).
- `test/LoyaltyLockHook.t.sol` — Foundry tests using v4 test fixtures (`Deployers`).
- `foundry.toml` — solc 0.8.26, via-ir, remappings.
- `remappings.txt` — v4-core / v4-periphery paths.

---

## Task 1: Project config (solc + remappings)

- [ ] Set `foundry.toml` to `solc = "0.8.26"`, `evm_version = "cancun"`, `via_ir = true`, `ffi`/optimizer on.
- [ ] Write `remappings.txt` for `v4-core/`, `v4-periphery/`, `forge-std/`, `@openzeppelin/`, `permit2/`, `solmate/`.
- [ ] Run `forge build` on empty src to confirm deps resolve.

## Task 2: Pure decay math (TDD)

- [ ] Write failing test: `feeBps` at age 0 == MAX, at >= VEST == 0, at VEST/2 == MAX/2.
- [ ] Implement `_feeBps(uint256 age)` pure function.
- [ ] Run tests → pass.
- [ ] Commit.

## Task 3: Deposit-time tracking in `afterAddLiquidity` (TDD)

- [ ] Test: after an add, `depositInfo(key,...)` returns current timestamp and liquidity.
- [ ] Test: a second add blends timestamp by liquidity weight.
- [ ] Implement `afterAddLiquidity` + `_positionKey` + storage.
- [ ] Run → pass. Commit.

## Task 4: Fee assessment in `afterRemoveLiquidity` (TDD)

- [ ] Test: add, remove immediately → `LoyaltyFeeAssessed` event fee == MAX_FEE_BPS.
- [ ] Test: add, `warp(VEST)`, remove → fee == 0.
- [ ] Test: add, `warp(VEST/2)`, remove → fee ≈ MAX/2.
- [ ] Implement `afterRemoveLiquidity` (compute, emit, decrement tracked liquidity).
- [ ] Run → pass. Commit.

## Task 5: Wiring & end-to-end (TDD)

- [ ] Deploy hook to a mined address (`HookMiner`) with correct permission flags in test setup.
- [ ] Full lifecycle test through `modifyLiquidityRouter`.
- [ ] `forge test -vvv` all green. Commit.

## Phase 2 (implemented)

- [x] Enable `afterRemoveLiquidityReturnDelta` permission (flag `1 << 0`, encoded in hook address).
- [x] In `afterRemoveLiquidity`, compute `fee0`/`fee1` from the positive amounts of the `delta` owed to the LP.
- [x] `poolManager.donate(key, fee0, fee1)` to remaining in-range LPs, then return `+fee` as the hook delta so the hook nets to zero and the exiting LP receives `fee` less.
- [x] Guard with `StateLibrary.getLiquidity(poolId) > 0` so a sole LP can always exit (fee waived when there's no one to reward).
- [x] Tests: fee captured at age 0 (LP proceeds reduced by exactly the bps rate); no fee after vest; **stayer's withdrawal exceeds their deposit by exactly the donated mercenary fee**; weighted-timestamp blend yields half fee.

## Phase 3 (future ideas, out of scope)

- Carry the real LP owner in `hookData` instead of keying on the router `sender`.
- Configurable non-linear decay curves; per-pool fee config.
- Optional split: part of the fee to a protocol/public-goods sink.
