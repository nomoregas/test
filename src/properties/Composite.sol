// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";

/// @title Composite
/// @notice Combines several properties under one operator, AND or OR, in a single evaluation.
///
/// @dev Port of the structural argument behind Phylax's `AnomalyCompositeAssertion`, which applies
///      to this registry unchanged.
///
///      A set of separately subscribed rules can only ever express OR. The registry returns on the
///      first violation, so subscribing to three rules yields "revert if h1 or h2 or h3 is violated".
///      Reverting is disjunctive across subscriptions, so a conjunction — *revert only when several
///      heuristics agree* — cannot be assembled from separate entries at all. It has to live inside
///      one `check`.
///
///      That matters whenever a single signal is too noisy to act on alone. A large withdrawal is
///      not an exploit; a large withdrawal *and* a fresh counterparty *and* an oracle that just
///      moved might be. Under `Operator.Or` this behaves like the fleet and is mostly a convenience.
///      Under `Operator.And` it expresses something the registry structurally cannot.
///
///      Their second observation also carries over: the exclusive-set fall-through
///      `NOT(h1) AND NOT(h2) ...` needs to be a non-revert outcome of the same evaluation, which
///      again requires one function rather than several contracts.
contract Composite is IProperty {
    enum Operator {
        Or,
        And
    }

    Operator public immutable operator;
    string private _name;
    IProperty[] private _members;

    error NoMembers();

    constructor(string memory name_, Operator operator_, IProperty[] memory members_) {
        if (members_.length == 0) revert NoMembers();
        _name = name_;
        operator = operator_;
        for (uint256 i; i < members_.length; ++i) {
            _members.push(members_[i]);
        }
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function memberCount() external view returns (uint256) {
        return _members.length;
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        uint256 n = _members.length;

        if (operator == Operator.Or) {
            for (uint256 i; i < n; ++i) {
                (bool held, string memory why) = _members[i].check(ctx);
                if (!held) return (false, why);
            }
            return (true, "");
        }

        // And: a violation requires every member to be violated. One member holding is enough to
        // let the transition through, which is the whole point of gating a noisy signal.
        string memory lastReason;
        for (uint256 i; i < n; ++i) {
            (bool held, string memory why) = _members[i].check(ctx);
            if (held) return (true, "");
            lastReason = why;
        }
        return (false, lastReason);
    }
}
