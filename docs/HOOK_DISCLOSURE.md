# ArchemistV4Hook Disclosure

| Field | Value |
|---|---|
| Document | Hook Disclosure |
| Document ID | ARC-HOOK-001 |
| Version | 1.0 |
| Date | 19 September 2026 |
| Status | Final |
| Classification | Public |
| Chain | Arc (chain id 5042) |
| Hook address | `0xF22D3F0200BFDC51f2CBa9D13a6B04163745A8Cc` |
| Permission bits | `0x28CC` |
| Source | `contracts/v4/src/ArchemistV4Hook.sol` |

This document is written for reviewers of Uniswap routing integrations and hook registries. It states what the hook does, what can cause a swap to revert, what external calls it makes, and who can change anything.

## 1. Permissions

| Flag | Bit | Purpose |
|---|---|---|
| `beforeInitialize` | `0x2000` | Rejects any pool not initialised by the Archemist launcher. |
| `beforeAddLiquidity` | `0x0800` | Rejects third-party liquidity during the launch window only. |
| `beforeSwap` | `0x0080` | Charges the quote-side fee on exact-input buys and exact-output sells. |
| `afterSwap` | `0x0040` | Charges the fee on the other two modes; enforces the buy cap; triggers the buyback. |
| `beforeSwapReturnsDelta` | `0x0008` | The fee is taken as a return delta. |
| `afterSwapReturnsDelta` | `0x0004` | As above, for the modes settled in `afterSwap`. |

Pools bound to the hook use a Uniswap fee of zero; the hook's fee, denominated in the quote currency only, is the sole fee. Because both return-delta flags are set, the hook is not automatically allowlisted for routing and is submitted for review.

## 2. Registry properties

```json
{
  "dynamicFee": false,
  "upgradeable": false,
  "requiresCustomSwapData": false,
  "vanillaSwap": false,
  "swapAccess": "none"
}
```

The hook never calls `updateDynamicLPFee`; it has no proxy, owner or setter; it ignores `hookData` entirely; the fee is taken via return deltas; and there is no allowlist, pause or gate on who may swap.

## 3. Conditions under which a swap reverts

| Error | Condition | Relevance to routers |
|---|---|---|
| `ExactOutputBuyBlocked` | An exact-output buy during the launch window (at most 120 seconds after launch) | Only inside the window; exact-input buys are unaffected |
| `MaxBuyExceeded` | A buy whose token output exceeds the per-launch cap, during the window only | Only inside the window |
| `PartialFillNotAllowed` | A swap that a price limit stops before the specified amount is consumed, on a leg whose fee was charged in `beforeSwap` | Not reachable with the extreme price limits routers pass |
| `PoolNotConfigured` | A pool using this hook that the launcher did not create | Cannot exist; `beforeInitialize` prevents it |

`LiquidityLocked` rejects third-party liquidity additions during the window; it is not a swap path. There is no pause, no allowlist, no owner-settable fee, and no restriction on liquidity removal (the hook has no remove-liquidity callback).

On `PartialFillNotAllowed`: for an exact-input buy the fee is charged in `beforeSwap` on the specified amount, before the pool executes, and `afterSwap` can return a delta only on the unspecified currency. If a price limit then stops the swap early, the fee and the traded amount would disagree; the hook reverts rather than overcharge. Routers pass `MIN_SQRT_PRICE + 1` and `MAX_SQRT_PRICE - 1`, under which the condition cannot occur. An exact-input sell with a price limit succeeds.

## 4. Fee

- Sells pay a flat 1% of the quote amount. Not settable.
- Buys pay a rate that decays quadratically from a per-launch start value to the same 1% floor over a per-launch window, then 1% thereafter.
- Bounds enforced at configuration and unchangeable afterwards: 1% ≤ start fee ≤ 99%; 0 < window ≤ 120 seconds; 0 < buy cap ≤ 100% of supply.
- The 99% ceiling applies only to buys, only within the window, and decays continuously to 1% within it. It exists to make the first block of a launch unprofitable to snipe. It cannot be raised, extended or re-applied.
- The rate depends only on time and the pool's locked configuration; no balance, pool state or external value enters it.
- The creator's atomic launch purchase, executed inside the launch transaction, pays the flat rate and is exempt from the cap. It is identified by the launcher being the swap sender, which occurs only for that purchase.

Ordering note: on a sell, the holder-reward notification occurs before the router settles the seller's tokens into the pool, so the seller's balance still counts toward the eligible supply and the seller receives a pro-rata share of the reward its own sell funded. The effect is bounded by the seller's share of the float and cannot be amplified, because the fee scales with the sale.

## 5. External calls from within the callbacks

Two, both by design.

1. `locker.recordHookFee(...)`. After minting the fee to the locker as ERC-6909 claims, the hook reports the amount and direction. The locker verifies that its claim balance backs the amount before crediting anything.
2. `vault.execute{gas: budget}(asset)` in `afterSwap`, on fee-bearing buys, within a `try`/`catch`. This makes the ARCH buyback trading-triggered rather than dependent on an operator. The call receives the gas remaining above a reserved 150,000 that the swap needs to settle, capped at 1,500,000; below 100,000 the call is skipped. Any failure inside the vault is contained. Reentrancy is prevented by the vault's guard and by the `PoolManager` locking model. Three tests cover a reverting vault, a gas-consuming vault, and insufficient spare gas; in each case the trader's swap completes.

## 6. Administrative surface

Of the hook: none. It has no owner, no setter and no proxy. Per-pool configuration is written once by the launcher immediately before pool initialisation and cannot be written again.

Of the contracts that receive the fee: the launcher, locker, buyback vault, holder-reward custodian and pair registry are UUPS proxies owned by an OpenZeppelin `TimelockController` with a 48-hour minimum delay, an open executor role and itself as administrator. Every privileged action is an on-chain operation visible for at least 48 hours before it can execute. The proposer is currently a single externally owned account; the role can be moved to a multi-signature account without any upgrade. See `UPGRADE_POLICY.md`.

For a pool this means: the hook that prices trades and the token being traded are immutable; the contracts that receive the fee can change, on a 48-hour public delay.

## 7. Pool-key trust and isolation

- `beforeInitialize` requires the initialiser to be the launcher, so no third party can create a pool bound to this hook.
- All per-pool state is keyed by pool identifier; pools cannot read one another's configuration.
- Configuration validates the key: the hook address, a zero pool fee, the token and quote orientation, and that the token and quote differ.
- The hook holds no balances at any time.

## 8. Analysis and tests

- 335 Foundry tests including fuzz (1,000 runs) and invariant (256 runs by depth 128) suites, and 14 tests against a fork of Arc mainnet.
- Static analysis with Slither and Aderyn, triaged in `INTERNAL_AUDIT.md`.
- Internal security review: `INTERNAL_AUDIT.md`. Independent audit: not yet commissioned; the system falls in the medium tier of the Uniswap Foundation hook security framework.

## 9. Submission checklist

- Verify the hook, the five proxies, their implementations and one launch token on `explorer.arc.io`.
- Seed one pool on the linked USDC pair (`0x3600000000000000000000000000000000000000`) with liquidity and record its pool identifier.
- Submit the registry entry (`hooklist-entry.json`) and the routing-allowlist form with a link to this document.
