// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";
import {Configured} from "../catalogue/Configured.sol";
import {SubscriptionRegistry} from "../catalogue/SubscriptionRegistry.sol";

/// @title ValueConservation
/// @notice The sum over a declared set of slots is unchanged across the transition.
///
/// @dev Adapted from Phylax's `BalanceConservationAssertion`, with one deliberate difference. Theirs
///      pins specific (token, account) balances so a treasury or escrow cannot move at all. This
///      conserves the *total* across the set while permitting redistribution inside it, which is the
///      property an accounting system actually wants: shares may move between holders, but none may
///      be created or destroyed. Freeze semantics are `SlotProtection`, not this.
///
///      **What does not port.** Their version reads ERC-20 `balanceOf` on foreign token contracts
///      across two forks. A Gas Killer diff describes the adopter's own storage, so a property here
///      cannot see a token contract's ledger.
///
///      Stateless: the conserved set is per-adopter configuration, `abi.encode(bytes32[])`.
contract ValueConservation is IProperty, Configured {
    using PreState for TransitionContext;

    constructor(SubscriptionRegistry s) Configured(s) {}

    function name() external pure returns (string memory) {
        return "ValueConservation";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        (bytes memory cfg, bool present) = _rawConfig(ctx.target);
        if (!present) return (false, "property is not configured for this adopter");

        bytes32[] memory slots = abi.decode(cfg, (bytes32[]));
        TransitionContext memory c = ctx;
        uint256 before;
        uint256 after_;
        for (uint256 i; i < slots.length; ++i) {
            bytes32 slot = slots[i];
            if (!c.touched(slot)) continue;
            before += uint256(c.pre(slot, bytes32(0)));
            after_ += uint256(c.post(slot, bytes32(0)));
        }
        if (before != after_) return (false, "declared slot set did not conserve its total");
        return (true, "");
    }
}
