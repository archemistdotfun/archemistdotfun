# Archemist Protocol Internal Security Review

| Field | Value |
|---|---|
| Document | Internal Security Review Report |
| Document ID | ARC-AUD-001 |
| Version | 1.0 |
| Review period | 18 September 2026 |
| Report date | 19 September 2026 |
| Status | Final |
| Classification | Public |
| Reviewed by | Archemist engineering (internal review) |

### Revision history

| Version | Date | Description |
|---|---|---|
| 1.0 | 19 September 2026 | Initial public release. |

---

## 1. Executive summary

This report documents the internal security review of the Archemist protocol contracts published in this repository, performed before the deployment of the Uniswap v4 launch system (deployment 7) and the release of implementation version 3 of the Uniswap v3 launch system. The review was conducted in three rounds: an initial review of the restructured code base, a re-verification of every resolution, and a final acceptance round after the last set of changes.

The review identified 18 findings: 3 of high severity, 5 of medium severity, 7 of low severity and 3 informational. All high and medium findings are resolved. Of the low and informational findings, 6 are resolved and 4 are accepted with the rationale recorded in Section 6. No finding of critical severity was identified, and no finding concerned the hook's fee arithmetic, the launch token's transfer path, the locker's custody of liquidity or the fee-backing check between the hook and the locker.

At the close of the review the Uniswap v4 project passes 335 tests (unit, fuzz, invariant, scenario and proxy-behaviour) with 0 failures, plus 22 tests that execute against a fork of Arc mainnet; the v2 tooling passes its 13 storage-layout tests; the deployed runtime bytecode of every contract reproduces exactly from source.

This is an internal review. It is not a substitute for an independent third-party audit, which has not yet been commissioned (Section 9).

## 2. Scope

### 2.1 Contracts in scope

| File | Contract | Kind |
|---|---|---|
| `contracts/v4/src/ArchemistV4Launcher.sol` | `ArchemistV4Launcher` | UUPS implementation |
| `contracts/v4/src/ArchemistV4Locker.sol` | `ArchemistV4Locker` | UUPS implementation |
| `contracts/v4/src/ArchemistBuybackVault.sol` | `ArchemistBuybackVault` | UUPS implementation |
| `contracts/v4/src/ArchemistHolderRewards.sol` | `ArchemistHolderRewards` | UUPS implementation |
| `contracts/v4/src/ArchemistPairRegistry.sol` | `ArchemistPairRegistry` | UUPS implementation |
| `contracts/v4/src/ArchemistV4Hook.sol` | `ArchemistV4Hook` | Immutable |
| `contracts/v4/src/ArchemistV4Token.sol` | `ArchemistV4Token` | Immutable, per launch |
| `contracts/v4/src/ArchemistV4Types.sol`, `HookFeeMath.sol`, `InitialPriceMath.sol` | Libraries and types | |
| `contracts/v4/src/upgradeability/ArchemistUpgradeable.sol`, `ArchemistERC1967Proxy.sol` | Upgrade base and proxy | |
| `contracts/v4/script/DeployArcMainnet.s.sol`, `VerifyDeployment.s.sol`, `timelock.sh` | Deployment and operations | |
| `contracts/v2/src/ArchemistV2USDCFactoryV3.sol` | `ArchemistV2USDCFactoryV3`, `V3USDCLaunchTokenV3` | UUPS implementation, token |
| `contracts/v2/src/ArchemistV2USDCLockerV3.sol` | `ArchemistV2USDCLockerV3` | UUPS implementation |
| `contracts/v2/src/ArchemistProxy.sol` | `ArchemistProxy` | Proxy |

### 2.2 Out of scope

Uniswap v3 and v4 core and periphery contracts; OpenZeppelin Contracts 5.0.2; the Arc linked USDC contract and its precompiles; `ArchemistArchRedistributor` and `ArchemistVerificationPayments` (reviewed separately); the fee router; the Archemist web application, indexer and backend.

### 2.3 Reviewed revision

The code reviewed is the revision published in this repository at version 1.0 of this document. Deployed runtime bytecode for every in-scope contract was reproduced from this source with the compiler settings in `contracts/v4/foundry.toml` (solc 0.8.26, optimizer 200 runs, via IR, Cancun, no metadata hash).

## 3. Methodology

