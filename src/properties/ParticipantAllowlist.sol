// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";

interface IParticipantRegistry {
    /// @notice Accounts participating in this transition, per the adopter's own reading of it.
    function participantsOf(bytes32[] calldata intentIds) external view returns (address[] memory);
    function isAllowedParticipant(address account) external view returns (bool);
}

/// @title ParticipantAllowlist
/// @notice Every participant in a transition must be on the adopter's allowlist.
///
/// @dev Covers Assertions Book #4 (KYC / whitelist) and the slot-based half of their `ParticipantGate`
///      micro-pattern.
///
///      **What is different from theirs.** `ParticipantGate` extracts participants from the call trace
///      — "extract participants from sensitive calls and block listed accounts" — so it works on any
///      protocol without cooperation. Here the adopter must name its own participants, because there
///      is no trace to extract them from. That is weaker in an important way: the property trusts the
///      adopter's answer, so a bug in `participantsOf` is a hole in the guard rather than a bug the
///      guard catches.
///
///      Worth using where the participant set is genuinely adopter state (a registry, a subscription
///      list), and worth distrusting where it is derived.
contract ParticipantAllowlist is IProperty {
    function name() external pure returns (string memory) {
        return "ParticipantAllowlist";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IParticipantRegistry r = IParticipantRegistry(ctx.target);
        address[] memory participants = r.participantsOf(ctx.intentIds);
        for (uint256 i; i < participants.length; ++i) {
            if (!r.isAllowedParticipant(participants[i])) {
                return (false, "a participant is not on the allowlist");
            }
        }
        return (true, "");
    }
}
