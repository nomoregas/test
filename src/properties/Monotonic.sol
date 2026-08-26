// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

/// @title Monotonic
/// @notice Declared slots may never decrease.
///
/// @dev Port of the monotonic-counter micro-pattern. The property that protects nonces, epochs,
///      cumulative fee indices, reward accumulators, last-updated timestamps and high-water marks —
///      anything whose whole correctness argument is "this only ever goes up".
///
///      Cheap to state and, in this model, decidable from the diff alone: a slot the transition did
///      not touch cannot have decreased, so no view access to the target is required.
///
///      Rewinding an accumulator is a favourite exploit primitive precisely because the contract
///      itself rarely re-checks it — the increment path is audited, the value is not.
contract Monotonic is IProperty {
    using PreState for TransitionContext;

    bytes32[] private _slots;

    constructor(bytes32[] memory slots) {
        for (uint256 i; i < slots.length; ++i) {
            _slots.push(slots[i]);
        }
    }

    function name() external pure returns (string memory) {
        return "Monotonic";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        for (uint256 i; i < _slots.length; ++i) {
            bytes32 slot = _slots[i];
            if (!c.touched(slot)) continue;
            if (uint256(c.post(slot, bytes32(0))) < uint256(c.pre(slot, bytes32(0)))) {
                return (false, "a monotonic slot decreased");
            }
        }
        return (true, "");
    }
}
