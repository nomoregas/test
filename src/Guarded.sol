// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {CallEntry, LogEntry, SlotWrite, TransitionContext} from "./interfaces/IProperty.sol";
import {SubscriptionRegistry} from "./catalogue/SubscriptionRegistry.sol";

/// @title Guarded
/// @notice Runs a contract's safety rules inside the transaction, and either reverts on a violation
///         or records it, depending on the mode the contract chose.
///
/// @dev **This is ordinary Solidity and it needs nothing else to work.** No operators, no quorum, no
///      attestation, no cooperation from a sequencer or block builder. Put the modifier on a
///      function, and a violating call reverts on any EVM, today.
///
///      Gas Killer is orthogonal. The reason contracts do not already run checks like these is that
///      sweeping every market or holder on every call is too expensive, so the checks get pushed into
///      pre-deploy testing or a monitoring script that notices afterwards. Gas Killer makes that
///      compute cheap by running it off-chain and settling the result. It has no idea what the code
///      it accelerates is doing, and is not a party to the security of this contract.
abstract contract Guarded {
    /// @notice What happens when a rule is violated.
    enum GuardMode {
        /// @dev The call reverts. The violating state never persists. The default, and what anyone
        ///      protecting a live contract wants.
        Enforce,
        /// @dev The call succeeds and the violation is emitted as an event.
        ///
        ///      Two reasons this exists rather than being a footgun. Rolling a new rule out over a
        ///      live protocol reverting-first means discovering a false positive by breaking user
        ///      transactions; running it in Detect for a while surfaces the false-positive rate
        ///      against real traffic first. And a violation in Enforce mode leaves no on-chain trace
        ///      at all — the call reverted, so there is nothing to point at afterwards. Anything that
        ///      needs *evidence* a rule was broken (a claims process, an incident timeline, an
        ///      insurer) needs a mode that lets the violation land and records it.
        ///
        ///      It provides no protection. A contract in Detect mode is monitored, not guarded.
        Detect
    }

    SubscriptionRegistry public immutable guardRegistry;
    GuardMode public guardMode;

    error PropertyViolated(string propertyName, string reason);

    /// @notice A rule was violated and the call was allowed to proceed.
    /// @dev The on-chain evidence that Enforce mode cannot leave. Indexed so a monitor can filter by
    ///      rule without scanning every guarded call.
    event GuardViolation(string indexed propertyName, string reason, address caller, uint256 blockNumber);

    /// @notice The contract switched between reverting and recording.
    event GuardModeChanged(GuardMode from, GuardMode to);

    constructor(SubscriptionRegistry registry_, GuardMode mode_) {
        guardRegistry = registry_;
        guardMode = mode_;
    }

    /// @notice Check every rule this contract subscribes to, after the function body runs.
    /// @dev Runs afterwards so rules judge the state the call actually produced.
    modifier guarded() {
        _;
        _runGuards(new SlotWrite[](0), new CallEntry[](0), new LogEntry[](0));
    }

    /// @notice As `guarded`, but hands the rules the transition's declared effects too.
    /// @dev For rules that judge *what changed* or *what the transition did outwardly* rather than
    ///      the resulting state — a frozen slot, a per-call movement cap, an allowlisted call target,
    ///      a required event. A plain guarded call has no declared effect list, which is why the bare
    ///      modifier passes empty ones.
    function _guardedWith(SlotWrite[] memory writes, CallEntry[] memory calls, LogEntry[] memory logs) internal {
        _runGuards(writes, calls, logs);
    }

    /// @notice Evaluate the rules without reverting or recording. For monitors and tests.
    function checkGuards() external view returns (bool ok, string memory propertyName, string memory reason) {
        return
            guardRegistry.checkAll(address(this), _context(new SlotWrite[](0), new CallEntry[](0), new LogEntry[](0)));
    }

    /// @dev Mode changes are a security-relevant action, so the contract decides who may make them.
    ///      Left unrestricted here and expected to be overridden; a contract that forgets to has an
    ///      obvious hole rather than a subtle one.
    function _setGuardMode(GuardMode mode_) internal {
        emit GuardModeChanged(guardMode, mode_);
        guardMode = mode_;
    }

    function _runGuards(SlotWrite[] memory writes, CallEntry[] memory calls, LogEntry[] memory logs) private {
        (bool ok, string memory propertyName, string memory reason) =
            guardRegistry.checkAll(address(this), _context(writes, calls, logs));
        if (ok) return;

        if (guardMode == GuardMode.Enforce) revert PropertyViolated(propertyName, reason);
        emit GuardViolation(propertyName, reason, msg.sender, block.number);
    }

    function _context(SlotWrite[] memory writes, CallEntry[] memory calls, LogEntry[] memory logs)
        private
        view
        returns (TransitionContext memory)
    {
        return TransitionContext({
            target: address(this),
            transitionIndex: 0,
            intentIds: new bytes32[](0),
            writes: writes,
            calls: calls,
            logs: logs
        });
    }
}
