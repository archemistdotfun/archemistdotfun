// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice A launch token. Plain, immutable, ownerless ERC-20 - with holder-reward accounting kept
/// inside the contract rather than delegated to another one.
///
/// **Why the accounting lives here.** It used to live in `ArchemistHolderRewards`, and `_transfer`
/// called into it on every single transfer. That one external call is what token-safety scanners
/// (GoPlus, De.Fi, Blockaid and friends) decompile out of the bytecode and report as
/// *"Trade Restriction - an external transfer checker can reject transfers and potentially trap holders
/// from selling"*, High severity. The finding is about shape, not intent: any callee whose revert would
/// revert the transfer can trap holders, and the scanner cannot know ours would not. Wrapping the call
/// in try/catch does not help - the external call is still there to be found, and swallowing a failure
/// would silently corrupt every holder's entitlement. The only fix that actually removes the finding is
/// to remove the call, so the accounting moved in here and `ArchemistHolderRewards` became a pure
/// custodian that holds the quote currency and pays claims.
///
/// **What that buys, precisely.** `_transfer` now makes no `CALL`, `STATICCALL` or `DELEGATECALL` at
/// all (proved by `test_transferBytecodeHasNoExternalCall`), and its only two revert paths are
/// `InsufficientBalance` and `to == address(0)` - the two every plain ERC-20 has. Everything else it
/// does is unchecked arithmetic whose bounds are argued at each site below. No admin, anywhere, can
/// stop, tax, freeze or redirect a transfer, because there is no admin.
///
/// **The accounting itself** is the standard "reward per token" accumulator, the same shape Uniswap v3
/// uses for fee growth:
///
///   - A sell's holder slice raises one number, `rewardPerTokenX128`, by `amount·2^128 / eligibleSupply`.
///     It never loops over holders - the holder set is unbounded and this is called from inside some
///     unrelated trader's swap.
///   - Every holder's entitlement is derived on demand from their own balance and the accumulator's
///     movement since they last settled. `_transfer` settles both sides at their *pre*-transfer balances,
///     so a holder earns for exactly the intervals they actually held and there is no snapshot instant
///     to game.
///   - `eligibleSupply` excludes the infrastructure addresses - above all the PoolManager, which
///     custodies nearly the whole supply as pool liquidity. Dividing by `totalSupply` instead would send
///     the overwhelming majority of every distribution to the pool, where nobody could ever claim it.
///     The consequence is intended: shares are relative to the circulating float, so early holders take
///     large shares that dilute as more of the supply is bought. The exclusion set is fixed in the
///     constructor and there is no function to change it - nobody can redefine who counts as a holder.
///
/// The `rewards` contract is the only caller that can move the accumulator or collect what a holder is
/// owed, and it can do neither to anyone's detriment: `notifyReward` only ever increases entitlements,
/// and `consumeReward` is how a holder's own `claim` is paid out.
contract ArchemistV4Token {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 private constant Q128 = 1 << 128;

    uint256 public immutable totalSupply;
    address public immutable launcher;
    /// @dev Custodian of the quote currency and the only address allowed to move this token's reward
    /// accumulator or settle a holder's balance out. Fixed at construction; there is no setter.
    address public immutable rewards;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Addresses that hold this token without being holders in any meaningful sense, and so are
    /// neither counted in `eligibleSupply` nor able to earn: the PoolManager (pool liquidity), the
    /// locker (the LP position), the launcher (the supply in transit during the launch tx), the rewards
    /// custodian, and this contract itself. Written once, in the constructor. No setter exists.
    mapping(address => bool) public excluded;

    /// @notice Sum of the balances of every non-excluded address - the denominator of every distribution.
    uint256 public eligibleSupply;

    /// @notice Running reward per unit of eligible supply, Q128 fixed point. Q128 is what stops a holder
    /// with a very small share from being rounded to zero on every single distribution and losing their
    /// accrual: the truncation happens once, at settlement, not on every sell.
    /// @dev Accumulates `unchecked`. Wrap-around is harmless for the same reason it is in Uniswap v3's
    /// `feeGrowthGlobal`: every entitlement is computed from the *difference* `rpt - paid`, which wraps
    /// identically. Reaching a wrap would take 2^256 of reward-per-token anyway.
    uint256 public rewardPerTokenX128;

    struct HolderState {
        uint256 paidPerTokenX128;
        uint256 owed;
    }

    mapping(address => HolderState) public holderState;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event RewardNotified(uint256 amount, uint256 eligibleSupply);

    error EmptyMetadata();
    error InvalidReceiver();
    error InsufficientBalance();
    error InsufficientAllowance();
    error NotRewards();

    modifier onlyRewards() {
        if (msg.sender != rewards) revert NotRewards();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        address rewards_,
        address locker_,
        address poolManager_
    ) {
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyMetadata();
        if (supply_ == 0) revert InsufficientBalance();
        if (rewards_ == address(0) || locker_ == address(0) || poolManager_ == address(0)) revert InvalidReceiver();

        name = name_;
        symbol = symbol_;
        totalSupply = supply_;
        launcher = msg.sender;
        rewards = rewards_;

        excluded[msg.sender] = true;
        excluded[locker_] = true;
        excluded[poolManager_] = true;
        excluded[rewards_] = true;
        excluded[address(this)] = true;

        // Not routed through _transfer: the launcher is excluded, so this mint changes no entitlement
        // and moves no eligible supply.
        balanceOf[msg.sender] = supply_;

        emit Transfer(address(0), msg.sender, supply_);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Raises the reward accumulator by `amount` of the pool's quote currency, which the rewards
    /// custodian is by then holding on this token's holders' behalf.
    /// @return accepted False - never a revert - when there is nothing to distribute to, nothing to
    ///         distribute, or an amount so far outside any real fee that the Q128 scaling could
    ///         overflow. This is called from inside a trader's swap, and the locker's fallback (route
    ///         the slice to the treasury instead) is strictly better than failing their trade.
    function notifyReward(uint256 amount) external onlyRewards returns (bool accepted) {
        uint256 supply = eligibleSupply;
        if (supply == 0 || amount == 0 || amount >= Q128) return false;
        unchecked {
            rewardPerTokenX128 += FullMath.mulDiv(amount, Q128, supply);
        }
        emit RewardNotified(amount, supply);
        return true;
    }

    /// @notice Settles `holder` and hands their whole accrued balance to the custodian to pay out.
    /// @dev The custodian is responsible for actually delivering it; if delivery fails it credits the
    /// amount back via a fresh `notifyReward`-independent path of its own (see `claimFor`).
    function consumeReward(address holder) external onlyRewards returns (uint256 amount) {
        if (excluded[holder]) return 0;
        _settle(holder, rewardPerTokenX128);
        HolderState storage hs = holderState[holder];
        amount = hs.owed;
        hs.owed = 0;
    }

    /// @notice Restores an entitlement the custodian took but could not deliver (a recipient contract
    /// that rejects payment, an address the quote currency's issuer has not allowlisted). Nothing is
    /// lost and nothing is stuck: the holder can still claim it later themselves.
    function restoreReward(address holder, uint256 amount) external onlyRewards {
        if (amount == 0) return;
        unchecked {
            holderState[holder].owed += amount;
        }
    }

    /// @notice Rewards `holder` could collect right now, including what has accrued since they last
    /// settled.
    function earned(address holder) external view returns (uint256) {
        if (excluded[holder]) return 0;
        HolderState storage hs = holderState[holder];
        return hs.owed + _pending(holder, hs.paidPerTokenX128, rewardPerTokenX128);
    }

    /// @dev Exactly two revert paths, both of which every plain ERC-20 has. Nothing else here can fail:
    /// see the per-site bound arguments on each `unchecked` block.
    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidReceiver();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();

        uint256 rpt = rewardPerTokenX128;
        bool fromEligible = !excluded[from];
        bool toEligible = !excluded[to];

        // Settled BEFORE the balances move, so both sides are measured over the interval that just
        // ended, at what they actually held during it.
        if (fromEligible) _settle(from, rpt);
        if (toEligible && to != from) _settle(to, rpt);

        unchecked {
            // `balance >= amount` was just checked, and `balanceOf[to] + amount <= totalSupply` because
            // balances always sum to totalSupply.
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;

            // The denominator only moves when the transfer crosses the eligibility boundary. Same-side
            // transfers (holder to holder, infrastructure to infrastructure) leave it untouched.
            // Both directions are exact: eligibleSupply is by construction the sum of non-excluded
            // balances, so it is >= `amount` whenever an eligible address is sending, and adding
            // `amount` can never take it past totalSupply.
            if (fromEligible != toEligible) {
                if (toEligible) {
                    eligibleSupply += amount;
                } else {
                    eligibleSupply -= amount;
                }
            }
        }

        emit Transfer(from, to, amount);
    }

    function _settle(address holder, uint256 rpt) private {
        HolderState storage hs = holderState[holder];
        uint256 paid = hs.paidPerTokenX128;
        if (paid == rpt) return;
        uint256 pending = _pending(holder, paid, rpt);
        if (pending != 0) {
            // Unchecked so that `_transfer` has no arithmetic revert path at all. Unreachable in
            // practice: `owed` is bounded by the sum of everything ever notified, and every notify is
            // bounded by `Q128`.
            unchecked {
                hs.owed += pending;
            }
        }
        hs.paidPerTokenX128 = rpt;
    }

    /// @dev `FullMath.mulDiv` cannot revert here, which is what makes `_transfer` revert-free:
    /// `balance <= totalSupply = 1e27 < 2^90` and `rpt - paid < 2^256`, so the intermediate product is
    /// below 2^346 and the quotient below 2^218 - comfortably inside uint256, and the denominator is a
    /// nonzero constant.
    function _pending(address holder, uint256 paid, uint256 rpt) private view returns (uint256) {
        if (rpt == paid) return 0;
        uint256 balance = balanceOf[holder];
        if (balance == 0) return 0;
        unchecked {
            return FullMath.mulDiv(balance, rpt - paid, Q128);
        }
    }
}