1. **Manual review.** Every in-scope file was read in full by two reviewers working independently, each producing a written findings list before the lists were reconciled. Particular attention was given to: the upgradeability base (initialiser protection, upgrade authorisation, storage namespaces, immutables in implementations, delegatecall context); the hook registry and the locker's fee-backing check; the hook's fee arithmetic in all four swap modes and its anti-snipe rules; the token's transfer path and reward arithmetic; the vault's routing, bounds and burn path; the timelock configuration and ownership handover; and the deployment scripts.
2. **Reproduction.** Every finding rated medium or higher was reproduced with a Foundry test before being reported, and every resolution was re-verified against the code and by re-running the reproduction where one existed.
3. **Automated testing.** The full Foundry suite (unit, fuzz at 1,000 runs, invariant at 256 runs by depth 128 with revert-on-failure, scenario and proxy-behaviour tests) was executed after every change. The mainnet fork suites were executed against Arc mainnet state.
4. **Static analysis.** Slither 0.11.6 and Aderyn 0.6.8 were run over `contracts/v4/src`; every detector category at medium severity or above was triaged individually (Section 8).
5. **On-chain rehearsal.** The deployment procedure, the timelock handover, a hook rotation, a launcher upgrade and a cancellation were exercised on Arc testnet before mainnet deployment, and the mainnet deployment was verified with `script/VerifyDeployment.s.sol`. The v2 implementation version 3 was deployed on Arc testnet with its handover executed, and a launch was performed through the timelock-owned proxies; the cross-kind upgrade refusal, the proxy's rejection of stray value and the absence of every removed function were confirmed on chain.

## 4. Severity classification

| Severity | Definition |
|---|---|
| Critical | Direct loss or freezing of user or protocol funds by an unprivileged party, or a privileged party acting outside the documented trust model, with no precondition. |
| High | Loss or freezing of funds under realistic preconditions; or a defect that prevents the system from being deployed or operated as specified. |
| Medium | A defect that can cause a bounded loss, an interruption of a function, or an unrecoverable state, typically requiring specific preconditions or privileged action. |
| Low | A defect with limited impact, or one that is mitigated by other controls, but that should be corrected. |
| Informational | An observation about design, documentation or code quality with no direct security impact. |

Status values: **Resolved** (the code was changed and the change was verified), **Accepted** (the behaviour is retained with a documented rationale), **Documented** (no code change; the behaviour is disclosed).

## 5. Summary of findings

| ID | Title | Severity | Status |
|---|---|---|---|
| ARC-01 | Mainnet deployment script reverted on a registry canonical-alias conflict | High | Resolved |
| ARC-02 | v2 implementation version 3 lacked executable test coverage | High | Resolved |
| ARC-03 | Storage-layout gate did not inspect namespaced struct members | High | Resolved |
| ARC-04 | Buyback drift checkpoint could disable execution indefinitely | Medium | Resolved |
| ARC-05 | Proxies accepted an implementation of a different contract kind | Medium | Resolved |
| ARC-06 | v2 proxy `receive` function allowed a stray balance to block creator purchases | Medium | Resolved |
| ARC-07 | Ownership handover to the timelock was not scheduled by the deployment | Medium | Resolved |
| ARC-08 | Tests referenced by the source did not exist | Medium | Resolved |
| ARC-09 | Vault upgrade check omitted the `PoolManager` immutable | Low | Resolved |
| ARC-10 | v2 factory storage-slot table was inaccurate | Low | Resolved |
| ARC-11 | Timelock command-line tool could not schedule a repeated operation; salt series collided | Low | Resolved |
| ARC-12 | Slippage floor computation overflowed at large square-root prices | Low | Resolved |
| ARC-13 | Fee recording depends on launcher storage on every swap | Low | Accepted |
| ARC-14 | Registry probe was impractical under timelock ownership | Low | Resolved |
| ARC-15 | Buyback of ARCH itself would have executed a same-pool round trip | Low | Resolved |
| ARC-16 | Seller receives a share of the holder reward funded by its own sell | Informational | Documented |
| ARC-17 | Timelock delay is changeable by a timelocked operation | Informational | Documented |
| ARC-18 | Miscellaneous observations | Informational | Resolved / Accepted |

## 6. Detailed findings

### ARC-01 Mainnet deployment script reverted on a registry canonical-alias conflict

**Severity:** High. **Status:** Resolved.

