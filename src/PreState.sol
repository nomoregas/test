// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {SlotWrite, TransitionContext} from "./interfaces/IProperty.sol";

/// @title PreState
/// @notice Reconstructs the before-image of a transition from its diff.
///
/// @dev This is the Gas Killer answer to `ph.forkPreTx()` / `ph.forkPostTx()`. Phylax can hand an
///      assertion two live EVM forks because assertions run in a custom EVM. A property here may
///      run on-chain inside `settle`, where there is exactly one state — the post-state — and no
///      way to read a foreign contract's arbitrary slot at all (the EVM has no cross-contract
///      SLOAD).
///
///      The diff closes both gaps. For a slot the transition touched, pre-state is in the diff. For
///      a slot it did not touch, pre-state *is* post-state. So:
///
///          pre(slot) = touched(slot) ? firstOldValue(slot) : current(slot)
///
///      Callers supply `current` for untouched slots from wherever they can legitimately read it —
///      usually one of the target's own view functions. That keeps every property evaluable
///      on-chain, which is what lets `Mode.OnchainVerify` be a real option rather than a diagram.
///
///      **Endpoint semantics.** A diff may write the same slot more than once. The true endpoints
///      are the *first* `oldValue` and the *last* `newValue`; taking any intermediate pair would
///      compare against a state that never existed at a transition boundary. Phylax makes the same
///      choice for its own reason — "healthy vault operations update assets and shares at different
///      internal call boundaries, so intermediate snapshots are not part of this property".
library PreState {
    /// @notice Whether the transition wrote to `slot` at all.
    /// @dev A write is reported even when it stores the value already there. That matches Phylax's
    ///      `forbidChangeForSlots`, which flags a write "even if it sets the same value
    ///      (conservative -- a write is suspicious regardless of whether the value changed)". For a
    ///      frozen slot the interesting event is that something reached for it.
    function touched(TransitionContext memory ctx, bytes32 slot) internal pure returns (bool) {
        for (uint256 i; i < ctx.writes.length; ++i) {
            if (ctx.writes[i].slot == slot) return true;
        }
        return false;
    }

    /// @notice Value of `slot` before the transition, or `current` if it was never written.
    function pre(TransitionContext memory ctx, bytes32 slot, bytes32 current) internal pure returns (bytes32) {
        for (uint256 i; i < ctx.writes.length; ++i) {
            if (ctx.writes[i].slot == slot) return ctx.writes[i].oldValue; // first write wins
        }
        return current;
    }

    /// @notice Value of `slot` after the transition, or `current` if it was never written.
    function post(TransitionContext memory ctx, bytes32 slot, bytes32 current) internal pure returns (bytes32) {
        bytes32 value = current;
        bool found;
        for (uint256 i; i < ctx.writes.length; ++i) {
            if (ctx.writes[i].slot == slot) {
                value = ctx.writes[i].newValue; // last write wins
                found = true;
            }
        }
        return found ? value : current;
    }

    /// @notice Signed change in `slot` across the transition, read as a uint256 quantity.
    function delta(TransitionContext memory ctx, bytes32 slot, bytes32 current) internal pure returns (int256) {
        uint256 before = uint256(pre(ctx, slot, current));
        uint256 after_ = uint256(post(ctx, slot, current));
        return after_ >= before ? int256(after_ - before) : -int256(before - after_);
    }

    /// @notice Absolute magnitude of the change in `slot`.
    function absDelta(TransitionContext memory ctx, bytes32 slot, bytes32 current) internal pure returns (uint256) {
        uint256 before = uint256(pre(ctx, slot, current));
        uint256 after_ = uint256(post(ctx, slot, current));
        return after_ >= before ? after_ - before : before - after_;
    }
}
