// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";
import {Configured} from "../catalogue/Configured.sol";
import {SubscriptionRegistry} from "../catalogue/SubscriptionRegistry.sol";

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
///
///      Stateless: the frozen set is per-adopter configuration, `abi.encode(bytes32[])`.
contract SlotProtection is IProperty, Configured {
    using PreState for TransitionContext;

    constructor(SubscriptionRegistry s) Configured(s) {}

    function name() external pure returns (string memory) {
        return "SlotProtection";
    }

    function frozenSlotsFor(address adopter) public view returns (bytes32[] memory) {
        (bytes memory cfg, bool present) = _rawConfig(adopter);
        if (!present) return new bytes32[](0);
        return abi.decode(cfg, (bytes32[]));
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        (bytes memory cfg, bool present) = _rawConfig(ctx.target);
        if (!present) return (false, "property is not configured for this adopter");

        bytes32[] memory frozen = abi.decode(cfg, (bytes32[]));
        TransitionContext memory c = ctx;
        for (uint256 i; i < frozen.length; ++i) {
            if (c.touched(frozen[i])) return (false, "transition writes a frozen slot");
        }
        return (true, "");
    }
}
