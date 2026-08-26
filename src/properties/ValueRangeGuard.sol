// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";
import {Configured} from "../catalogue/Configured.sol";
import {SubscriptionRegistry} from "../catalogue/SubscriptionRegistry.sol";

/// @notice A permitted range for one configuration slot.
struct Range {
    bytes32 slot;
    uint256 min;
    uint256 max;
}

/// @title ValueRangeGuard
/// @notice Declared configuration slots must hold a value inside their permitted range.
///
/// @dev Port of Phylax's `ConfigurationGuard` micro-pattern — "whole-state config sanity for
///      initialization, wiring, and timing parameters".
///
///      The complement to `SlotProtection`: that one freezes a slot, this lets it move within bounds.
///      Governance legitimately changes a fee or a timelock delay; what it must not do is set the fee
///      to 100% or the delay to zero, which is the shape a compromised-governance exploit takes. A
///      frozen slot cannot express "adjustable but sane".
///
///      Stateless: the ranges are per-adopter configuration, `abi.encode(Range[])`.
contract ValueRangeGuard is IProperty, Configured {
    using PreState for TransitionContext;

    constructor(SubscriptionRegistry s) Configured(s) {}

    function name() external pure returns (string memory) {
        return "ValueRangeGuard";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        (bytes memory cfg, bool present) = _rawConfig(ctx.target);
        if (!present) return (false, "property is not configured for this adopter");

        Range[] memory ranges = abi.decode(cfg, (Range[]));
        TransitionContext memory c = ctx;
        for (uint256 i; i < ranges.length; ++i) {
            Range memory r = ranges[i];
            if (!c.touched(r.slot)) continue;
            uint256 value = uint256(c.post(r.slot, bytes32(0)));
            if (value < r.min || value > r.max) {
                return (false, "a configuration slot left its permitted range");
            }
        }
        return (true, "");
    }
}
