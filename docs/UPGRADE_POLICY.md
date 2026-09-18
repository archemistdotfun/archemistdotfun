# Archemist Protocol Upgrade and Governance Policy

| Field | Value |
|---|---|
| Document | Upgrade and Governance Policy |
| Document ID | ARC-GOV-001 |
| Version | 1.0 |
| Date | 19 September 2026 |
| Status | In force |
| Classification | Public |

### Revision history

| Version | Date | Description |
|---|---|---|
| 1.0 | 19 September 2026 | Initial public release, effective from deployment 7. |

---

## 1. Purpose

This policy states which Archemist contracts can be changed, by whom, under what delay, and how such changes can be observed. It is binding on the protocol's operators and is published so that every user can verify it against the chain.

## 2. Summary

One key may propose changes to the Archemist system contracts. No proposed change can take effect for 48 hours. Every proposal is an on-chain event from the moment it is submitted. The Uniswap v4 hook, every launch token and the timelock itself cannot be changed by anyone.

## 3. Upgradeable and immutable components

| Contract | Upgradeable | Basis |
|---|---|---|
| `ArchemistV4Launcher` | Yes, UUPS proxy | Owned by the timelock |
| `ArchemistV4Locker` | Yes, UUPS proxy | Owned by the timelock |
| `ArchemistBuybackVault` | Yes, UUPS proxy | Owned by the timelock |
| `ArchemistHolderRewards` | Yes, UUPS proxy | Owned by the timelock |
| `ArchemistPairRegistry` | Yes, UUPS proxy | Owned by the timelock |
| `ArchemistV2USDCFactoryV3` | Yes, UUPS proxy | Owned by the timelock |
| `ArchemistV2USDCLockerV3` | Yes, UUPS proxy | Owned by the timelock |
| `ArchemistV4Hook` | No | A hook's permissions are encoded in its address and its identity is part of every pool key that uses it. New behaviour is deployed as a new hook and registered; existing pools remain on the hook they were launched with. |
| Launch tokens | No | No owner, no pause, no restriction, no external call in the transfer path. |
| `TimelockController` | No | The root of trust. |

## 4. Roles

Every upgradeable contract is owned by a single OpenZeppelin `TimelockController` with the following configuration.

| Role | Holder | Effect |
|---|---|---|
| Proposer and canceller | The Archemist deployer address (`0xE662fb8A5ca5549368D880B33a9B6ee2789887c9`) | May schedule and cancel operations |
| Executor | Any address | May execute an operation once its delay has elapsed |
| Administrator | The timelock itself | Roles and the delay can be changed only by a timelocked operation |
| Minimum delay | 172,800 seconds (48 hours) | Applies to every operation |

Every privileged action on the protocol is a timelock operation, because the timelock is the owner: implementation upgrades, hook registration and enablement, pair curation, enabling launches, retiring a launcher, and clearing a buyback price checkpoint.

## 5. Trust model

An upgradeable contract that holds funds is more powerful than any single administrative function, since an upgrade may change any behaviour. The protection is that every change is slow and public: an operation emits `CallScheduled` on the timelock with its target and calldata when it is proposed, cannot execute for at least 48 hours, and can be cancelled at any point in that window. The hook that prices every trade and the token a holder owns are outside this arrangement entirely.

If the proposer key were ever used without authorisation, an operation could be scheduled but could not execute for 48 hours, during which it is visible on chain and can be cancelled. Migration of the proposer role to a multi-signature account, when one is available on Arc, requires no upgrade (Section 8).

The `TimelockController` permits its own minimum delay to be changed by an operation it executes itself. Such a change is subject to the current delay and is visible for its duration like any other operation. Archemist undertakes not to reduce the delay below 48 hours.

## 6. Observing operations

The protocol does not operate an off-chain announcement channel. Operations are observed directly on chain:

- `CallScheduled(id, index, target, value, data, predecessor, delay)` on the timelock at the moment a change is proposed;
- `Cancelled(id)` if it is withdrawn;
- `CallExecuted(id, index, target, value, data)` when it takes effect;
- the transaction history of the proposer address, from which every proposal originates.

The timelock address for each deployment is listed in `DEPLOYMENTS.md`. The operation state for a known target and calldata can be read with `contracts/v4/script/timelock.sh status`.

## 7. Upgrade procedure

1. Implement the change. Storage in every upgradeable contract is ERC-7201 namespaced and append-only: fields are never reordered, retyped or removed, and no state is declared outside the namespace struct.
2. Run the full test suite, including the storage-layout gate (`forge test --match-path 'test/UpgradeLayout.t.sol'`). The gate compares each namespace struct and every type it reaches against a committed reference and permits only appended fields. If the change deliberately appends a field, regenerate the references with `make layout-references` and review the diff before proceeding. The v2 contracts are gated by `npm run compile`.
3. Deploy the new implementation. It is inert: its initialiser is locked at construction and it cannot be owned.
4. Schedule the upgrade through the timelock:
   ```sh
   export TIMELOCK=<timelock> RPC=<rpc-url> PRIVATE_KEY=<proposer-key>
   ./script/timelock.sh schedule <PROXY> "$(cast calldata 'upgradeToAndCall(address,bytes)' <NEW_IMPL> 0x)"
   ```
5. After 48 hours, any address may execute:
   ```sh
   ./script/timelock.sh execute <PROXY> "$(cast calldata 'upgradeToAndCall(address,bytes)' <NEW_IMPL> 0x)"
   ```
6. Verify the new implementation on the explorer and record the upgrade in Section 9.

The same tool drives every other privileged action, for example:

```sh
./script/timelock.sh schedule <LAUNCHER> "$(cast calldata 'registerHook(address)' <HOOK>)"
./script/timelock.sh schedule <LAUNCHER> "$(cast calldata 'setHookEnabled(address,bool)' <HOOK> false)"
./script/timelock.sh schedule <REGISTRY> "$(cast calldata 'setPairEnabled(address,bool)' <QUOTE> true)"
./script/timelock.sh schedule <VAULT>    "$(cast calldata 'resetCheckpoint(address)' <ASSET>)"
```

The tool derives a deterministic salt from the target and calldata, so `status`, `execute` and `cancel` re-derive the same operation identifier. Because the timelock retains executed operations, a repeated operation is scheduled under the next salt in a numbered series; the tool reports which salt it used.

On-chain checks performed by every upgrade, in order: the caller is the owner; the new implementation is a contract; it declares the same contract kind (`ARCHEMIST_KIND`) as the current one; its infrastructure immutables (`PoolManager`, chain id, and for the vault the ARCH, linked USDC and Uniswap v3 factory addresses) match the current ones. The kind check prevents one system contract's implementation from being installed behind another's proxy.

## 8. Migration of the proposer role

When a multi-signature account is available:

```
schedule grantRole(PROPOSER_ROLE,  <MULTISIG>)      wait 48h    execute
schedule grantRole(CANCELLER_ROLE, <MULTISIG>)      wait 48h    execute
from the multisig: schedule revokeRole(PROPOSER_ROLE, <DEPLOYER>)   wait 48h   execute
```

No upgrade and no redeployment is involved. The procedure is exercised by `test_proposerCanBeMigratedToMultisigWithoutUpgrade`.

## 9. Change log

One entry per executed operation that changes an implementation, a role or the delay. Append only.

| Date | Proxy | Previous implementation | New implementation | Schedule tx | Execute tx | Reason |
|---|---|---|---|---|---|---|
| | | | | | | No upgrade has been executed under this policy. |
