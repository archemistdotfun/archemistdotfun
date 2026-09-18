# Archemist v4 launch system

Foundry project for the Uniswap v4 based launch system. See `../../docs/PROTOCOL_MECHANISM.md` for the specification and `../../docs/UPGRADE_POLICY.md` for the governance procedure.

## Layout

| Directory | Contents |
|---|---|
| `src/` | Contracts. `upgradeability/` holds the shared UUPS base and the proxy. |
| `test/` | Foundry tests: unit, fuzz, invariant, scenario, proxy behaviour, storage-layout gate, mainnet fork. `vendored/` links to the v2 and fee-router sources so they are compiled and tested here. |
| `script/` | Deployment, verification and operations scripts. `timelock.sh` drives every privileged action. |
| `test/layout/reference/` | Committed storage layouts. The gate in `test/UpgradeLayout.t.sol` fails if any upgradeable contract's layout is not an append-only extension of its reference. |

## Commands

```sh
make install                 # dependencies at pinned commits
forge build --sizes
forge test
forge test --match-path 'test/UpgradeLayout.t.sol'   # storage-layout gate
make test-fork-mainnet       # requires RPC_URL_MAINNET in .env
make layout-references       # regenerate references after a deliberate storage change
```
