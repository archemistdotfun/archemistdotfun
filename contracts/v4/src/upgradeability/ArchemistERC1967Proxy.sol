// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice The proxy every Archemist V4 system contract lives behind. A bare, renamed `ERC1967Proxy`:
/// no admin functions, no `receive()`, no logic of its own whatsoever.
///
/// The two things worth knowing about it:
///
///   - **It has no `receive()`, and that is deliberate.** An empty-calldata native transfer therefore
///     falls through to `fallback()` and is delegated to the implementation, so the implementation's own
///     `receive()` - including its sender check ("only the PoolManager and the locker may pay me") -
///     runs exactly as it did before the contract was put behind a proxy. Adding a `receive()` here
///     would silently accept native currency from anyone and bypass that check.
///     `test_nativeTransfersReachImplementationReceive` proves it rather than assuming it.
///
///   - **It is initialized in its own constructor.** `data_` is delegatecalled to the implementation
///     during construction, so there is no window in which the proxy exists uninitialized and a
///     front-runner could call `initialize` and take ownership.
///
/// It is a byte-for-byte standard `ERC1967Proxy`; the subclass exists only so the explorer, the
/// deployment manifest and `forge build --sizes` name it something recognisable.
contract ArchemistERC1967Proxy is ERC1967Proxy {
    constructor(address implementation_, bytes memory data_) payable ERC1967Proxy(implementation_, data_) { }
}