**Description.** `DeployArcMainnet.s.sol` constructed the pair registry with the linked USDC address as the canonical native alias and then registered both the native currency and linked USDC as quote pairs. `ArchemistPairRegistry._checkCanonicalConflict` rejects registering the alias when the native pair already exists, so the second registration reverted and the entire broadcast failed. The testnet script and the test fixture used a zero alias, so no automated test had exercised the mainnet argument.

**Impact.** The system could not be deployed as written. The natural manual correction, removing one of the two registrations, would have silently changed the set of quote currencies available at launch relative to what had been rehearsed.

**Resolution.** The script now passes a zero alias, matching the previous deployment, the testnet script and the fixture. `test/DeployArcMainnet.t.sol` executes the script's deployment body under the mainnet chain id with the infrastructure addresses etched, asserts that both pairs are registered and enabled, and asserts the full wiring and the two-step ownership handover. The script also refuses any timelock delay below 48 hours.

### ARC-02 v2 implementation version 3 lacked executable test coverage

**Severity:** High. **Status:** Resolved.

**Description.** The Uniswap v3 launch system had no Foundry tests, and the existing end-to-end tooling targeted the previous implementation. The move behind proxies, the constant fee split and the nonce-predicted factory link were therefore untested at the time of review.

**Resolution.** `contracts/v4/test/ArchemistV2UsdcV3.t.sol` compiles the live v2 sources through the vendored links and covers: a complete launch with the position minted into the locker and no tokens retained by the factory; refusal of a pre-existing pool; the fee split as a constant and as a paid-out result; the absence of any administrative selector on both proxies; the absence of any locker function that moves a position; cross-kind and in-kind upgrades; the two-step ownership handover; and both halves of ARC-06. `test/ArcMainnetForkV2.t.sol` additionally exercises the pair against the real Uniswap v3 periphery on a fork of Arc mainnet.

### ARC-03 Storage-layout gate did not inspect namespaced struct members

**Severity:** High. **Status:** Resolved.

**Description.** The upgrade gate asserted only that no upgradeable contract declared a plain state variable outside its ERC-7201 namespace. Because the compiler's `storageLayout` output omits structs reached only through assembly slot assignment, a field reordered, retyped, removed or inserted inside a namespace struct would have passed the gate. This is the class of defect the gate exists to prevent, and it would have manifested only after an upgrade reinterpreted live state.

**Resolution.** Canary contracts declare each namespace struct as an ordinary state variable so that the compiler emits its layout. A committed reference for every upgradeable contract records the struct's members and every reachable type; the gate requires the committed member list to be a prefix of the current one and every committed type to be unchanged, which also detects a field moved inside a nested struct. Self-tests demonstrate that the gate rejects a reorder against the real launcher layout, rejects a removal, rejects a plain variable and accepts an append. An equivalent gate for the v2 contracts runs on every compile.

### ARC-04 Buyback drift checkpoint could disable execution indefinitely

**Severity:** Medium. **Status:** Resolved.

**Description.** The vault refused to execute when the spot price had drifted more than 5% from its checkpoint, and the checkpoint was written only by a successful execution. A sustained price move therefore stopped every subsequent execution, and because the linked USDC to ARCH hop is shared, a stale checkpoint on that hop blocked buybacks for every asset. The function that previously cleared the checkpoint had been removed together with the owner-configurable routes. Two aggravating factors were noted: the first checkpoint for an asset is seeded from the spot price at the moment of the first execution, and a refused execution performed the locker claim and the first hop before reverting on the second, charging every triggering trader for a failed attempt.

**Resolution.** The tolerance now widens by 5 percentage points for every 6-hour period since the checkpoint was written, capped at 100% of the square-root price, so that an active vault is held to the tight band and a stalled one recovers without intervention. The exposure under a relaxed tolerance remains bounded by the 30% per-execution cap and the 6-hour cooldown. An owner-only `resetCheckpoint` was added; it moves no funds and, being subject to the timelock, cannot be timed to a manipulation. `execute` now validates both hops before it claims or swaps anything, so a refused execution costs two price reads. Eight tests cover the relaxation, the reset and the cost of a refused attempt.

### ARC-05 Proxies accepted an implementation of a different contract kind

**Severity:** Medium. **Status:** Resolved.

