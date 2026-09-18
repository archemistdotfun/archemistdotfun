// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistERC1967Proxy } from "../src/upgradeability/ArchemistERC1967Proxy.sol";

/// @notice One-line "deploy implementation, then deploy a proxy initialized in its own constructor" for
/// each system contract, so tests never construct a bare implementation by accident.
///
/// That accident is worth guarding against: an implementation deployed on its own has no state (its
/// `initialize` is locked by `_disableInitializers()`), so a test that used one directly would fail in
/// confusing ways or - worse - pass against behaviour the deployed system does not have, since
/// `address(this)`, every `msg.sender` check and all transient state are keyed by the proxy.
library ArchemistDeploy {
    function registry(address owner, address canonicalNativeAlias) internal returns (ArchemistPairRegistry deployed) {
        address impl = address(new ArchemistPairRegistry(canonicalNativeAlias, block.chainid));
        deployed = ArchemistPairRegistry(
            address(new ArchemistERC1967Proxy(impl, abi.encodeCall(ArchemistPairRegistry.initialize, (owner))))
        );
    }

    function launcher(
        IPoolManager poolManager,
        address owner,
        address pairRegistry,
        address treasury,
        uint256 deployFee
    ) internal returns (ArchemistV4Launcher deployed) {
        address impl = address(new ArchemistV4Launcher(poolManager, block.chainid));
        deployed = ArchemistV4Launcher(
            payable(address(
                    new ArchemistERC1967Proxy(
                        impl, abi.encodeCall(ArchemistV4Launcher.initialize, (owner, pairRegistry, treasury, deployFee))
                    )
                ))
        );
    }

    function locker(IPoolManager poolManager, address owner, address launcherProxy)
        internal
        returns (ArchemistV4Locker deployed)
    {
        address impl = address(new ArchemistV4Locker(poolManager, block.chainid));
        deployed = ArchemistV4Locker(
            payable(address(
                    new ArchemistERC1967Proxy(
                        impl, abi.encodeCall(ArchemistV4Locker.initialize, (owner, launcherProxy))
                    )
                ))
        );
    }

    function rewards(address owner, address launcherProxy, address lockerProxy)
        internal
        returns (ArchemistHolderRewards deployed)
    {
        address impl = address(new ArchemistHolderRewards(block.chainid));
        deployed = ArchemistHolderRewards(
            payable(address(
                    new ArchemistERC1967Proxy(
                        impl, abi.encodeCall(ArchemistHolderRewards.initialize, (owner, launcherProxy, lockerProxy))
                    )
                ))
        );
    }

    function vault(
        IPoolManager poolManager,
        address arch,
        address linkedUsdc,
        address uniswapV3Factory,
        address owner,
        address lockerProxy,
        address pairRegistry
    ) internal returns (ArchemistBuybackVault deployed) {
        address impl = address(
            new ArchemistBuybackVault(poolManager, arch, linkedUsdc, uniswapV3Factory, block.chainid)
        );
        deployed = ArchemistBuybackVault(
            payable(address(
                    new ArchemistERC1967Proxy(
                        impl, abi.encodeCall(ArchemistBuybackVault.initialize, (owner, lockerProxy, pairRegistry))
                    )
                ))
        );
    }
}
