// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/// @notice One raw storage write inside an attested transition.
///
/// @dev Carries `oldValue` as well as `newValue`, which is what makes pre/post reasoning possible
///      at all. Phylax's assertions get pre-state from a second EVM fork (`ph.forkPreTx()`); a
///      property here has no such luxury — by the time it runs on-chain the pre-state is gone. So
///      the diff carries its own before-image, and `PreState` reconstructs the rest.
///
///      Settlement verifies `oldValue` against live storage before applying, so the diff is a
///      compare-and-swap rather than a blind write. Without that check an operator could simply lie
///      about the before-image and every pre/post property built on it would be fooled — and a
///      stale diff assembled against an older state would apply silently.
struct SlotWrite {
    bytes32 slot;
    bytes32 oldValue;
    bytes32 newValue;
}

/// @notice One external call a transition makes.
/// @dev Gas Killer's settlement format (`StateUpdateType[]` in `StateChangeHandlerLib`) applies
///      `sstore`, `call` **and** `log`, so a settlement's calls are part of the diff and a rule can
///      judge them. This is not a transaction trace: it is what the settlement itself does. For a
///      guarded contract that is the only thing changing state, so it is the equivalent object.
struct CallEntry {
    address target;
    uint256 value;
    bytes data;
}

/// @notice One event a transition emits.
/// @dev Unblocks the whole class of rule that reasons about emitted events — that a transfer was
///      announced, that an expected event is present, that no unexpected one is. Phylax reads these
///      from the transaction journal (`ph.getLogs`); here they come from the diff.
struct LogEntry {
    bytes32[] topics;
    bytes data;
}

/// @notice Everything a property needs in order to judge a proposed transition.
///
/// @dev Properties come in three flavours and this struct serves all of them:
///      - *state* properties read the target's storage through its own view functions;
///      - *diff* properties inspect `writes`, and can recover pre-state via `PreState`;
///      - *effect* properties inspect `calls` and `logs` — what the transition did outwardly.
///
///      The caller is responsible for evaluating a property against the **post-state**. `calls` and
///      `logs` are empty when a guarded function runs the rules directly, since a plain call has no
///      declared effect list; they are populated when judging a Gas Killer settlement, whose diff
///      carries them.
struct TransitionContext {
    address target;
    uint256 transitionIndex;
    bytes32[] intentIds;
    SlotWrite[] writes;
    CallEntry[] calls;
    LogEntry[] logs;
}

/// @notice A single named property of a contract, evaluated on every state transition.
/// @dev Properties are deliberately allowed to be expensive. They are normally evaluated
///      **off-chain** by operators who then refuse to sign a violating transition, so an
///      O(N) sweep over every holder costs the chain nothing. That is the whole point:
///      you get to enforce the check you could never afford to run on-chain.
interface IProperty {
    function name() external view returns (string memory);

    /// @return ok  true when the property holds
    /// @return reason human-readable explanation when it does not
    function check(TransitionContext calldata ctx) external view returns (bool ok, string memory reason);
}

/// @notice Implemented by a guarded contract to declare which storage slots are hers to change.
/// @dev This is the structural fix for the phantom-holder class of bug: a diff that writes
///      value to a slot the contract never declared is rejected outright, so an attacker
///      cannot escape a conservation sum by writing to an address that sum never visits.
interface IGuardedDomain {
    function isGuardedSlot(bytes32 slot) external view returns (bool);
}

/// @notice Verifies that an operator quorum attested to a transition digest.
/// @dev In production this wraps `GasKillerSDK.verifyAndUpdate`'s quorum check (aggregated
///      BLS against an EigenLayer IBLSSignatureChecker, or the aggregate Schnorr scheme).
///      Kept behind an interface so the guard layer is testable without EigenLayer.
interface IAttestor {
    function verify(bytes32 digest, bytes calldata attestation) external view returns (bool);
}
