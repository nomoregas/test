// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IProperty, SlotWrite, TransitionContext, CallEntry, LogEntry} from "../src/interfaces/IProperty.sol";
import {PreState} from "../src/PreState.sol";
import {SlotProtection} from "../src/properties/SlotProtection.sol";
import {ValueConservation} from "../src/properties/ValueConservation.sol";
import {Monotonic} from "../src/properties/Monotonic.sol";
import {DeltaBound, Bound} from "../src/properties/DeltaBound.sol";
import {CatalogueFixture} from "./helpers/CatalogueFixture.sol";
import {SharePriceFloor} from "../src/properties/SharePriceFloor.sol";
import {AssetFlowConsistency} from "../src/properties/AssetFlowConsistency.sol";
import {ImplementationLock} from "../src/properties/ImplementationLock.sol";
import {Composite} from "../src/properties/Composite.sol";
import {SlotDomain} from "../src/properties/SlotDomain.sol";
import {MockAdopter} from "./mocks/MockAdopter.sol";

/// @notice Tests for the properties ported from Phylax's assertion library.
/// @dev Each property gets a holds-case and a violates-case, evaluated the way an operator would:
///      against the post-state and the proposed diff together.
contract PortedPropertiesTest is Test, CatalogueFixture {
    MockAdopter vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    bytes32 constant SLOT_A = bytes32(uint256(0xAA));
    bytes32 constant SLOT_B = bytes32(uint256(0xBB));

    function setUp() public {
        _deployCatalogue();
        vault = new MockAdopter();
    }

    // ------------------------------------------------------------------ helpers

    function _ctx(SlotWrite[] memory writes) internal view returns (TransitionContext memory) {
        return TransitionContext({
            target: address(vault),
            transitionIndex: 0,
            intentIds: new bytes32[](0),
            writes: writes,
            calls: new CallEntry[](0),
            logs: new LogEntry[](0)
        });
    }

    function _one(bytes32 slot, uint256 from, uint256 to) internal pure returns (SlotWrite[] memory w) {
        w = new SlotWrite[](1);
        w[0] = SlotWrite(slot, bytes32(from), bytes32(to));
    }

    function _slots(bytes32 a) internal pure returns (bytes32[] memory s) {
        s = new bytes32[](1);
        s[0] = a;
    }

    function _check(IProperty p, SlotWrite[] memory writes) internal view returns (bool ok, string memory reason) {
        return p.check(_ctx(writes));
    }

    /// @dev The shared-catalogue pattern: one deployment, per-adopter config. Each helper lists the
    ///      property and subscribes the vault, which is what an integrator does once via
    ///      `SubscriptionRegistry.subscribe`.
    function _slotProtection(bytes32[] memory frozen) internal returns (SlotProtection p) {
        p = new SlotProtection(subs);
        _listAndSubscribe(p, "SlotProtection", address(vault), abi.encode(frozen));
    }

    function _monotonic(bytes32[] memory slots) internal returns (Monotonic p) {
        p = new Monotonic(subs);
        _listAndSubscribe(p, "Monotonic", address(vault), abi.encode(slots));
    }

    function _valueConservation(bytes32[] memory slots) internal returns (ValueConservation p) {
        p = new ValueConservation(subs);
        _listAndSubscribe(p, "ValueConservation", address(vault), abi.encode(slots));
    }

    function _deltaBound(Bound[] memory bounds) internal returns (DeltaBound p) {
        p = new DeltaBound(subs);
        _listAndSubscribe(p, "DeltaBound", address(vault), abi.encode(bounds));
    }

    // ------------------------------------------------------- SlotProtection

    function test_slotProtection_allowsUntouchedSlots() public {
        SlotProtection p = _slotProtection(_slots(SLOT_A));
        (bool ok,) = _check(p, _one(SLOT_B, 1, 2));
        assertTrue(ok);
    }

    function test_slotProtection_blocksAnyWrite() public {
        SlotProtection p = _slotProtection(_slots(SLOT_A));
        (bool ok, string memory reason) = _check(p, _one(SLOT_A, 1, 2));
        assertFalse(ok);
        assertEq(reason, "transition writes a frozen slot");
    }

    /// @notice A write that stores the same value is still a violation.
    /// @dev Matches Phylax's conservative reading of `forbidChangeForSlots`: for a slot that is
    ///      supposed to be frozen, something reaching for it is the signal, not the delta.
    function test_slotProtection_blocksNoOpWrite() public {
        SlotProtection p = _slotProtection(_slots(SLOT_A));
        (bool ok,) = _check(p, _one(SLOT_A, 7, 7));
        assertFalse(ok, "a no-op write to a frozen slot must still be flagged");
    }

    // ---------------------------------------------------- ValueConservation

    function test_valueConservation_allowsRedistribution() public {
        bytes32[] memory s = new bytes32[](2);
        s[0] = SLOT_A;
        s[1] = SLOT_B;
        ValueConservation p = _valueConservation(s);

        SlotWrite[] memory w = new SlotWrite[](2);
        w[0] = SlotWrite(SLOT_A, bytes32(uint256(100)), bytes32(uint256(40)));
        w[1] = SlotWrite(SLOT_B, bytes32(uint256(0)), bytes32(uint256(60)));

        (bool ok,) = _check(p, w);
        assertTrue(ok, "moving value inside the set must be allowed");
    }

    function test_valueConservation_blocksNetChange() public {
        bytes32[] memory s = new bytes32[](2);
        s[0] = SLOT_A;
        s[1] = SLOT_B;
        ValueConservation p = _valueConservation(s);

        SlotWrite[] memory w = new SlotWrite[](2);
        w[0] = SlotWrite(SLOT_A, bytes32(uint256(100)), bytes32(uint256(40)));
        w[1] = SlotWrite(SLOT_B, bytes32(uint256(0)), bytes32(uint256(61)));

        (bool ok, string memory reason) = _check(p, w);
        assertFalse(ok);
        assertEq(reason, "declared slot set did not conserve its total");
    }

    // ------------------------------------------------------------- Monotonic

    function test_monotonic_allowsIncrease() public {
        Monotonic p = _monotonic(_slots(SLOT_A));
        (bool ok,) = _check(p, _one(SLOT_A, 5, 9));
        assertTrue(ok);
    }

    function test_monotonic_blocksDecrease() public {
        Monotonic p = _monotonic(_slots(SLOT_A));
        (bool ok, string memory reason) = _check(p, _one(SLOT_A, 9, 5));
        assertFalse(ok);
        assertEq(reason, "a monotonic slot decreased");
    }

    /// @notice Endpoints are first-old to last-new, so an intermediate dip is not a violation.
    /// @dev Phylax makes the same choice: intermediate snapshots describe states that never
    ///      existed at a transition boundary.
    function test_monotonic_ignoresIntermediateDip() public {
        Monotonic p = _monotonic(_slots(SLOT_A));
        SlotWrite[] memory w = new SlotWrite[](2);
        w[0] = SlotWrite(SLOT_A, bytes32(uint256(5)), bytes32(uint256(1)));
        w[1] = SlotWrite(SLOT_A, bytes32(uint256(1)), bytes32(uint256(7)));
        (bool ok,) = _check(p, w);
        assertTrue(ok, "endpoints 5 -> 7 hold even though the diff dipped through 1");
    }

    // ------------------------------------------------------------ DeltaBound

    function test_deltaBound_allowsWithinBound() public {
        Bound[] memory b = new Bound[](1);
        b[0] = Bound(SLOT_A, 100);
        DeltaBound p = _deltaBound(b);
        (bool ok,) = _check(p, _one(SLOT_A, 0, 100));
        assertTrue(ok);
    }

    function test_deltaBound_blocksBeyondBound() public {
        Bound[] memory b = new Bound[](1);
        b[0] = Bound(SLOT_A, 100);
        DeltaBound p = _deltaBound(b);
        (bool ok, string memory reason) = _check(p, _one(SLOT_A, 0, 101));
        assertFalse(ok);
        assertEq(reason, "a slot moved more than its per-transition bound");
    }

    function test_deltaBound_boundsDecreasesToo() public {
        Bound[] memory b = new Bound[](1);
        b[0] = Bound(SLOT_A, 10);
        DeltaBound p = _deltaBound(b);
        (bool ok,) = _check(p, _one(SLOT_A, 100, 50));
        assertFalse(ok, "a large withdrawal is as bounded as a large mint");
    }

    // -------------------------------------------------------- SharePriceFloor

    /// @dev Give the vault a real share price to reason about: 100 assets, 100 shares.
    function _seedVault() internal {
        vault.setVault(100, 100);
    }

    function test_sharePriceFloor_allowsYieldAccrual() public {
        _seedVault();
        SharePriceFloor p = new SharePriceFloor(0);
        // Assets rise, supply flat: price up. Permitted.
        (bool ok,) = _check(p, _one(vault.totalAssetsSlot(), 100, 150));
        assertTrue(ok);
    }

    function test_sharePriceFloor_blocksDilution() public {
        _seedVault();
        SharePriceFloor p = new SharePriceFloor(0);
        // Supply rises with no new assets: every remaining holder is diluted.
        (bool ok, string memory reason) = _check(p, _one(vault.totalSupplySlot(), 100, 200));
        assertFalse(ok);
        assertEq(reason, "assets per share fell beyond tolerance");
    }

    function test_sharePriceFloor_toleranceAdmitsSmallFeeAccrual() public {
        _seedVault();
        SharePriceFloor p = new SharePriceFloor(200); // 2%
        // 1% drop in assets, supply flat: inside tolerance.
        (bool ok,) = _check(p, _one(vault.totalAssetsSlot(), 100, 99));
        assertTrue(ok);
    }

    function test_sharePriceFloor_skipsEmptyVault() public {
        SharePriceFloor p = new SharePriceFloor(0);
        // No deposits: supply is zero at both endpoints, so there is no holder price to protect.
        (bool ok,) = _check(p, _one(vault.totalAssetsSlot(), 0, 50));
        assertTrue(ok);
    }

    // --------------------------------------------------- AssetFlowConsistency

    function test_assetFlow_agreesWithDeclaredDeposit() public {
        AssetFlowConsistency p = new AssetFlowConsistency();
        vault.setVault(100, 100);
        vault.setDeclaredFlow(100); // the vault says this transition brings in 100

        (bool ok,) = _check(p, _one(vault.totalAssetsSlot(), 0, 100));
        assertTrue(ok);
    }

    function test_assetFlow_blocksDiffThatDisagreesWithIntent() public {
        AssetFlowConsistency p = new AssetFlowConsistency();
        vault.setVault(500, 500);
        vault.setDeclaredFlow(100); // says 100...

        (bool ok, string memory reason) = _check(p, _one(vault.totalAssetsSlot(), 0, 500)); // ...moves 500
        assertFalse(ok);
        assertEq(reason, "totalAssets delta disagrees with declared net flow");
    }

    function test_assetFlow_blocksSharesCreditedToZeroAddress() public {
        AssetFlowConsistency p = new AssetFlowConsistency();
        vault.setVault(100, 100);
        vault.setDeclaredFlow(0);
        vault.setZeroShares(1);

        (bool ok, string memory reason) = _check(p, new SlotWrite[](0));
        assertFalse(ok);
        assertEq(reason, "zero address holds shares");
    }

    // ---------------------------------------------------- ImplementationLock

    function test_implementationLock_allowsUntouched() public {
        ImplementationLock p = new ImplementationLock(bytes32(0), new bytes32[](0));
        (bool ok,) = _check(p, _one(SLOT_A, 1, 2));
        assertTrue(ok);
    }

    function test_implementationLock_blocksUnapprovedUpgrade() public {
        ImplementationLock p = new ImplementationLock(bytes32(0), new bytes32[](0));
        (bool ok, string memory reason) =
            _check(p, _one(p.EIP1967_IMPLEMENTATION(), uint256(uint160(address(1))), uint256(uint160(address(2)))));
        assertFalse(ok);
        assertEq(reason, "unapproved proxy implementation change");
    }

    function test_implementationLock_allowsApprovedUpgrade() public {
        bytes32[] memory approved = new bytes32[](1);
        approved[0] = bytes32(uint256(uint160(address(0xBEEF))));
        ImplementationLock p = new ImplementationLock(bytes32(0), approved);

        (bool ok,) =
            _check(p, _one(p.EIP1967_IMPLEMENTATION(), uint256(uint160(address(1))), uint256(uint160(address(0xBEEF)))));
        assertTrue(ok, "the planned upgrade target must be allowed through");
    }

    function test_implementationLock_watchesOwnerSlotWhenSet() public {
        ImplementationLock p = new ImplementationLock(SLOT_A, new bytes32[](0));
        (bool ok, string memory reason) = _check(p, _one(SLOT_A, 1, 2));
        assertFalse(ok);
        assertEq(reason, "unapproved owner change");
    }

    // -------------------------------------------------------------- Composite

    /// @notice Under AND, one member holding lets the transition through.
    /// @dev This is the case a set of separately registered properties structurally cannot express:
    ///      the registry blocks on the first violation, so separate entries can only ever OR.
    function test_composite_andRequiresEveryMemberViolated() public {
        IProperty[] memory members = new IProperty[](2);
        members[0] = _monotonic(_slots(SLOT_A)); // violated by a decrease
        members[1] = _slotProtection(_slots(SLOT_B)); // untouched, so it holds

        Composite p = new Composite("GatedDrain", Composite.Operator.And, members);
        (bool ok,) = _check(p, _one(SLOT_A, 9, 5));
        assertTrue(ok, "AND must not block when a member holds");
    }

    function test_composite_andBlocksWhenAllMembersViolated() public {
        IProperty[] memory members = new IProperty[](2);
        members[0] = _monotonic(_slots(SLOT_A));
        members[1] = _slotProtection(_slots(SLOT_A));

        Composite p = new Composite("GatedDrain", Composite.Operator.And, members);
        (bool ok,) = _check(p, _one(SLOT_A, 9, 5));
        assertFalse(ok, "AND blocks only when every member corroborates");
    }

    function test_composite_orBlocksOnAnyMember() public {
        IProperty[] memory members = new IProperty[](2);
        members[0] = _monotonic(_slots(SLOT_A));
        members[1] = _slotProtection(_slots(SLOT_B));

        Composite p = new Composite("AnyDamage", Composite.Operator.Or, members);
        (bool ok,) = _check(p, _one(SLOT_A, 9, 5));
        assertFalse(ok, "OR blocks as soon as one member is violated");
    }

    function test_composite_rejectsEmptyMemberSet() public {
        vm.expectRevert(Composite.NoMembers.selector);
        new Composite("Empty", Composite.Operator.Or, new IProperty[](0));
    }
}
