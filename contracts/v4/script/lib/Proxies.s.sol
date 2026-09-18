// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { ArchemistERC1967Proxy } from "../../src/upgradeability/ArchemistERC1967Proxy.sol";

/// @notice Deploy helpers shared by every Archemist V4 script: "implementation, then proxy initialized
/// in its own constructor", and the timelock the proxies are ultimately owned by.
library Proxies {
    /// @dev The initializer runs inside the proxy's constructor, so there is no block in which the proxy
    /// exists uninitialized and a front-runner could call `initialize` and take ownership of it. That is
    /// the single most important property of this helper; never deploy a proxy with empty `initData` and
    /// initialize it in a second transaction.
    function deploy(address implementation, bytes memory initData) internal returns (address proxy) {
        proxy = address(new ArchemistERC1967Proxy(implementation, initData));
    }

    /// @notice The root of trust for the whole system: every proxy's owner, and therefore the only
    /// address that can upgrade anything or curate hooks and pairs.
    /// @param proposers Who may schedule an operation. On Arc today this is the deployer EOA alone
    ///        (there is no multisig on Arc yet); the 48-hour delay is what stands between
    ///        that one key and any change, and the role can be handed to a multisig later by a scheduled
    ///        `grantRole`/`revokeRole` with no upgrade and no redeploy.
    /// @dev Three details of this construction are load-bearing:
    ///   - `executors = [address(0)]` means ANYONE may execute an operation once its delay has elapsed.
    ///     Nobody can be locked out of executing a change that is already public.
    ///   - `admin = address(0)` makes the timelock its own administrator. There is no external key that
    ///     can grant itself the proposer role or shorten the delay; changing either is itself a
    ///     timelocked operation.
    ///   - `minDelay` must never be set to zero "temporarily" on a live network. The delay IS the
    ///     security model.
    function timelock(uint256 minDelay, address[] memory proposers) internal returns (TimelockController) {
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        return new TimelockController(minDelay, proposers, executors, address(0));
    }
}
