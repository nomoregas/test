// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";
import {Configured} from "../catalogue/Configured.sol";
import {SubscriptionRegistry} from "../catalogue/SubscriptionRegistry.sol";

/// @notice A per-transition movement cap on one slot.
struct Bound {
    bytes32 slot;
    uint256 maxAbsDelta;
}

/// @title DeltaBound
/// @notice A declared slot may not move by more than a fixed amount in one transition.
///
/// @dev The per-transition rate limit: a supply cap's step size, a maximum single withdrawal, the
///      largest permissible oracle jump. Blocks the shape of exploit that drains everything in one
///      transaction while leaving ordinary activity untouched.
///
///      **This is the honest half of Phylax's circuit breaker.** Their
///      `ERC4626CumulativeOutflowAssertion` caps *cumulative* outflow within a rolling window, and it
///      works because their executor "handles all persistent state tracking, TVL snapshots, and
///      threshold enforcement internally". A property here is a pure function of one transition and
///      has nowhere to keep a window, so this bounds a single step — strictly weaker, since it cannot
///      catch a drain spread across many small transitions.
///
///      Stateless: the bounds are per-adopter configuration, `abi.encode(Bound[])`.
contract DeltaBound is IProperty, Configured {
    using PreState for TransitionContext;

    constructor(SubscriptionRegistry s) Configured(s) {}

    function name() external pure returns (string memory) {
        return "DeltaBound";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        (bytes memory cfg, bool present) = _rawConfig(ctx.target);
        if (!present) return (false, "property is not configured for this adopter");

        Bound[] memory bounds = abi.decode(cfg, (Bound[]));
        TransitionContext memory c = ctx;
        for (uint256 i; i < bounds.length; ++i) {
            if (!c.touched(bounds[i].slot)) continue;
            if (c.absDelta(bounds[i].slot, bytes32(0)) > bounds[i].maxAbsDelta) {
                return (false, "a slot moved more than its per-transition bound");
            }
        }
        return (true, "");
    }
}
