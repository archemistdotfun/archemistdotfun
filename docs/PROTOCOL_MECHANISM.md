# Archemist Protocol Mechanism Specification

| Field | Value |
|---|---|
| Document | Protocol Mechanism Specification |
| Document ID | ARC-SPEC-001 |
| Version | 1.0 |
| Date | 18 September 2026 |
| Status | Final |
| Classification | Public |
| Applies to | Archemist v4 launch system (deployment 7); Archemist v2 launch system (implementation version 3) |

### Revision history

| Version | Date | Description |
|---|---|---|
| 1.0 | 18 September 2026 | Initial public release. |

---

## 1. Introduction

### 1.1 Purpose

This document specifies the mechanisms of the Archemist protocol as implemented in the contracts published in this repository. It describes what each contract does, the rules it enforces, the formulas it applies, and the properties the system is designed to maintain. It is written so that a reader can verify each statement against the source.

### 1.2 Scope

The specification covers the Uniswap v4 based launch system (`contracts/v4/`), the Uniswap v3 based launch system at implementation version 3 (`contracts/v2/`), and the shared governance arrangement. The fee router (`contracts/fee-router/`) is described only to the extent that it interacts with the launch systems.

### 1.3 Conventions

Amounts denominated "in pips" are parts per million (1,000,000 pips = 100%). Amounts in "bps" are basis points (10,000 bps = 100%). "Quote currency" means the currency a launch token is paired against; on Arc this is normally the native currency or its linked ERC-20 representation. "Launch token" means a token deployed by one of the launchers. Unless stated otherwise, section references to source files are relative to `contracts/v4/src/`.

## 2. Definitions

| Term | Definition |
|---|---|
| Launcher | The contract that deploys launch tokens, initialises their pools and seeds their liquidity (`ArchemistV4Launcher`). |
| Locker | The contract that owns every launch's liquidity position and holds all fee balances until they are claimed (`ArchemistV4Locker`). |
| Hook | The Uniswap v4 hook bound to every launch pool, which charges the protocol fee and enforces the anti-snipe rules (`ArchemistV4Hook`). |
| Vault | The contract that converts the buyback share of fees into ARCH and burns it (`ArchemistBuybackVault`). |
| Custodian | The contract that holds the holder-reward share of fees and pays claims (`ArchemistHolderRewards`). |
| Registry | The curated list of quote currencies a launch may be priced in (`ArchemistPairRegistry`). |
| Timelock | The OpenZeppelin `TimelockController` that owns every upgradeable contract. |
| Pool key | The Uniswap v4 tuple `(currency0, currency1, fee, tickSpacing, hooks)` whose hash identifies a pool. |
| ERC-6909 claim | A Uniswap v4 claim token representing a balance held inside the `PoolManager`. |
| Eligible supply | The sum of launch-token balances held by addresses that are not excluded from holder rewards. |

## 3. System overview

### 3.1 Components

| Contract | Kind | Role |
|---|---|---|
| `ArchemistV4Launcher` | UUPS proxy | Token deployment, pool initialisation, liquidity seeding, hook registry, launch switch. |
| `ArchemistV4Locker` | UUPS proxy | Permanent custody of every liquidity position; fee accounting and claims. |
| `ArchemistV4Hook` | Immutable | Fee collection, anti-snipe window, buy cap, buyback trigger. |
| `ArchemistV4Token` | Immutable, one per launch | Fixed-supply ERC-20 with holder-reward accounting. |
| `ArchemistBuybackVault` | UUPS proxy | ARCH buyback and burn. |
| `ArchemistHolderRewards` | UUPS proxy | Custody and payment of holder rewards. |
| `ArchemistPairRegistry` | UUPS proxy | Quote-currency curation and per-pair parameters. |
| `TimelockController` | Immutable | Owner of all proxies; 48-hour minimum delay. |

### 3.2 Trust boundaries

Two classes of contract exist. The hook and the launch tokens are immutable and have no owner, no pause, no allowlist and no settable parameter. All other system contracts are upgradeable through the timelock. A holder's token and the hook that prices every trade in it therefore cannot be changed by anyone; the contracts that receive and distribute fees can be changed only through a public 48-hour procedure (Section 12).

