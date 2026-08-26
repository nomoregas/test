// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

/// @title SlotProtection
/// @notice Declared slots are frozen: a transition may not write them at all.
///
/// @dev Port of Phylax's `SlotProtectionAssertion` / `forbidChangeForSlots`, and the denylist
///      counterpart to `SlotDomain`'s allowlist. Covers the same ground: proxy admin, owner and
///      implementation slots, timelock delays, role slots, fee parameters, oracle addresses.
///
///      Deliberately flags a write even when it stores the value already present, matching their
///      reasoning that "a write is suspicious regardless of whether the value changed". For a slot
///      that is supposed to be frozen, something reaching for it is the signal — a no-op write is
///      usually a probe or an unexpected code path, not a harmless coincidence.
contract SlotProtection is IProperty {
    using PreState for TransitionContext;

    bytes32[] private _frozen;

    constructor(bytes32[] memory frozenSlots) {
        for (uint256 i; i < frozenSlots.length; ++i) {
            _frozen.push(frozenSlots[i]);
        }
    }

    function name() external pure returns (string memory) {
        return "SlotProtection";
    }

    function frozenCount() external view returns (uint256) {
        return _frozen.length;
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        for (uint256 i; i < _frozen.length; ++i) {
            if (c.touched(_frozen[i])) {
                return (false, "transition writes a frozen slot");
            }
        }
        return (true, "");
    }
}
