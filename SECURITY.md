# Security Policy

## Reporting a vulnerability

If you believe you have found a vulnerability in any contract in this repository, or in a deployed instance listed in `docs/DEPLOYMENTS.md`, please report it privately before any public disclosure.

Contact: security@archemist.fun / telegram: @calee_0x

Please include a description of the issue, the affected contract and function, the conditions required to trigger it, and, where possible, a proof of concept as a Foundry test. Reports are acknowledged within three business days.

Do not test against deployed contracts with real funds. A fork of Arc mainnet (`make test-fork-mainnet`) reproduces the live system in full.

## Scope

In scope: every contract under `contracts/`, and the deployed instances listed in `docs/DEPLOYMENTS.md`.

Out of scope: the Uniswap v3 and v4 core contracts, the Arc linked USDC contract and its precompiles, the OpenZeppelin `TimelockController`, and the Archemist web application and indexer.

## Disclosure

The maintainers will confirm the issue, prepare a fix, and coordinate a disclosure date with the reporter. Where a fix requires a contract upgrade, it is subject to the 48-hour timelock described in `docs/UPGRADE_POLICY.md`; the schedule transaction is visible on chain from the moment it is submitted.
