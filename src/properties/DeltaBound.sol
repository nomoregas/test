// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

/// @title DeltaBound
/// @notice A declared slot may not move by more than a fixed amount in one transition.
///
/// @dev The per-transition rate limit: a supply cap's step size, a maximum single withdrawal, the
///      largest permissible oracle jump. Blocks the shape of exploit that drains everything in one
///      transaction while leaving ordinary activity untouched.
///
///      **This is the honest half of Phylax's circuit breaker.** Their
///      `ERC4626CumulativeOutflowAssertion` caps *cumulative* outflow within a rolling time window,
///      and it works because their executor "handles all persistent state tracking, TVL snapshots,
///      and threshold enforcement internally". A property here is a pure function of one transition
///      — it has nowhere to keep a window. So this bounds a single step, which is strictly weaker:
///      it cannot catch a drain spread across many small transitions.
///
///      Closing that gap needs the window kept somewhere. The natural place is guarded state on the
///      adopter itself, updated by the same attested diff — which would make the rolling breaker
///      expressible, at the cost of the property no longer being stateless. Worth building, but it
///      is a design change rather than another property, so it is not pretended here.
contract DeltaBound is IProperty {
    using PreState for TransitionContext;

    struct Bound {
        bytes32 slot;
        uint256 maxAbsDelta;
    }

    Bound[] private _bounds;

    constructor(Bound[] memory bounds) {
        for (uint256 i; i < bounds.length; ++i) {
            _bounds.push(bounds[i]);
        }
    }

    function name() external pure returns (string memory) {
        return "DeltaBound";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        for (uint256 i; i < _bounds.length; ++i) {
            Bound memory b = _bounds[i];
            if (!c.touched(b.slot)) continue;
            if (c.absDelta(b.slot, bytes32(0)) > b.maxAbsDelta) {
                return (false, "a slot moved more than its per-transition bound");
            }
        }
        return (true, "");
    }
}
