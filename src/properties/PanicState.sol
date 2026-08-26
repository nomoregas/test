// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

interface IPausable {
    function pausedSlot() external view returns (bytes32);
    function paused() external view returns (bool);
}

/// @title PanicState
/// @notice While the adopter is paused, declared slots may not move.
///
/// @dev Port of Assertions Book #17. Pausing is the emergency brake every protocol has and almost
///      none re-checks: the modifier is on the functions someone remembered to annotate, and an
///      unannotated path stays live precisely when it matters most.
///
///      Evaluated against the paused flag at **both** endpoints, so a transition cannot pause itself
///      at the end to look compliant, nor unpause itself at the start to escape the check. If either
///      endpoint is paused, the protected slots must be untouched.
contract PanicState is IProperty {
    using PreState for TransitionContext;

    bytes32[] private _protected;

    constructor(bytes32[] memory protectedSlots) {
        for (uint256 i; i < protectedSlots.length; ++i) {
            _protected.push(protectedSlots[i]);
        }
    }

    function name() external pure returns (string memory) {
        return "PanicState";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        IPausable t = IPausable(ctx.target);

        bytes32 slot = t.pausedSlot();
        bytes32 current = bytes32(uint256(t.paused() ? 1 : 0));
        bool pausedBefore = uint256(c.pre(slot, current)) != 0;
        bool pausedAfter = uint256(c.post(slot, current)) != 0;

        if (!pausedBefore && !pausedAfter) return (true, "");

        for (uint256 i; i < _protected.length; ++i) {
            if (c.touched(_protected[i])) {
                return (false, "protected state moved while paused");
            }
        }
        return (true, "");
    }
}
