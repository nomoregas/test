// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext, CallEntry, LogEntry} from "../../interfaces/IProperty.sol";
import {Configured} from "../../catalogue/Configured.sol";
import {SubscriptionRegistry} from "../../catalogue/SubscriptionRegistry.sol";

/// @notice Addresses a transition may call, and a ceiling on native value sent.
struct CallPolicy {
    address[] allowedTargets;
    uint256 maxValuePerCall;
    uint256 maxTotalValue;
}

/// @title CallAllowlist
/// @notice A transition may only call addresses the contract approved, within value limits.
///
/// @dev Unblocked by carrying the diff's `call` entries. This is the rule that matters most in that
///      set: a settlement that can call anything is a settlement that can move anything. Bounding
///      the call targets does for outward effects what `SlotDomain` does for storage — it closes the
///      class rather than enumerating the ways it could go wrong.
///
///      Not equivalent to Phylax's call introspection. Theirs reads the transaction's whole call
///      trace, so it can judge calls the protocol made for its own reasons. This judges the calls a
///      *settlement* declares, which is the only outward effect a guarded contract has.
contract CallAllowlist is IProperty, Configured {
    constructor(SubscriptionRegistry s) Configured(s) {}

    function name() external pure returns (string memory) {
        return "CallAllowlist";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        (bytes memory cfg, bool present) = _rawConfig(ctx.target);
        if (!present) return (false, "property is not configured for this adopter");

        CallPolicy memory policy = abi.decode(cfg, (CallPolicy));
        uint256 total;

        for (uint256 i; i < ctx.calls.length; ++i) {
            CallEntry calldata c = ctx.calls[i];

            bool allowed;
            for (uint256 j; j < policy.allowedTargets.length; ++j) {
                if (policy.allowedTargets[j] == c.target) {
                    allowed = true;
                    break;
                }
            }
            if (!allowed) return (false, "transition calls an address outside the allowlist");

            if (policy.maxValuePerCall != 0 && c.value > policy.maxValuePerCall) {
                return (false, "a call sends more value than permitted");
            }
            total += c.value;
        }

        if (policy.maxTotalValue != 0 && total > policy.maxTotalValue) {
            return (false, "transition sends more value in total than permitted");
        }
        return (true, "");
    }
}

/// @title RequiredEvent
/// @notice A transition that changes state must announce it with a given event topic.
///
/// @dev Unblocked by carrying the diff's `log` entries. Silent state changes are how an incident
///      goes unnoticed for hours: every off-chain consumer — indexers, accounting, monitoring, the
///      protocol's own dashboards — is driven by events, so a write with no matching event is
///      invisible to all of them while being perfectly real on-chain.
///
///      Configured with the topic that must be present. A transition writing nothing is exempt,
///      since there is nothing to announce.
contract RequiredEvent is IProperty, Configured {
    constructor(SubscriptionRegistry s) Configured(s) {}

    function name() external pure returns (string memory) {
        return "RequiredEvent";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        (bytes memory cfg, bool present) = _rawConfig(ctx.target);
        if (!present) return (false, "property is not configured for this adopter");
        if (ctx.writes.length == 0) return (true, "");

        bytes32 required = abi.decode(cfg, (bytes32));
        for (uint256 i; i < ctx.logs.length; ++i) {
            LogEntry calldata l = ctx.logs[i];
            if (l.topics.length != 0 && l.topics[0] == required) return (true, "");
        }
        return (false, "state changed without emitting the required event");
    }
}

/// @title NoUnexpectedEvents
/// @notice Every event a transition emits must be one the contract declared it can emit.
///
/// @dev The denylist counterpart to `RequiredEvent`. An event topic the contract does not recognise
///      means something ran that the contract's own author did not account for — a delegatecall into
///      unfamiliar code, or a settlement doing more than it claimed.
contract NoUnexpectedEvents is IProperty, Configured {
    constructor(SubscriptionRegistry s) Configured(s) {}

    function name() external pure returns (string memory) {
        return "NoUnexpectedEvents";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        (bytes memory cfg, bool present) = _rawConfig(ctx.target);
        if (!present) return (false, "property is not configured for this adopter");

        bytes32[] memory known = abi.decode(cfg, (bytes32[]));
        for (uint256 i; i < ctx.logs.length; ++i) {
            LogEntry calldata l = ctx.logs[i];
            if (l.topics.length == 0) return (false, "transition emits an anonymous event");

            bool recognised;
            for (uint256 j; j < known.length; ++j) {
                if (known[j] == l.topics[0]) {
                    recognised = true;
                    break;
                }
            }
            if (!recognised) return (false, "transition emits an event the contract does not declare");
        }
        return (true, "");
    }
}