### 3.3 Interaction diagram

```
creator -> Launcher.createToken
             |-- HolderRewards.register(token, quote)
             |-- new ArchemistV4Token (CREATE2)
             |-- Hook.lockConfig(key, token, quote, orientation, params)
             |-- PoolManager.initialize(key, sqrtPrice)
             |-- Locker.seedPosition(token, key, ticks, creatorShare, recipients)
             |-- optional creator buy (PoolManager.swap)
             '-- deploy fee -> treasury

trader  -> PoolManager.swap(key)
             |-- Hook.beforeSwap / afterSwap: fee minted as ERC-6909 to Locker
             |-- Locker.recordHookFee: split creator / ecosystem / treasury
             |     '-- (sell) HolderRewards.notify -> Token.notifyReward
             '-- (buy)  Hook -> Vault.execute (gas-bounded, failure ignored)

anyone  -> Vault.execute(asset): claim from Locker, swap to ARCH, burn
holder  -> HolderRewards.claim(token): Token.consumeReward, pay quote
creator -> Locker.claim(asset)
```

## 4. Launch token

`ArchemistV4Token` is an ERC-20 with 18 decimals and a fixed supply of 1,000,000,000 tokens minted in full to the launcher at construction. It has no owner, no minting, no burning, no pause and no transfer restriction. The token records the addresses of the launcher, the locker, the `PoolManager`, the custodian and itself as **excluded** from holder rewards at construction; this set cannot be modified.

The transfer function performs exactly the following: it rejects a zero recipient, rejects an amount above the sender's balance, settles the reward entitlement of the sender and the recipient at their pre-transfer balances (Section 9), moves the balances, and adjusts the eligible supply if the transfer crosses the excluded boundary. It makes no call to any other contract. The compiled contract contains no `CALL`, `STATICCALL` or `DELEGATECALL` instruction anywhere in its bytecode. The only conditions under which a transfer reverts are therefore insufficient balance and a zero recipient.

## 5. Launch procedure

A launch is a single transaction, `ArchemistV4Launcher.createToken(LaunchParams)`, with the following parameters.

| Parameter | Meaning | Constraint |
|---|---|---|
| `name`, `symbol` | Token metadata | Non-empty |
| `salt` | Creator-chosen value | Combined with the creator address and chain id before use |
| `quote` | Quote currency | Must be registered and enabled in the registry |
| `targetFdvQuoteRaw` | Desired fully diluted valuation, in the quote's smallest unit | Non-zero; resulting tick must lie within the pair's tick band |
| `hook` | The hook the pool is bound to | Must be registered and currently enabled (Section 7.1) |
| `hookParams` | Hook-specific configuration | Decoded and validated by the hook |
| `creatorShareBps` | Creator's share of fees | Within the pair's creator-share band (Section 8.1) |
| `recipients` | One to four creator fee recipients with their shares | Shares sum to 10,000 bps; payout addresses strictly increasing |
| `creatorBuyAmount`, `creatorBuyMinTokensOut` | Optional atomic first purchase | Zero disables it |

The procedure is:

1. The launcher requires that launches are enabled and that `hook` is enabled in its registry.
2. The token address is computed with CREATE2 from `keccak256(creator, chainId, salt)` and the token's creation code. A launch reverts if code already exists at that address.
3. The token is pre-registered with the custodian, then deployed. The deployed address must equal the computed address.
4. The initial tick is derived from `targetFdvQuoteRaw` (Section 6). The pool key is formed with `fee = 0`, the pair's tick spacing, and the chosen hook. A launch reverts if a pool with this key is already initialised.
5. The hook's `lockConfig` is called with the pool key, the token, the quote, the orientation and `hookParams`. The hook validates and stores its per-pool configuration; it can never be written again for that pool.
6. The pool is initialised at the derived price. The hook's `beforeInitialize` callback rejects any initialiser other than the launcher.
7. The entire supply is transferred to the locker, which mints a single one-sided liquidity position covering the range from the initial tick to the far end of the price range on the token's side. At most 10^12 base units (0.000001 tokens) may remain unplaced.
8. If a creator buy was requested, the launcher executes it against the new pool inside the same transaction. This purchase pays the flat base fee and is exempt from the anti-snipe rate and the buy cap, since no external party can trade before it.
9. The deployment fee, if non-zero, is forwarded to the treasury.