**Description.** Upgrade authorisation compared only the implementation's infrastructure immutables. Every UUPS implementation returns the same `proxiableUUID`, and all five system implementations are compiled against the same `PoolManager` and chain id, so upgrading the launcher proxy to the locker implementation was accepted; the reviewers reproduced this and observed the launcher proxy lose its interface. The v2 factory and locker accepted each other's implementation for the same reason. The upgrade is restricted to the timelock, but the check exists specifically to protect against an operator error of this shape.

**Resolution.** Every upgradeable contract declares a distinct `ARCHEMIST_KIND()` value derived from a literal, and upgrade authorisation requires the incoming implementation to report the same kind before any other check. Tests exercise the full grid of cross-kind upgrades among the five v4 contracts, confirm that each proxy still accepts a fresh implementation of its own kind, and cover both directions for the v2 pair.

### ARC-06 v2 proxy `receive` function allowed a stray balance to block creator purchases

**Severity:** Medium. **Status:** Resolved.

**Description.** `ArchemistProxy` declared its own `receive` function, so value sent with empty calldata was accepted by the proxy without reaching the implementation's sender check. The factory's creator-purchase routine then asserted that its paired-token and native balances were exactly zero after the swap. On Arc the native currency and linked USDC are one balance, so a transfer of one unit to the factory proxy by any party would have caused every launch with a creator purchase to revert, with no function able to remove the balance and no remedy short of a timelocked upgrade.

**Resolution.** `ArchemistProxy` no longer declares `receive`; empty-calldata value falls through to the implementation, whose rule applies. The post-swap assertion is now relative to balances snapshotted before the swap, requiring only that the amount brought in by the current call has left. Tests confirm that the proxy rejects stray value and that a stray balance no longer prevents a creator purchase, and the fork test repeats the latter against the real router.

### ARC-07 Ownership handover to the timelock was not scheduled by the deployment

**Severity:** Medium. **Status:** Resolved.

**Description.** The deployment ended with each proxy owned by the deployer and the timelock as pending owner. Completing the handover required five separately scheduled `acceptOwnership` operations that nothing enforced, and a helper script referenced in a comment did not exist. Until the handover, a single key could upgrade any proxy without delay.

**Resolution.** The deployment schedules the five `acceptOwnership` operations in the same broadcast, under a fixed salt so that the execute commands are reproducible, when the proposer is the deployer. The operations remain subject to the full delay and to cancellation, and the deployer retains the ability to redirect ownership before they mature. `script/VerifyDeployment.s.sol` performs read-only checks of the deployment and fails while any proxy is not yet owned by the timelock.

### ARC-08 Tests referenced by the source did not exist

**Severity:** Medium. **Status:** Resolved.

**Description.** Source comments cited a test measuring a two-hop buyback against the hook's gas allowance, and a test enumerating the locker's interface to prove the absence of any liquidity-withdrawal path. Neither test existed. Without the first, nothing established that the gas allowance was sufficient after the move behind proxies; without the second, a future mutating function could have been added to the locker unnoticed.

**Resolution.** Both tests now exist. The gas measurement drives a two-hop execution through the proxies and asserts it against the allowance; the interface enumeration requires every state-changing locker function to appear on an annotated allow-list and fails on any unlisted or stale entry.

### ARC-09 Vault upgrade check omitted the `PoolManager` immutable

**Severity:** Low. **Status:** Resolved.

**Description.** The vault's upgrade authorisation compared the ARCH, linked USDC, factory and chain id immutables but not the `PoolManager`, unlike the launcher and the locker.

**Resolution.** The comparison was added and is covered by a test.

### ARC-10 v2 factory storage-slot table was inaccurate

**Severity:** Low. **Status:** Resolved.

**Description.** The layout table in the factory's header listed two variables at the same slot, so every subsequent entry was off by one. The table served as the reference for future upgrades.

**Resolution.** The table was corrected against the compiler's output, and a generated, committed layout reference enforced on every compile now supersedes the table as the authoritative record.

### ARC-11 Timelock command-line tool could not schedule a repeated operation; salt series collided

**Severity:** Low. **Status:** Resolved.

**Description.** The tool derived the operation salt from the target and calldata alone. Because the timelock retains executed operations, an identical operation could never be scheduled a second time. The first correction introduced a numbered salt series whose index was encoded with a right-padding conversion, so indices 1 and 10, 2 and 20, and 3 and 30 produced identical salts.

**Resolution.** The series index is encoded with a left-padding conversion; 32 attempts produce 32 distinct salts. The base salt is unchanged.

### ARC-12 Slippage floor computation overflowed at large square-root prices

