# Archemist v2 launch system, implementation version 3

The original Archemist launch system, built on Uniswap v3. Implementation version 3 places the factory and the locker behind EIP-1967 UUPS proxies and removes every administrative function other than upgrade.

The contracts are single, self-contained files compiled with solc 0.8.26 through the scripts in this directory. They are also compiled and tested by the Foundry project in `../v4` through the links in `../v4/test/vendored/`.

## Commands

```sh
npm install
npm run compile              # compiles src/ and runs the storage-layout gate
npm test                     # tests of the storage-layout gate itself
NETWORK=arc-testnet npm run deploy
```

`npm run deploy` reads `deployments/<network>.json` for the Uniswap v3 infrastructure addresses, deploys both implementations and both proxies, verifies the cross-links, and offers ownership to the address in `TIMELOCK`. Environment variables are read from `.env` in this directory.
