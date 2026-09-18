# Archemist Protocol

Archemist is a token launch protocol on Arc. A creator deploys a fixed-supply token whose entire supply is placed in a permanently locked, one-sided Uniswap liquidity position, so that the position itself acts as the price curve from the first block. Trading fees are split between the creator, the protocol treasury, an automatic ARCH buyback-and-burn, and the holders of the token.

This repository contains the complete on-chain source of the protocol, the test suites, the deployment tooling, and the formal documentation.

## Contents

| Path | Description |
|---|---|
| `contracts/v4/` | The current launch system, built on Uniswap v4 (Foundry project). |
| `contracts/v2/` | The original launch system, built on Uniswap v3, at implementation version 3. |
| `contracts/fee-router/` | The upgradeable swap router used by the Archemist application. |
| `docs/PROTOCOL_MECHANISM.md` | Protocol mechanism specification. |
| `docs/INTERNAL_AUDIT.md` | Internal security review report. |
| `docs/UPGRADE_POLICY.md` | Upgrade and governance policy. |
| `docs/HOOK_DISCLOSURE.md` | Disclosure document for the Uniswap v4 hook. |
| `docs/DEPLOYMENTS.md` | Deployed contract addresses. |

## Design summary

- **Locked liquidity.** The full token supply is deposited into a single one-sided liquidity position owned by a locker contract that has no function capable of removing it.
- **Quote-only fees.** The hook charges its fee exclusively in the quote currency, on every swap direction and mode, at a flat 1% for sells and a time-decaying anti-snipe rate for buys during the first two minutes after launch.
- **Automatic buyback-and-burn.** The buyback share of fees is swapped to ARCH through canonical Uniswap pools and sent to the dead address. No party can redirect it.
- **Holder rewards.** The holder share of sell fees accrues to token holders in proportion to their balance, with the accounting kept inside the token contract so that transfers never call another contract.
- **Immutable hook and token, upgradeable periphery.** The hook and every launch token are immutable and ownerless. The launcher, locker, buyback vault, holder-reward custodian and pair registry are UUPS proxies owned by a timelock with a 48-hour minimum delay.

## Building and testing

Requirements: Foundry (forge 1.x), Node.js 20 or later, solc 0.8.26 (installed by the tooling).

```sh
cd contracts/v4
make install          # pins Uniswap v4-core, v4-periphery and forge-std
forge build --sizes
forge test
```

```sh
cd contracts/v2
npm install
npm run compile       # compiles and runs the storage-layout gate
npm test
```

Tests that exercise a fork of Arc mainnet require `RPC_URL_MAINNET` in `contracts/v4/.env` and are run with `make test-fork-mainnet` and `make test-fork-mainnet-v2`. Without a fork URL they are reported as skipped.

## Compiler settings

All contracts are compiled with solc 0.8.26, optimizer enabled at 200 runs, via IR, EVM version Cancun. The Uniswap v4 project sets `bytecode_hash = "none"` and `cbor_metadata = false`, so its deployed bytecode contains no metadata hash and is a pure function of the source.

## License

The contracts in this repository are licensed under the GNU General Public License, version 2 or later. See `LICENSE`.

## Security

See `SECURITY.md` for the vulnerability disclosure process.
