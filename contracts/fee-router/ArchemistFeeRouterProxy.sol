// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/**
 * @title ArchemistFeeRouterProxy
 * @notice Minimal EIP-1967 UUPS proxy. All swap logic, fee accounting, and upgrade
 *         authorization live in the implementation contract (ArchemistFeeRouterV1
 *         and any future version) - this proxy only stores the implementation
 *         address at the standard slot and forwards every call via delegatecall.
 *
 * The frontend (/token and /dex) always targets this proxy's address. Upgrading
 * the implementation (new fee logic, a different swap venue, Uniswap v2/v4
 * support, etc.) never changes this address, so users never need to re-approve.
 *
 * IMPORTANT: Research draft. It has not been audited and must not be deployed to
 * production before testnet validation and an independent security review.
 */
contract ArchemistFeeRouterProxy {
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

    receive() external payable {}
}
