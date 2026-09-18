// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IVaultMockToken {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal stand-in for ArchemistV4Locker's claim surface, used to test ArchemistBuybackVault in
/// isolation. `setClaimable` simulates fee credits already recorded elsewhere; `claim` pays out real
/// balance the test pre-funded this mock with, exactly like the real locker paying from its own holdings.
contract MockVaultLocker {
    mapping(address beneficiary => mapping(address asset => uint256)) public claimable;

    function setClaimable(address beneficiary, address asset, uint256 amount) external {
        claimable[beneficiary][asset] = amount;
    }

    function claim(address asset, address to) external returns (uint256 amount) {
        amount = claimable[to][asset];
        claimable[to][asset] = 0;
        if (amount == 0) return 0;
        if (asset == address(0)) {
            (bool ok,) = to.call{ value: amount }("");
            require(ok);
        } else {
            require(IVaultMockToken(asset).transfer(to, amount));
        }
    }

    receive() external payable { }
}