Because steps 3 to 8 are atomic, no observer can trade against the pool before the creator's own optional purchase, and no partially initialised launch can exist.

## 6. Initial price and liquidity

The initial price is expressed by the creator as a target fully diluted valuation `F` in the quote currency's smallest unit. With supply `S` (in the token's smallest unit), the intended price of one token unit in quote units is `F / S`. The launcher converts this to a Uniswap square-root price:

- if the token is `currency0`: `sqrtPriceX96 = sqrt(F) * 2^96 / sqrt(S)`
- if the token is `currency1`: `sqrtPriceX96 = sqrt(S) * 2^96 / sqrt(F)`

The square roots are taken before multiplication so that no intermediate value can overflow at extreme ratios. The resulting tick is rounded to a multiple of the pair's tick spacing in the direction that never lets the realised price exceed the requested valuation, and must lie within `[minTick, maxTick]` of the pair.

The liquidity position is one-sided: it holds only launch tokens at initialisation and spans from the initial tick to the maximum usable tick (if the token is `currency0`) or from the minimum usable tick to the initial tick (if the token is `currency1`). The pool's current price sits exactly on the position's inner boundary, so the first buy immediately begins consuming the position. The position behaves as a continuous price curve in which every buy raises the price and every sell lowers it, without a separate bonding phase or graduation event.

The position is minted directly by the locker under a fixed salt, and the locker exposes no function that decreases its liquidity or transfers it.

## 7. Hook

### 7.1 Hook registry

The launcher maintains a registry of hook contracts. A hook may be **registered** (added, permanently) and **enabled** or **disabled** (affecting new launches only). Registration requires that the hook reports this launcher, this locker and this `PoolManager` as its wiring, and that the low 14 bits of its address equal the permission set it declares, as Uniswap v4 requires. Registration is append-only: because a pool's hook is part of its key and can never change, the locker must continue to accept fee records from every hook that any live pool is bound to. Disabling a hook prevents new launches from selecting it and has no effect on existing pools.

Every launch must name a registered, enabled hook. The launcher does not permit hookless pools.

### 7.2 Permissions

`ArchemistV4Hook` declares the permissions `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`, encoded in the address suffix `0x28CC`. Pools bound to it use a Uniswap fee of zero; the hook's fee is the only fee.

### 7.3 Per-pool configuration

At `lockConfig`, the hook records for the pool: the token, the quote, the orientation, the base fee, the start fee, the launch timestamp, the window end and the buy cap. The parameters carried in `hookParams` are:

| Parameter | Bound |
|---|---|
| `startHookFee` (pips) | 10,000 (1%) ≤ value ≤ 990,000 (99%) |
| `windowSeconds` | 1 ≤ value ≤ 120 |
| `maxBuyBps` | 1 ≤ value ≤ 10,000 |

The hook also requires that the pool key names the hook itself, that the pool fee is zero, that the token and quote occupy the declared sides of the key, and that the token and quote differ. Configuration is written once; a second attempt for the same pool reverts.

### 7.4 Fee rate

Let `t` be the current time, `t0` the launch time, `T = t0 + windowSeconds` the window end, `f_base = 1%` and `f_start` the configured start fee. The fee rate applied to a swap is:

- for a sell, or for the creator's atomic launch purchase: `f_base`;
- for a buy at `t ≥ T`: `f_base`;
- for a buy at `t < T`: `f(t) = f_base + (f_start − f_base) · ((T − t) / (T − t0))^2`.

The buy rate decays quadratically from `f_start` at launch to `f_base` at the window end and is continuous at `T`. It depends only on time and the locked configuration; no pool state, balance or external value enters the computation.

### 7.5 Fee collection

The fee is always taken in the quote currency, on all four swap modes. Let `p` be the fee rate in pips and `D = 1,000,000`.

