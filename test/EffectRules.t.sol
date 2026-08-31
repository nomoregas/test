// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IProperty, TransitionContext, SlotWrite, CallEntry, LogEntry} from "../src/interfaces/IProperty.sol";
import {CallAllowlist, RequiredEvent, NoUnexpectedEvents, CallPolicy} from "../src/properties/effects/EffectRules.sol";
import {CatalogueFixture} from "./helpers/CatalogueFixture.sol";

/// @notice Rules that judge what a transition did outwardly, not just the state it left.
/// @dev Unblocked by carrying the diff's `call` and `log` entries. Gas Killer's settlement format
///      applies `sstore`, `call` and `log`, so a settlement's outward effects are part of the diff.
contract EffectRulesTest is Test, CatalogueFixture {
    address adopter = address(0xA0);
    address allowedA = address(0xAA);
    address allowedB = address(0xBB);
    address stranger = address(0xDEAD);

    bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");
    bytes32 constant ROGUE_TOPIC = keccak256("Rogue(bytes)");

    function setUp() public {
        _deployCatalogue();
        adminVerifier.setAdmin(adopter, address(this), true);
    }

    function _install(IProperty p, string memory n, bytes memory cfg) internal {
        cat.list(p, n, 1, true);
        subs.subscribe(adopter, p, cfg);
    }

    function _ctx(SlotWrite[] memory writes, CallEntry[] memory calls, LogEntry[] memory logs)
        internal
        view
        returns (TransitionContext memory)
    {
        return TransitionContext({
            target: adopter, transitionIndex: 0, intentIds: new bytes32[](0), writes: writes, calls: calls, logs: logs
        });
    }

    function _call(address t, uint256 v) internal pure returns (CallEntry[] memory c) {
        c = new CallEntry[](1);
        c[0] = CallEntry({target: t, value: v, data: ""});
    }

    function _log(bytes32 topic) internal pure returns (LogEntry[] memory l) {
        l = new LogEntry[](1);
        bytes32[] memory t = new bytes32[](1);
        t[0] = topic;
        l[0] = LogEntry({topics: t, data: ""});
    }

    function _oneWrite() internal pure returns (SlotWrite[] memory w) {
        w = new SlotWrite[](1);
        w[0] = SlotWrite(bytes32(uint256(1)), bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function _policy(uint256 perCall, uint256 total) internal view returns (bytes memory) {
        address[] memory targets = new address[](2);
        targets[0] = allowedA;
        targets[1] = allowedB;
        return abi.encode(CallPolicy({allowedTargets: targets, maxValuePerCall: perCall, maxTotalValue: total}));
    }

    // ---------------------------------------------------------- CallAllowlist

    function test_allowedCallPasses() public {
        CallAllowlist p = new CallAllowlist(subs);
        _install(p, "CallAllowlist", _policy(1 ether, 2 ether));
        (bool ok,) = p.check(_ctx(new SlotWrite[](0), _call(allowedA, 0.5 ether), new LogEntry[](0)));
        assertTrue(ok);
    }

    /// @notice The rule that closes the class: a settlement that can call anything can move anything.
    function test_unlistedCallTargetIsRefused() public {
        CallAllowlist p = new CallAllowlist(subs);
        _install(p, "CallAllowlist", _policy(1 ether, 2 ether));
        (bool ok, string memory reason) = p.check(_ctx(new SlotWrite[](0), _call(stranger, 0), new LogEntry[](0)));
        assertFalse(ok);
        assertEq(reason, "transition calls an address outside the allowlist");
    }

    function test_perCallValueCapIsEnforced() public {
        CallAllowlist p = new CallAllowlist(subs);
        _install(p, "CallAllowlist", _policy(1 ether, 100 ether));
        (bool ok, string memory reason) = p.check(_ctx(new SlotWrite[](0), _call(allowedA, 2 ether), new LogEntry[](0)));
        assertFalse(ok);
        assertEq(reason, "a call sends more value than permitted");
    }

    /// @notice Many small calls under the per-call cap still hit the total.
    function test_totalValueCapCatchesSplitCalls() public {
        CallAllowlist p = new CallAllowlist(subs);
        _install(p, "CallAllowlist", _policy(1 ether, 1.5 ether));

        CallEntry[] memory calls = new CallEntry[](2);
        calls[0] = CallEntry({target: allowedA, value: 1 ether, data: ""});
        calls[1] = CallEntry({target: allowedB, value: 1 ether, data: ""});

        (bool ok, string memory reason) = p.check(_ctx(new SlotWrite[](0), calls, new LogEntry[](0)));
        assertFalse(ok);
        assertEq(reason, "transition sends more value in total than permitted");
    }

    function test_noCallsIsFine() public {
        CallAllowlist p = new CallAllowlist(subs);
        _install(p, "CallAllowlist", _policy(1 ether, 1 ether));
        (bool ok,) = p.check(_ctx(_oneWrite(), new CallEntry[](0), new LogEntry[](0)));
        assertTrue(ok);
    }

    // ----------------------------------------------------------- RequiredEvent

    function test_stateChangeWithTheEventPasses() public {
        RequiredEvent p = new RequiredEvent(subs);
        _install(p, "RequiredEvent", abi.encode(TRANSFER_TOPIC));
        (bool ok,) = p.check(_ctx(_oneWrite(), new CallEntry[](0), _log(TRANSFER_TOPIC)));
        assertTrue(ok);
    }

    /// @notice A silent state change is how an incident goes unnoticed for hours.
    function test_silentStateChangeIsRefused() public {
        RequiredEvent p = new RequiredEvent(subs);
        _install(p, "RequiredEvent", abi.encode(TRANSFER_TOPIC));
        (bool ok, string memory reason) = p.check(_ctx(_oneWrite(), new CallEntry[](0), new LogEntry[](0)));
        assertFalse(ok);
        assertEq(reason, "state changed without emitting the required event");
    }

    function test_wrongEventDoesNotSatisfyTheRequirement() public {
        RequiredEvent p = new RequiredEvent(subs);
        _install(p, "RequiredEvent", abi.encode(TRANSFER_TOPIC));
        (bool ok,) = p.check(_ctx(_oneWrite(), new CallEntry[](0), _log(APPROVAL_TOPIC)));
        assertFalse(ok);
    }

    /// @notice A transition that writes nothing has nothing to announce.
    function test_noWritesIsExempt() public {
        RequiredEvent p = new RequiredEvent(subs);
        _install(p, "RequiredEvent", abi.encode(TRANSFER_TOPIC));
        (bool ok,) = p.check(_ctx(new SlotWrite[](0), new CallEntry[](0), new LogEntry[](0)));
        assertTrue(ok);
    }

    // ------------------------------------------------------ NoUnexpectedEvents

    function test_declaredEventsPass() public {
        NoUnexpectedEvents p = new NoUnexpectedEvents(subs);
        bytes32[] memory known = new bytes32[](2);
        known[0] = TRANSFER_TOPIC;
        known[1] = APPROVAL_TOPIC;
        _install(p, "NoUnexpectedEvents", abi.encode(known));

        (bool ok,) = p.check(_ctx(_oneWrite(), new CallEntry[](0), _log(APPROVAL_TOPIC)));
        assertTrue(ok);
    }

    /// @notice An unrecognised topic means something ran the author did not account for.
    function test_undeclaredEventIsRefused() public {
        NoUnexpectedEvents p = new NoUnexpectedEvents(subs);
        bytes32[] memory known = new bytes32[](1);
        known[0] = TRANSFER_TOPIC;
        _install(p, "NoUnexpectedEvents", abi.encode(known));

        (bool ok, string memory reason) = p.check(_ctx(_oneWrite(), new CallEntry[](0), _log(ROGUE_TOPIC)));
        assertFalse(ok);
        assertEq(reason, "transition emits an event the contract does not declare");
    }

    function test_anonymousEventIsRefused() public {
        NoUnexpectedEvents p = new NoUnexpectedEvents(subs);
        bytes32[] memory known = new bytes32[](1);
        known[0] = TRANSFER_TOPIC;
        _install(p, "NoUnexpectedEvents", abi.encode(known));

        LogEntry[] memory logs = new LogEntry[](1);
        logs[0] = LogEntry({topics: new bytes32[](0), data: hex"beef"});

        (bool ok, string memory reason) = p.check(_ctx(_oneWrite(), new CallEntry[](0), logs));
        assertFalse(ok);
        assertEq(reason, "transition emits an anonymous event");
    }

    // --------------------------------------------------------------- plumbing

    function test_unconfiguredEffectRuleFailsClosed() public {
        CallAllowlist p = new CallAllowlist(subs);
        cat.list(p, "CallAllowlist", 1, true);
        // deliberately not subscribed
        (bool ok, string memory reason) = p.check(_ctx(new SlotWrite[](0), _call(allowedA, 0), new LogEntry[](0)));
        assertFalse(ok);
        assertEq(reason, "property is not configured for this adopter");
    }
}