**Severity:** Low. **Status:** Resolved.

**Description.** The vault squared the square-root price before dividing, which overflows for square-root prices of 2^128 or more, a raw price of 2^64. A six-decimal quote paired against a very cheap eighteen-decimal counterpart can reach this range, in which case every execution for that asset would have reverted.

**Resolution.** The computation is applied in two halves of 2^96 and never squares the price. Tests execute both the single-hop and two-hop paths at a square-root price of 2^130.

### ARC-13 Fee recording depends on launcher storage on every swap

**Severity:** Low. **Status:** Accepted.

**Description.** The locker authorises a fee record by asking the launcher whether the calling hook is registered. A defective launcher upgrade that broke this query would cause every swap on every pool to revert until corrected.

**Rationale for acceptance.** Mirroring the hook set into the locker would introduce a second copy of the same state that could diverge from the first, a failure mode judged worse than the one it removes. The dependency is documented in the locker, and launcher upgrades are subject to the layout gate and the timelock.

### ARC-14 Registry probe was impractical under timelock ownership

**Severity:** Low. **Status:** Resolved.

**Description.** The registry's probe pulled its tokens from the caller. With the timelock as owner, listing a probed pair required the timelock to hold the quote currency and to have scheduled an approval, making the unprobed path the likely default.

**Resolution.** The probe spends a balance the registry already holds if one is available, so any party can pre-fund it with an ordinary transfer and listing remains a single operation; the pull path is retained as a fallback. The probe's observations continue to be derived from its outbound transfers.

### ARC-15 Buyback of ARCH itself would have executed a same-pool round trip

**Severity:** Low. **Status:** Resolved.

**Description.** Every asset other than linked USDC is routed through linked USDC to ARCH. Had ARCH been listed as a quote currency, both hops would have resolved to the same pool: the vault would have sold ARCH to buy back a smaller amount of ARCH, and the price read taken for the second hop before the first executed would have been stale. The condition was unreachable with the deployed pair set.

**Resolution.** When the asset is ARCH, the vault burns the epoch amount directly, under the same cooldown and cap, without any swap. Three tests cover the direct path.

### ARC-16 Seller receives a share of the holder reward funded by its own sell

**Severity:** Informational. **Status:** Documented.

**Description.** The hook notifies the reward custodian during the swap, before the router settles the seller's tokens into the pool, so the seller's balance is still counted in the eligible supply and the seller receives a pro-rata share of the reward its own sell funded. The effect is bounded by the seller's share of the float; acquiring a larger balance to capture more of one's own fee is strictly loss-making because the fee scales with the sale. The behaviour is disclosed in the mechanism specification and the hook disclosure.

### ARC-17 Timelock delay is changeable by a timelocked operation

**Severity:** Informational. **Status:** Documented.

**Description.** The OpenZeppelin `TimelockController` permits its own delay to be changed by an operation that it executes itself. The proposer can therefore schedule a reduction of the delay, which takes effect after the current delay elapses. This is a property of the component, bounded by the same visibility and cancellation as any other operation, and is stated in the upgrade policy.

### ARC-18 Miscellaneous observations

**Severity:** Informational. **Status:** Resolved unless stated.

- The mainnet deployment script defaulted the treasury address to the deployer when the environment variable was unset. The variable is now required.
- The deployment verification script read environment variables its usage text did not list. Corrected.
- A comment in the hook rotation script described a salt mechanism that did not exist. Corrected.
- A comment at the head of the vault's `execute` stated that its preliminary reads wrote nothing; the first route resolution for an asset does write its cache. Corrected.
- The push-payment gas allowance in the reward custodian applies only to native payouts; ERC-20 transfers receive full gas. Accepted: the recipient of an ERC-20 transfer does not execute code.
- The hook identifies the creator's atomic purchase by the launcher being the swap sender. Any future launcher implementation that adds a swap path would inherit this exemption. Accepted and recorded in the hook.
- The mainnet deployment is a sequence of approximately twenty transactions and is not atomic; the handover scheduling is the last step. Accepted; the verification script detects an incomplete run.

## 7. Test coverage