| Mode | Where charged | Known quantity | Fee |
|---|---|---|---|
| Exact-input buy | `beforeSwap` | Gross quote input `G` | `G · p / D` (taken from the input) |
| Exact-output sell | `beforeSwap` | Net quote output `N` requested | `N · p / (D − p)` (added on top) |
| Exact-input sell | `afterSwap` | Gross quote output `G` from the pool | `G · p / D` (taken from the output) |
| Exact-output buy | `afterSwap` | Net quote input `N` charged by the pool | `N · p / (D − p)` (added on top) |

In every mode the fee equals `p` of the gross quote amount the trader pays or receives. The hook mints the fee as an ERC-6909 claim to the locker and reports the amount and direction to the locker in the same call.

### 7.6 Anti-snipe rules during the window

For `t < T`:

- an exact-output buy reverts (`ExactOutputBuyBlocked`), so that the buy cap cannot be circumvented by specifying output;
- a buy whose token output exceeds `INITIAL_SUPPLY · maxBuyBps / 10,000` reverts (`MaxBuyExceeded`);
- any liquidity addition by an address other than the locker reverts (`LiquidityLocked`), so that no third party can capture the elevated fee by placing competing liquidity.

The creator's atomic launch purchase is exempt from the first two rules. After `T`, buys of either mode and liquidity additions by anyone are permitted; the hook never restricts liquidity removal and has no remove-liquidity callback.

### 7.7 Partial fills

For the two modes charged in `beforeSwap`, the fee is computed on the specified amount before the pool executes. If a caller supplies a price limit that stops the swap before the specified amount is consumed, the fee and the traded amount would disagree. The hook reverts such swaps (`PartialFillNotAllowed`) instead of overcharging. For an exact-output buy the hook likewise requires the full requested output. Routers pass the extreme price limits, under which this condition cannot occur.

### 7.8 Buyback trigger

After every fee-bearing buy, the hook calls `ArchemistBuybackVault.execute(quote)` with an explicit gas allowance and ignores the result. The allowance is the gas remaining above a reserved amount of 150,000 that the swap needs to settle, capped at 1,500,000; if less than 100,000 is available the call is skipped. Any failure inside the vault, including cooldown, missing route, price drift and out-of-gas, is contained within the call and does not affect the trader's swap. The vault is reentrancy-guarded, and the `PoolManager`'s locking model prevents a nested swap on the same pool.

## 8. Fee distribution

### 8.1 Split

The locker splits every fee it records into three parts:

