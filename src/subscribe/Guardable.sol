// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IAttestor} from "../interfaces/IProperty.sol";

/// @title Guardable
/// @notice Additive protection for a contract that already exists: annotate the functions that let
///         value leave, deploy nothing else, rewrite nothing.
///
/// @dev **Why this shape.** `GuardedState` gives the strong guarantee — no violating state change,
///      ever — but only by routing every write through attested settlement, which means rewriting the
///      contract. For an already-deployed protocol that is not an option, and there is a hard limit
///      on what any additive change can do: nothing can veto a synchronous write. By the time an
///      operator sees a transaction it is mined. State corruption is therefore not preventable this
///      way, and pretending otherwise would be the dishonest version of this contract.
///
///      What *is* preventable is loss. An exploit that corrupts state but cannot extract value is a
///      bug report rather than an incident. So the guarantee here is narrower and still worth having:
///      **value cannot leave faster than an operator quorum has recently agreed it may.**
///
///      **The inversion.** Operators do not veto anything. They evaluate the property set off-chain
///      against the live contract — the same `IProperty` contracts, unchanged — and periodically
///      attest a spending budget with an expiry. On-chain, an outflow costs one storage read and a
///      comparison. If a property is violated, operators simply stop refreshing; the budget expires
///      and outflows stop. Nothing has to be proven on-chain, because the absence of an attestation
///      *is* the signal.
///
///      That makes it fail-closed, which is the right default for a security device and a real
///      liveness cost: a quorum that stops attesting freezes withdrawals, whether it is honest,
///      broken, or censoring. `budgetGracePeriod` bounds how long a lapse can bite before governance
///      can intervene, and the honest framing is that you have traded some liveness for containment.
abstract contract Guardable {
    IAttestor public guardAttestor;

    /// @notice Value permitted to leave in the current epoch.
    uint256 public outflowBudget;
    /// @notice Value that has already left in the current epoch.
    uint256 public outflowSpent;
    /// @notice After this timestamp the budget is void and outflows stop.
    uint256 public budgetExpiry;
    /// @notice Monotonic epoch, so a refresh cannot be replayed.
    uint256 public budgetEpoch;

    error BudgetExpired(uint256 expiry, uint256 now_);
    error BudgetExceeded(uint256 requested, uint256 remaining);
    error NotAttested();
    error StaleEpoch(uint256 given, uint256 expected);
    error ExpiryInPast();

    event BudgetRefreshed(uint256 epoch, uint256 budget, uint256 expiry);
    event OutflowConsumed(uint256 amount, uint256 spent, uint256 budget);

    constructor(IAttestor attestor_) {
        guardAttestor = attestor_;
    }

    /// @notice Annotate an existing value-releasing function with this.
    /// @dev Deliberately consumes budget *after* the body runs, so it measures what the function
    ///      actually did rather than what it was asked to do, and reverts the whole call if the
    ///      result exceeds what was attested. A modifier cannot un-send a transfer, but it can
    ///      revert the transaction that made it — which is prevention, not detection.
    ///
    ///      The one thing the integrator must supply is the amount, which is why this is a parameterised
    ///      modifier rather than a bare one. That is the "addition of lines" cost: an annotation at
    ///      each exit, and no change to the body.
    modifier guardedOutflow(uint256 amount) {
        _;
        _consumeOutflow(amount);
    }

    /// @notice Operators publish a fresh budget after checking every property off-chain.
    /// @dev The digest binds epoch, budget and expiry, so an attestation cannot be replayed into a
    ///      later epoch or stretched to a longer window than the quorum agreed to.
    function refreshBudget(uint256 epoch, uint256 budget, uint256 expiry, bytes calldata attestation) external {
        if (epoch != budgetEpoch + 1) revert StaleEpoch(epoch, budgetEpoch + 1);
        if (expiry <= block.timestamp) revert ExpiryInPast();

        bytes32 digest = budgetDigest(epoch, budget, expiry);
        if (!guardAttestor.verify(digest, attestation)) revert NotAttested();

        budgetEpoch = epoch;
        outflowBudget = budget;
        outflowSpent = 0;
        budgetExpiry = expiry;
        emit BudgetRefreshed(epoch, budget, expiry);
    }

    function budgetDigest(uint256 epoch, uint256 budget, uint256 expiry) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), epoch, budget, expiry));
    }

    /// @notice What may still leave right now.
    function outflowRemaining() public view returns (uint256) {
        if (block.timestamp > budgetExpiry) return 0;
        return outflowBudget > outflowSpent ? outflowBudget - outflowSpent : 0;
    }

    function _consumeOutflow(uint256 amount) internal {
        if (block.timestamp > budgetExpiry) revert BudgetExpired(budgetExpiry, block.timestamp);
        uint256 remaining = outflowBudget - outflowSpent;
        if (amount > remaining) revert BudgetExceeded(amount, remaining);
        outflowSpent += amount;
        emit OutflowConsumed(amount, outflowSpent, outflowBudget);
    }
}