| Suite | Tests | Notes |
|---|---|---|
| Foundry, `contracts/v4` | 335 passed, 0 failed | 25 suites; fuzz 1,000 runs; invariants 256 runs by depth 128 with revert-on-failure |
| Mainnet fork, v4 system | 10 | Real `PoolManager`, ARCH token, ARCH/USDC pool and linked USDC on a fork of Arc mainnet |
| Mainnet fork, v2 system | 12 | Real Uniswap v3 factory, position manager and router: launch, creator purchase, twenty swaps with the fee split checked against real pool fees, role rotation, and an upgrade with an appended field |
| Storage-layout gate, v2 tooling | 13 passed | Node.js |

Coverage areas: launch procedure and parameter validation; hook fee exactness in all four swap modes; anti-snipe decay, buy cap and exact-output block; partial-fill rules; creator-purchase exemption; fee split conservation including multi-recipient rounding; ERC-6909 backing and claim solvency; holder-reward accounting against an independently derived model, including accumulator wrap-around and transfer-path absence of external calls; buyback routing, bounds, drift relaxation, direct ARCH burn and burn destination; hook registry validation and rotation; proxy initialisation, upgrade authorisation across kinds and immutables, state preservation across upgrades, reinitialisers, two-step ownership, timelock roles, delay, cancellation, open execution, proposer migration and a leaked-proposer drill; storage-layout gate correctness; deployment script execution and verification; v2 launch, fee split, removed selectors, upgrades and the ARC-06 conditions.

Known gaps, deferred and recorded: additional invariants covering multiple hooks and upgrades within one invariant run; direct tests of the real hook's `lockConfig` access control and key validation; a router-shaped fuzz of post-window swaps; recipient-administrator transfer tests; a vault-upgrade scenario preserving cached routes; a named test of the vault's inline Uniswap v4 swap branch. None concerns a defect in shipped behaviour.

## 8. Static analysis

Slither 0.11.6 and Aderyn 0.6.8 were run over `contracts/v4/src`. Every detector category at medium severity or above was reviewed and either resolved or accepted with a written rationale. Accepted categories and their justification in brief:

| Detector | Disposition |
|---|---|
| Arbitrary native send in `claim` | Accepted: the destination is chosen by the caller for the caller's own balance. |
| Reentrancy around `PoolManager.unlock` | Accepted: the callback is gated to the `PoolManager` and to the action the caller set up; the entry points are reentrancy-guarded. |
| Divide before multiply in fee splitting and tick alignment | Accepted: the first recipient absorbs the rounding remainder; conservation is proven by fuzz tests; tick alignment is the intended floor. |
| Strict equality on computed balances | Accepted: zero-checks on values the contract itself computed. |
| Reentrancy in registry probing | Mitigated by a reentrancy guard; the detector does not model custom guards. |
| Unused return values of `PoolManager` calls | Accepted: each duplicates state the caller already holds. |
| Centralisation of owner functions | Accepted: the owner is the timelock and every owner function is enumerated in the upgrade policy. |
| Unsafe ERC-20 operations | Accepted: low-level calls with explicit return checking are used deliberately to support non-standard quote tokens. |

One earlier static-analysis finding, the absence of any withdrawal path for an unrouted asset in the vault, was resolved during development and subsequently superseded by the removal of all owner withdrawal paths (see the mechanism specification, Section 10).

## 9. Residual risks and recommendations

1. **Independent audit.** An external audit has not yet been commissioned. Under the Uniswap Foundation's hook security framework the system falls in the medium tier, for which one full audit with static analysis is indicated and a bug bounty recommended.
2. **Single proposer key.** The timelock's proposer is a single externally owned account. The 48-hour delay and the ability to cancel are the controls against its compromise. Migration of the role to a multi-signature account requires no upgrade and is rehearsed by test.
3. **Upgradeable custody.** The locker and the vault hold funds and are upgradeable. An upgrade can do anything; the protection is that it is public for 48 hours before it can execute. Holders should monitor the timelock contract.
4. **Test gaps.** The deferred tests listed in Section 7 should be completed before the next implementation upgrade.

## 10. Disclaimer

This report reflects the reviewers' understanding of the code at the reviewed revision. It does not constitute a guarantee that the contracts are free of defects, and it does not cover components listed as out of scope, the correctness of third-party dependencies, or risks arising from the underlying blockchain.

## Appendix A. Reproduction

```sh
cd contracts/v4 && make install && forge build --sizes && forge test
cd contracts/v4 && make test-fork-mainnet && make test-fork-mainnet-v2   # requires RPC_URL_MAINNET
cd contracts/v2 && npm install && npm run compile && npm test
```
