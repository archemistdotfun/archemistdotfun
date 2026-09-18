# Archemist fee router

The upgradeable router through which the Archemist application executes swaps and collects the application fee. `ArchemistFeeRouterProxy` is a minimal EIP-1967 UUPS proxy; `ArchemistFeeRouterV1`, `V2` and `V3` are the successive implementations. The storage layout is append-only across versions and is documented in the header of each implementation.

These sources are compiled and tested from the Foundry project in `../v4` through the links in `../v4/test/vendored/`.
