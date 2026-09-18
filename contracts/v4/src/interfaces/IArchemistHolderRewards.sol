// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IArchemistHolderRewards {
    function LAUNCHER() external view returns (address);
    function LOCKER() external view returns (address);

    /// @notice Pre-registers a launch token (and the currency its holders will be rewarded in) before
    ///         the token contract itself is deployed. Launcher-only, once per token.
    function register(address token, address quote) external;

    /// @notice Called by the locker when a sell fee's holder slice has been credited to this contract.
    /// @return accepted False when there is nothing to distribute to (no eligible supply yet), telling
    ///         the locker to route that slice to the treasury instead of stranding it here.
    function notify(address token, address asset, uint256 amount) external returns (bool accepted);

    function earned(address token, address holder) external view returns (uint256);
}

/// @notice The reward-accounting surface a launch token exposes to its custodian. Every one of these is
/// `onlyRewards` on the token side; nothing here is reachable by anyone else.
/// @dev Deliberately NOT part of the token's transfer path - see the contract note on ArchemistV4Token
/// for why the old `onTransfer` callback had to go.
interface IArchemistRewardToken {
    function notifyReward(uint256 amount) external returns (bool accepted);
    function consumeReward(address holder) external returns (uint256 amount);
    function restoreReward(address holder, uint256 amount) external;
    function earned(address holder) external view returns (uint256);
    function eligibleSupply() external view returns (uint256);
    function rewardPerTokenX128() external view returns (uint256);
    function excluded(address account) external view returns (bool);
}
