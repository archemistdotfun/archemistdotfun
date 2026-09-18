# Deployed Contracts

| Field | Value |
|---|---|
| Document | Deployed Contracts |
| Version | 1.0 |
| Date | 18 September 2026 |
| Status | Current |
| Classification | Public |

## 1. Arc mainnet (chain id 5042)

### 1.1 Archemist v4 launch system, deployment 7

Deployed 18 September 2026 at block 21,527,890. The five system contracts are UUPS proxies; the addresses in the "Proxy" column are permanent. The "Implementation" column identifies the code currently installed behind each proxy and changes only through the upgrade procedure in `UPGRADE_POLICY.md`.

| Contract | Proxy | Implementation |
|---|---|---|
| `TimelockController` | `0x3e7C3a40045ff4aA78d2ABcB8dd2EE72532855bD` | not upgradeable |
| `ArchemistPairRegistry` | `0x18b9D3BCCb6991523820C4Bcad1532aAF3EebE9a` | `0x742ff3E990CBf14e1d2109622053Cfa768Ee53C4` |
| `ArchemistV4Launcher` | `0xE4526293943683651707819d96CD9e003B75B4C2` | `0x1d96c4375f38A78187e2Bd7F4dfFa708551FC6e6` |
| `ArchemistV4Locker` | `0xa40e69885D0500E782AeA324BE86F06E716a4571` | `0x38c0754A4cb584C6d00bBe736705a3C93807C458` |
| `ArchemistBuybackVault` | `0xdc43A2c32eaA1DbF641022AF42D2466E805C1447` | `0x450aAf68262e3336A81EbD15F7C9C04703468Ab3` |
| `ArchemistHolderRewards` | `0x5b2EFa573F37660151F7F4F884B8036bd5fa83cb` | `0xF38b13b5a53548b667435F8ff4Aac9bC3a70E275` |
| `ArchemistV4Hook` | `0xF22D3F0200BFDC51f2CBa9D13a6B04163745A8Cc` | not upgradeable |

Timelock parameters: minimum delay 172,800 seconds (48 hours); proposer and canceller `0xE662fb8A5ca5549368D880B33a9B6ee2789887c9`; executor role open to any address; administrator role held by the timelock itself.

Ownership of the five proxies is transferred to the timelock by a two-step procedure. The `acceptOwnership` operations were scheduled in the deployment transaction and become executable 48 hours later. Until they execute, `owner()` on each proxy returns the deployer address and `pendingOwner()` returns the timelock.

Shared infrastructure referenced by the system:

| Contract | Address |
|---|---|
| Uniswap v4 `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Uniswap v3 `Factory` | `0xf0db7b58379503491d857dB50AC9ece64c653918` |
| Linked USDC (ERC-20 view of the native currency) | `0x3600000000000000000000000000000000000000` |
| ARCH token | `0x5042419b1F2498959787Bc23Be1F484Ed1306650` |
| ARCH/USDC Uniswap v3 pool (1% fee tier) | `0xC7CF0c94850c912A5045f2A0f2d70Ca18085b829` |
| Protocol treasury | `0x4C85e3847c549f4823cf9bBD5Dfc7E1724559AEf` |

### 1.2 Archemist v2 launch system, implementation version 3

Deployed 19 September 2026 at block 21,542,313. Both contracts are EIP-1967 UUPS proxies owned by the same timelock as the v4 system; the `acceptOwnership` operations were scheduled by the deployment and become executable 48 hours later.

| Contract | Proxy | Implementation |
|---|---|---|
| `ArchemistV2USDCFactoryV3` | `0x91Aca454C982459899eD46eED9668034Bd7EdF1F` | `0xe93750Affc58792C9a8c78dA84A48C8f0F49de02` |
| `ArchemistV2USDCLockerV3` | `0xD324578C2Caa01Bb454997DFcF531fCB435CE92d` | `0x5853989F172B21Df7fD7714c62dcc48e2DD1E3AE` |
| `TimelockController` | `0x3e7C3a40045ff4aA78d2ABcB8dd2EE72532855bD` | not upgradeable |

Parameters fixed at initialisation: paired token linked USDC `0x3600000000000000000000000000000000000000`; Uniswap v3 factory `0xf0db7b58379503491d857dB50AC9ece64c653918`; position manager `0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377`; `SwapRouter02` `0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77`; treasury `0x4C85e3847c549f4823cf9bBD5Dfc7E1724559AEf`; protocol fee 2,000 bps (creator 8,000 bps). The contracts are compiled without a metadata hash, so their bytecode is a pure function of the source in `contracts/v2/`.

### 1.3 Fee router

| Contract | Address |
|---|---|
| `ArchemistFeeRouterProxy` | see the Archemist application configuration |

## 2. Verification

Every contract above is verified on the Arc explorer (`https://explorer.arc.io`). The Uniswap v4 project compiles with `bytecode_hash = "none"` and `cbor_metadata = false`; a local build with the settings in `contracts/v4/foundry.toml` reproduces the deployed runtime bytecode exactly.

## 3. Superseded deployments

Earlier deployments of the launch system remain on chain and continue to operate for the tokens launched through them. They are not upgradeable and are not covered by the upgrade policy. Their addresses are recorded in the Archemist application configuration.
