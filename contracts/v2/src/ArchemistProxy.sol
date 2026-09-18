// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/**
 * @title ArchemistProxy
 * @notice Minimal EIP-1967 UUPS proxy. All logic, accounting and upgrade authorization live in the
 *         implementation contract - this proxy only stores the implementation address at the standard
 *         slot and forwards every call via delegatecall. It has no admin functions of its own.
 *
 * This is deliberately the SAME contract, byte for byte, as ArchemistFeeRouterProxy, which has been
 * running in production on Arc since the fee router's V1 and has been upgraded through it twice. It is
 * copied rather than imported because this repo's V2 contracts are compiled as standalone single files
 * (see contracts/v2/scripts/compile.mjs), and reusing proven, already-verified
 * proxy bytecode is worth more than avoiding the duplication.
 *
 * The frontend, the indexer and every integration target this proxy's address. Upgrading the
 * implementation never changes it, so nothing downstream has to move and no user ever re-approves.
 *
 * Two properties matter and both come from the constructor:
 *   - the implementation must have code, so the proxy can never be born pointing at nothing;
 *   - `data_` is delegatecalled during construction, so the proxy is initialized in the same
 *     transaction it is created and there is no window in which someone else can call `initialize`
 *     and take ownership.
 */
contract ArchemistProxy {
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    error InvalidImplementation();

    event Upgraded(address indexed implementation);

    constructor(address implementation_, bytes memory data_) {
        if (implementation_.code.length == 0) revert InvalidImplementation();
        _setImplementation(implementation_);
        emit Upgraded(implementation_);
        if (data_.length > 0) {
            (bool ok, bytes memory ret) = implementation_.delegatecall(data_);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function _setImplementation(address implementation_) private {
        assembly {
            sstore(_IMPLEMENTATION_SLOT, implementation_)
        }
    }

    fallback() external payable {
        assembly {
            let impl := sload(_IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // Deliberately NO `receive()`.
    //
    // A `receive()` here would swallow every empty-calldata transfer at the proxy, which means the
    // implementation's own guard - `if (msg.sender != _swapRouter02) revert InvalidPayment();` - would
    // never run, and anyone could park value in the factory. Without one, empty calldata falls through
    // to `fallback` and is delegatecalled into the implementation, so the implementation's rule is the
    // rule. That is also how V4's `ArchemistERC1967Proxy` is written, and why.
    //
    // This is the one byte-level difference from the fee router's proxy, which does have a `receive()`.
    // The divergence is deliberate and is the reason this file exists under its own name rather than
    // reusing `ArchemistFeeRouterProxy`.
}
