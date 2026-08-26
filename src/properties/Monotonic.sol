// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";
import {Configured} from "../catalogue/Configured.sol";
import {SubscriptionRegistry} from "../catalogue/SubscriptionRegistry.sol";

/// @title Monotonic
/// @notice Declared slots may never decrease.
///
/// @dev Port of the monotonic-counter micro-pattern. The property that protects nonces, epochs,
///      cumulative fee indices, reward accumulators, last-updated timestamps and high-water marks —
///      anything whose whole correctness argument is "this only ever goes up".
///
///      Decidable from the diff alone: a slot the transition did not touch cannot have decreased, so
///      no view access to the target is required. Rewinding an accumulator is a favourite exploit
///      primitive precisely because the contract rarely re-checks it — the increment path is audited,
///      the value is not.
///
///      Stateless: the watched set is per-adopter configuration, `abi.encode(bytes32[])`.
contract Monotonic is IProperty, Configured {
    using PreState for TransitionContext;

    constructor(SubscriptionRegistry s) Configured(s) {}

    function name() external pure returns (string memory) {
        return "Monotonic";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        (bytes memory cfg, bool present) = _rawConfig(ctx.target);
        if (!present) return (false, "property is not configured for this adopter");

        bytes32[] memory slots = abi.decode(cfg, (bytes32[]));
        TransitionContext memory c = ctx;
        for (uint256 i; i < slots.length; ++i) {
            bytes32 slot = slots[i];
            if (!c.touched(slot)) continue;
            if (uint256(c.post(slot, bytes32(0))) < uint256(c.pre(slot, bytes32(0)))) {
                return (false, "a monotonic slot decreased");
            }
        }
        return (true, "");
    }
}
