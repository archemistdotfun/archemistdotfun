// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Vm } from "forge-std/Vm.sol";

/// @notice Makes Arc's native/linked-USDC aliasing work inside a Foundry fork.
///
/// On Arc, the linked USDC at `0x3600…` is not an ordinary ERC-20 with its own ledger: `balanceOf`
/// reports the account's **native balance** divided by 1e12, and moving the token moves native. The
/// reporting half works in a fork for free, because it is plain EVM code reading `balance`. The moving
/// half does not: the implementation behind `0x3600…` calls a **precompile at `0x1800…`**, which exists
/// in Arc's client and not in revm, so every `transfer`/`transferFrom` dies with `OpcodeNotFound` after
/// burning a billion gas.
///
/// That is the whole reason the linked-USDC path has only ever been tested with `cast` against a live
/// chain. This shim closes it: etched at the precompile's address, it performs the same balance move
/// using `vm.deal`, so a fork can execute a real launch, real swaps and a real buyback against the real
/// Arc pools - without spending anything and without waiting for a block.
///
/// It is a test fixture and nothing else. It never ships, and the only thing it asserts about Arc is
/// the aliasing rule the chain already demonstrates on every block.
contract ArcNativeUsdcPrecompile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Native units per one unit of 6-decimal linked USDC.
    uint256 public constant SCALE = 1e12;

    event ShimTransfer(address indexed from, address indexed to, uint256 nativeAmount);

    error ShimInsufficientBalance(address from, uint256 have, uint256 want);
    error ShimUnhandledSelector(bytes4 selector);

    /// @dev The precompile is called with the amount already scaled up to native units.
    function transfer(address from, address to, uint256 nativeAmount) external returns (bool) {
        if (from.balance < nativeAmount) revert ShimInsufficientBalance(from, from.balance, nativeAmount);
        vm.deal(from, from.balance - nativeAmount);
        vm.deal(to, to.balance + nativeAmount);
        emit ShimTransfer(from, to, nativeAmount);
        return true;
    }

    /// @dev Anything else the implementation asks the precompile for shows up here by name, rather than
    /// as another unexplained `OpcodeNotFound` a thousand lines into a trace.
    fallback() external {
        revert ShimUnhandledSelector(msg.sig);
    }
}

/// @notice The compliance precompile the linked USDC consults on every transfer.
///
/// Arc's linked USDC is Circle-issued, and its implementation asks `0x1800…0001` whether either party
/// is blocklisted before it will move anything. Another client-side precompile, another
/// `OpcodeNotFound` in a fork - and a genuine integration fact none of the mocks in this suite ever
/// showed: **a transfer of the quote currency can be refused by a third party**, on the swap path, in
/// the buyback, and in a holder-reward payout.
///
/// The shim answers "not blocklisted" by default so the happy path can run, and lets a test blocklist
/// an address deliberately to see what the system does when Circle says no.
contract ArcBlocklistPrecompile {
    mapping(address => bool) public blocked;

    error ShimUnhandledSelector(bytes4 selector);

    function setBlocklisted(address account, bool value) external {
        blocked[account] = value;
    }

    function isBlocklisted(address account) external view returns (bool) {
        return blocked[account];
    }

    fallback() external {
        revert ShimUnhandledSelector(msg.sig);
    }
}

/// @notice One call that makes a fork of Arc behave like Arc.
library ArcFork {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant NATIVE_USDC_PRECOMPILE = 0x1800000000000000000000000000000000000000;
    address internal constant BLOCKLIST_PRECOMPILE = 0x1800000000000000000000000000000000000001;
    address internal constant LINKED_USDC = 0x3600000000000000000000000000000000000000;

    function install() internal {
        vm.etch(NATIVE_USDC_PRECOMPILE, address(new ArcNativeUsdcPrecompile()).code);
        // The shim moves native with `vm.deal`, which forge refuses from an etched address unless it is
        // explicitly allowed - a good default, and exactly the kind of thing to opt into by name.
        vm.allowCheatcodes(NATIVE_USDC_PRECOMPILE);
        vm.etch(BLOCKLIST_PRECOMPILE, address(new ArcBlocklistPrecompile()).code);

        vm.label(NATIVE_USDC_PRECOMPILE, "ArcNativeUsdcPrecompile(shim)");
        vm.label(BLOCKLIST_PRECOMPILE, "ArcBlocklistPrecompile(shim)");
        vm.label(LINKED_USDC, "LinkedUSDC");
    }

    function setBlocklisted(address account, bool value) internal {
        ArcBlocklistPrecompile(BLOCKLIST_PRECOMPILE).setBlocklisted(account, value);
    }

    /// @dev Funding an account with linked USDC is funding it with native, at 1e12 to one.
    function dealUsdc(address to, uint256 usdcUnits) internal {
        vm.deal(to, to.balance + usdcUnits * 1e12);
    }
}