| Part | Share | Recipient |
|---|---|---|
| Creator | `creatorShareBps` (50% to 80%, fixed per launch within the pair's band) | The launch's fee recipients, pro rata to their configured shares |
| Ecosystem | 12.5% | Buyback vault (fee from a buy) or holder-reward custodian (fee from a sell) |
| Treasury | remainder (7.5% to 37.5%) | Protocol treasury |

The ecosystem share is the same size in both directions; only its destination depends on the direction of the swap that produced the fee. Rounding remainders in the creator share are assigned to the first recipient, and the treasury receives whatever is left after the creator and ecosystem amounts, so the three parts always sum exactly to the fee.

If the custodian reports that a sell's holder share cannot be distributed (the eligible supply is zero because no tokens have left the pool), that share is credited to the treasury instead.

### 8.2 Custody and claims

Fee balances are held by the locker as claimable amounts per beneficiary and asset. Hook fees are backed by ERC-6909 claims inside the `PoolManager`; the locker verifies before crediting that its claim balance covers all outstanding claim-backed liabilities plus the new amount, so a hook cannot credit a fee it did not mint. A beneficiary withdraws with `claim(asset, to)`, which redeems the ERC-6909 backing and transfers the asset.

The locker also collects the liquidity position's own Uniswap fees and donations with the permissionless `collect(poolId)`; these are split under the buy rule, since they carry no direction.

### 8.3 Creator recipients

Each launch names one to four recipients, each with an administrator address, a payout address and a share. The administrator may change the payout address and may transfer the administrator role by a two-step procedure. Changing the payout address does not move amounts already credited.

## 9. Holder rewards

### 9.1 Accounting

Each launch token maintains a reward accumulator `R`, a Q128 fixed-point running total of reward per unit of eligible supply, and per-holder state `(paid, owed)`. When the custodian notifies a reward of `A` quote units and the eligible supply is `E > 0`:

`R ← R + A · 2^128 / E`

A holder with balance `b` and last-settled accumulator `paid` has a pending entitlement of `b · (R − paid) / 2^128`. Settlement adds this to `owed` and sets `paid ← R`. Settlement occurs for both parties of every transfer at their pre-transfer balances, so a holder is credited exactly for the intervals during which they held the balance and there is no snapshot moment to trade around.

The accumulator is updated with wrapping arithmetic; because every entitlement is computed from the difference `R − paid`, wrap-around is harmless in the same way as Uniswap's fee-growth accumulators. The product `b · (R − paid)` is bounded below 2^346 and the quotient below 2^218, so the settlement computation cannot overflow. Notifications with zero supply, zero amount or an amount of 2^128 or more are declined rather than reverted, since the call occurs inside a third party's swap.

### 9.2 Eligible supply

Eligible supply excludes the `PoolManager`, the locker, the launcher, the custodian and the token contract itself. Excluding the `PoolManager` is essential: it holds nearly the whole supply as pool liquidity, and dividing by total supply would direct almost every distribution to an address that can never claim. Shares are consequently relative to the circulating float.

### 9.3 Claims

The custodian pulls its accrued balance from the locker when needed and pays claims in the pool's quote currency. `claim(token, to)` pays the caller's own entitlement. `claimFor(token, holders[])` is permissionless and pays each listed holder to their own address; a recipient that cannot receive is skipped with its entitlement restored, so one recipient cannot block the others. Excluded addresses have no entitlement.

### 9.4 Ordering note

The hook notifies the custodian during the swap, before the router settles the seller's tokens into the pool. The seller's balance is therefore still counted in the eligible supply at that moment, and the seller receives a pro-rata share of the holder reward that their own sell funded. The effect is bounded by the seller's share of the float and cannot be amplified, because a larger sell pays a proportionally larger fee.

## 10. Buyback and burn

### 10.1 Routes

The vault converts the buyback share of fees into ARCH and sends it to `0x000000000000000000000000000000000000dEaD`. ARCH has no burn function and rejects transfers to the zero address, so tokens at the dead address are unspendable while `totalSupply` is unchanged.

Every asset other than linked USDC is routed in two hops, `asset → linked USDC → ARCH`; linked USDC is routed in one hop. The native currency is treated as linked USDC, because on Arc the two are one balance viewed at two decimal scales. ARCH itself, should it ever be listed as a quote, is burned directly without a swap.

A route is read from the pair registry and cached permanently on first use. A Uniswap v3 route is accepted only if the canonical v3 factory returns that exact pool for the asset, its fixed counterpart and the pool's fee tier. A Uniswap v4 route carries no address: the vault constructs the pool key itself from the asset, the counterpart, the registered fee and tick spacing, and `hooks = address(0)`, and requires that the pool is initialised. No party can direct a buyback into a pool of their choosing, and the vault has no withdrawal function.

### 10.2 Execution bounds

`execute(asset)` is permissionless and subject to:

| Bound | Value |
|---|---|
| Cooldown per asset | 6 hours |
| Maximum fraction of the asset balance swapped per execution | 30% |
| Slippage floor relative to spot | 2% |
| Drift tolerance, fresh checkpoint | 5% of the checkpoint's square-root price |
| Drift tolerance relaxation | +5% per 6 hours since the checkpoint was written, capped at 100% |
| Checkpoint update on success | Exponential moving average, 20% weight on the new observation |

Before any claim or swap, the vault reads the spot price of every hop and requires each to lie within the current tolerance of that hop's checkpoint. A refused execution therefore costs only the price reads. On success the vault claims its accrued balance from the locker, swaps at most 30% of it, burns the ARCH received, records the execution time and updates the checkpoints. The relaxation ensures that an ordinary sustained price move cannot disable buybacks indefinitely; the owner may additionally clear a checkpoint through the timelock, which moves no funds.

## 11. Pair registry

The registry lists the quote currencies a launch may use, with per-pair parameters: decimals, tick spacing, the permitted initial-tick band, the buyback route, and the band within which a launch may choose its creator share (globally bounded to 50% to 80%). A pair may be added, updated or disabled by the owner; these actions affect future launches only. Existing pools are unaffected because their key and hook are fixed, and a buyback route already cached by the vault is not changed by a later registry update.

When a pair is added with probing enabled, the registry transfers a small amount of the quote currency to the locker, the treasury, the vault and the custodian and records what it observes: transfer restrictions, fee-on-transfer behaviour, a pause function and non-standard return values. A pair observed to be transfer-restricted or fee-on-transfer is stored disabled. The probe amount is taken from the registry's own balance if it holds one, otherwise pulled from the caller.

## 12. Governance and upgradeability

### 12.1 Ownership

The launcher, locker, vault, custodian and registry are UUPS proxies (EIP-1967) whose owner is a single `TimelockController` with a 48-hour minimum delay. The timelock's proposer and canceller is the Archemist deployer address; the executor role is open, so any address may execute an operation once its delay has elapsed; the administrator role is held by the timelock itself, so the roles and the delay can be changed only through a timelocked operation.

Every privileged action is a timelock operation: upgrades, hook registration and enablement, pair curation, enabling launches, retiring a launcher, and clearing a buyback checkpoint. Each operation is visible on chain as a `CallScheduled` event on the timelock from the moment it is proposed, and can be inspected by reading the timelock contract or the deployer address's transactions. The protocol does not operate a separate announcement channel.

### 12.2 Upgrade safety

An upgrade is accepted only if the new implementation is a contract, declares the same contract kind (`ARCHEMIST_KIND`) as the proxy's current implementation, and was compiled with the same infrastructure immutables (`PoolManager`, chain id, and for the vault the ARCH, linked USDC and Uniswap v3 factory addresses). Storage is ERC-7201 namespaced, and a test gate compares every namespace struct against a committed reference and permits only appended fields. Implementations lock their own initialiser at construction, and each proxy is initialised in its constructor, so no uninitialised implementation or proxy can exist.

### 12.3 Immutable components

The hook, every launch token and the timelock are not upgradeable and have no owner. New hook behaviour is deployed as a new hook contract and registered; pools launched on an earlier hook continue to operate on it indefinitely.

### 12.4 Launch switch

Launches are enabled once by `enableCreate`, which requires the system to be fully wired and at least one hook to be registered. `retire` permanently disables new launches on a launcher and has no other effect: every existing pool continues to trade, accrue and pay out. There is no function that re-enables launches after retirement.

## 13. Archemist v2 launch system (Uniswap v3)

The original launch system places the full supply of a launch token into a one-sided Uniswap v3 position in the 1% fee tier, with the initial price at the position boundary, so that the position acts as the price curve in the same way as Section 6. Its parameters are fixed in code:

| Parameter | Value |
|---|---|
| Supply | 1,000,000,000 tokens, 18 decimals |
| Quote | Linked USDC (6 decimals) |
| Fee tier / tick spacing | 1% / 200 |
| Starting tick (token as token0) | −398,400 |
| Deployment fee | 0.1 in native units, forwarded to the treasury |
| Maximum unplaced dust | 10^12 base units |
| Fee split | Creator 80%, treasury 20%, fixed in code |

The factory deploys the token with CREATE2 under a creator-namespaced salt, refuses to reuse a pool that already exists at the expected address, creates and initialises the pool, mints the position directly into the locker and verifies the minted position's parameters, and optionally executes a creator purchase through the Uniswap `SwapRouter02` in the same transaction. The locker collects the position's fees on request, credits the creator's share as claimable, and pushes the treasury's share directly, falling back to a claimable credit if the push fails.

Implementation version 3 places both contracts behind EIP-1967 UUPS proxies. The only privileged function on either contract is upgrade; the fee split is a constant, no function transfers a position out of the locker, and there is no launch switch, so launches are accepted from the moment the pair is deployed. The locker's link to the factory is set once at initialisation to the factory proxy's address, predicted from the deployer's nonce, and the factory's own initialisation refuses to complete unless the locker reports that exact address. Both proxies are owned by the same timelock as the v4 system. The proxy contract has no `receive` function, so value sent with empty calldata is handled by the implementation's own rules.

## 14. Fee router

The Archemist application submits swaps through `ArchemistFeeRouterProxy`, an EIP-1967 UUPS proxy whose implementation collects the application fee and forwards the swap to the configured venue. It is independent of the launch systems: a launch pool can be traded through any Uniswap-compatible router.

## 15. Parameter summary

| Parameter | Value | Location |
|---|---|---|
| `INITIAL_SUPPLY` | 1,000,000,000 × 10^18 | `ArchemistV4Types.sol` |
| `BASE_HOOK_FEE` | 10,000 pips (1%) | `ArchemistV4Types.sol` |
| `MAX_START_HOOK_FEE` | 990,000 pips (99%) | `ArchemistV4Types.sol` |
| `MAX_WINDOW_SECONDS` | 120 | `ArchemistV4Types.sol` |
| `BUYBACK_GAS_STIPEND` / `SWAP_TAIL_RESERVE` / `BUYBACK_MIN_GAS` | 1,500,000 / 150,000 / 100,000 | `ArchemistV4Types.sol` |
| Creator share band (global) | 5,000 to 8,000 bps | `ArchemistPairRegistry.sol`, `ArchemistV4Locker.sol` |
| Ecosystem share | 1,250 bps | `ArchemistV4Locker.sol` |
| Maximum creator recipients | 4 | `ArchemistV4Locker.sol` |
| `MAX_TOKEN_DUST` | 10^12 | `ArchemistV4Locker.sol` |
| `COOLDOWN_SECONDS` | 6 hours | `ArchemistBuybackVault.sol` |
| `MAX_EPOCH_BPS` | 3,000 | `ArchemistBuybackVault.sol` |
| `SWAP_SLIPPAGE_BPS` | 200 | `ArchemistBuybackVault.sol` |
| `MAX_SQRT_PRICE_DRIFT_BPS` / relaxation / cap | 500 / 500 per period / 10,000 | `ArchemistBuybackVault.sol` |
| `CHECKPOINT_ALPHA_BPS` | 2,000 | `ArchemistBuybackVault.sol` |
| Quote decimals accepted | 6 to 18 | `ArchemistPairRegistry.sol` |
| Timelock minimum delay | 172,800 seconds | Deployment |
| Hook permission bits | `0x28CC` | `ArchemistV4Hook.sol` |

## 16. Invariants

The following properties are maintained by construction and are exercised by the test suites.

1. For every pool, the sum of amounts credited to the creator recipients, the ecosystem destination and the treasury equals the fee recorded.
2. For every asset, the locker's ERC-6909 claim balance is at least its outstanding claim-backed liability, and its real balance plus claim balance is at least its total liability.
3. The liquidity of a locked position never decreases, and no function of the locker transfers a position.
4. For every launch token, the eligible supply equals the total supply minus the balances of the excluded addresses.
5. The reward accumulator of a token never decreases (modulo wrap), and the sum of holder entitlements never exceeds the amount notified.
6. ARCH leaves the vault only to the dead address.
7. The set of registered hooks never shrinks, and a pool's hook is the one it was launched with.
8. A launch either completes in full or leaves no token, no pool, no position and no registration behind.

## 17. Known limitations

- A contract that holds a launch token but cannot call `claim` accrues holder rewards it may never collect. This is inherent to balance-proportional distribution.
- A quote currency that later becomes paused or that blocks one of the system addresses stops trading and claims in that currency; balances already credited remain recorded.
- The first buyback checkpoint for an asset is seeded from the spot price at that moment. The bounds in Section 10.2 limit the amount that can be swapped under any single price observation.
- The timelock's own delay can be changed by a timelocked operation. This is a property of the OpenZeppelin `TimelockController`; the change is itself subject to the current delay and is visible on chain for its duration.

## 18. References

1. Uniswap v4 Core, `PoolManager`, `Hooks` library and `BeforeSwapDelta` semantics.
2. Uniswap v3 Core and Periphery, `NonfungiblePositionManager` and `SwapRouter02`.
3. EIP-1967, Standard Proxy Storage Slots.
4. ERC-7201, Namespaced Storage Layout.
5. ERC-6909, Minimal Multi-Token Interface.
6. OpenZeppelin Contracts 5.0, `UUPSUpgradeable`, `Initializable`, `TimelockController`.
