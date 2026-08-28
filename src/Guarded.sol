// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, SlotWrite, TransitionContext} from "./interfaces/IProperty.sol";
import {SubscriptionRegistry} from "./catalogue/SubscriptionRegistry.sol";

/// @title Guarded
/// @notice Runs a contract's safety rules inside the transaction and reverts if any of them break.
///
/// @dev **This is ordinary Solidity and it needs nothing else to work.** No operators, no quorum, no
///      attestation, no cooperation from a sequencer or block builder. Put the modifier on a
///      function, and a violating call reverts on any EVM, today.
///
///      Gas Killer is orthogonal. The reason contracts do not already run checks like these is that
///      sweeping every holder on every call is too expensive, so the checks get pushed into
///      pre-deploy testing or a monitoring script that notices afterwards. Gas Killer makes that
///      compute cheap by running it off-chain and settling the result. It has no idea what the code
///      it accelerates is doing, and is not a party to the security of this contract.
///
///      So: the guard provides the security, Gas Killer removes the reason not to use it.
abstract contract Guarded {
    SubscriptionRegistry public immutable guardRegistry;

    error PropertyViolated(string propertyName, string reason);

    constructor(SubscriptionRegistry registry_) {
        guardRegistry = registry_;
    }

    /// @notice Check every rule this contract subscribes to, after the function body runs.
    /// @dev Runs afterwards so rules judge the state the call actually produced. A violation reverts
    ///      the whole call, so the offending state never persists.
    modifier guarded() {
        _;
        _runGuards(new SlotWrite[](0));
    }

    /// @notice As `guarded`, but also hands the rules the specific changes the call made.
    /// @dev Only needed for rules that judge *what changed* rather than the resulting state —
    ///      "this slot must not be written", "this value may not move more than X". Rules that read
    ///      the contract's own state work fine with the plain `guarded` modifier.
    function _guardedWith(SlotWrite[] memory writes) internal view {
        _runGuards(writes);
    }

    /// @notice Evaluate the rules without reverting. For monitoring and tests.
    function checkGuards() external view returns (bool ok, string memory propertyName, string memory reason) {
        return guardRegistry.checkAll(address(this), _context(new SlotWrite[](0)));
    }

    function _runGuards(SlotWrite[] memory writes) private view {
        (bool ok, string memory propertyName, string memory reason) =
            guardRegistry.checkAll(address(this), _context(writes));
        if (!ok) revert PropertyViolated(propertyName, reason);
    }

    function _context(SlotWrite[] memory writes) private view returns (TransitionContext memory) {
        return
            TransitionContext({target: address(this), transitionIndex: 0, intentIds: new bytes32[](0), writes: writes});
    }
}
