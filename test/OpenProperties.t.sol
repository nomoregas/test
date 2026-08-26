// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IProperty, SlotWrite, TransitionContext} from "../src/interfaces/IProperty.sol";
import {PostOperationSolvency} from "../src/properties/PostOperationSolvency.sol";
import {ConstantProduct} from "../src/properties/ConstantProduct.sol";
import {ParticipantAllowlist} from "../src/properties/ParticipantAllowlist.sol";
import {PanicState} from "../src/properties/PanicState.sol";
import {OracleLiveness} from "../src/properties/OracleLiveness.sol";
import {OracleDeviation} from "../src/properties/OracleDeviation.sol";
import {FeeConsistency} from "../src/properties/FeeConsistency.sol";
import {ValueRangeGuard} from "../src/properties/ValueRangeGuard.sol";
import {SpecConformance} from "../src/properties/SpecConformance.sol";
import {MockAdopter} from "./mocks/MockAdopter.sol";

/// @notice Tests for the properties that were reachable in the parity audit but unbuilt.
contract OpenPropertiesTest is Test {
    MockAdopter adopter;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        adopter = new MockAdopter();
    }

    function _ctx(SlotWrite[] memory writes) internal view returns (TransitionContext memory) {
        return
            TransitionContext({
                target: address(adopter), transitionIndex: 0, intentIds: new bytes32[](0), writes: writes
            });
    }

    function _one(bytes32 slot, uint256 from, uint256 to) internal pure returns (SlotWrite[] memory w) {
        w = new SlotWrite[](1);
        w[0] = SlotWrite(slot, bytes32(from), bytes32(to));
    }

    function _check(IProperty p, SlotWrite[] memory w) internal view returns (bool, string memory) {
        return p.check(_ctx(w));
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    // -------------------------------------------------- PostOperationSolvency

    function test_solvency_allowsSolventOutcome() public {
        adopter.setFloor(100);
        adopter.setTouched(_one(alice));
        adopter.setHealth(alice, 150);
        PostOperationSolvency p = new PostOperationSolvency();
        (bool ok,) = _check(p, _one(adopter.accountHealthSlot(alice), 150, 120));
        assertTrue(ok);
    }

    function test_solvency_blocksLeavingAccountInsolvent() public {
        adopter.setFloor(100);
        adopter.setTouched(_one(alice));
        adopter.setHealth(alice, 150);
        PostOperationSolvency p = new PostOperationSolvency();
        (bool ok, string memory reason) = _check(p, _one(adopter.accountHealthSlot(alice), 150, 90));
        assertFalse(ok);
        assertEq(reason, "a solvent account was left insolvent");
    }

    /// @notice A liquidation operates on an already-underwater account and must be allowed through.
    /// @dev The branch that stops this property deadlocking the repair path — a flat "everyone must
    ///      be solvent" rule would refuse every liquidation by construction.
    function test_solvency_allowsLiquidationThatImproves() public {
        adopter.setFloor(100);
        adopter.setTouched(_one(alice));
        adopter.setHealth(alice, 50);
        PostOperationSolvency p = new PostOperationSolvency();
        (bool ok,) = _check(p, _one(adopter.accountHealthSlot(alice), 50, 80));
        assertTrue(ok, "a liquidation that improves an underwater account must pass");
    }

    function test_solvency_blocksDeepeningInsolvency() public {
        adopter.setFloor(100);
        adopter.setTouched(_one(alice));
        adopter.setHealth(alice, 50);
        PostOperationSolvency p = new PostOperationSolvency();
        (bool ok, string memory reason) = _check(p, _one(adopter.accountHealthSlot(alice), 50, 40));
        assertFalse(ok);
        assertEq(reason, "an insolvent account was made worse");
    }

    // -------------------------------------------------------- ConstantProduct

    function test_constantProduct_allowsFeeGrowth() public {
        adopter.setReserves(1000, 1000);
        ConstantProduct p = new ConstantProduct(0);
        SlotWrite[] memory w = new SlotWrite[](2);
        w[0] = SlotWrite(adopter.RESERVE0(), bytes32(uint256(1000)), bytes32(uint256(1100)));
        w[1] = SlotWrite(adopter.RESERVE1(), bytes32(uint256(1000)), bytes32(uint256(920)));
        (bool ok,) = _check(p, w); // k: 1e6 -> 1,012,000
        assertTrue(ok);
    }

    function test_constantProduct_blocksValueExtraction() public {
        adopter.setReserves(1000, 1000);
        ConstantProduct p = new ConstantProduct(0);
        SlotWrite[] memory w = new SlotWrite[](2);
        w[0] = SlotWrite(adopter.RESERVE0(), bytes32(uint256(1000)), bytes32(uint256(1100)));
        w[1] = SlotWrite(adopter.RESERVE1(), bytes32(uint256(1000)), bytes32(uint256(800)));
        (bool ok, string memory reason) = _check(p, w); // k: 1e6 -> 880,000
        assertFalse(ok);
        assertEq(reason, "reserve product fell beyond tolerance");
    }

    // --------------------------------------------------- ParticipantAllowlist

    function test_participants_allowsListedAccounts() public {
        address[] memory ps = new address[](2);
        ps[0] = alice;
        ps[1] = bob;
        adopter.setParticipants(ps);
        adopter.setAllowed(alice, true);
        adopter.setAllowed(bob, true);
        ParticipantAllowlist p = new ParticipantAllowlist();
        (bool ok,) = _check(p, new SlotWrite[](0));
        assertTrue(ok);
    }

    function test_participants_blocksUnlistedAccount() public {
        address[] memory ps = new address[](2);
        ps[0] = alice;
        ps[1] = bob;
        adopter.setParticipants(ps);
        adopter.setAllowed(alice, true);
        ParticipantAllowlist p = new ParticipantAllowlist();
        (bool ok, string memory reason) = _check(p, new SlotWrite[](0));
        assertFalse(ok);
        assertEq(reason, "a participant is not on the allowlist");
    }

    // -------------------------------------------------------------- PanicState

    function test_panic_allowsMovementWhenLive() public {
        bytes32[] memory prot = new bytes32[](1);
        prot[0] = adopter.RESERVE0();
        PanicState p = new PanicState(prot);
        adopter.setPaused(false);
        (bool ok,) = _check(p, _one(adopter.RESERVE0(), 1, 2));
        assertTrue(ok);
    }

    function test_panic_blocksMovementWhilePaused() public {
        bytes32[] memory prot = new bytes32[](1);
        prot[0] = adopter.RESERVE0();
        PanicState p = new PanicState(prot);
        adopter.setPaused(true);
        (bool ok, string memory reason) = _check(p, _one(adopter.RESERVE0(), 1, 2));
        assertFalse(ok);
        assertEq(reason, "protected state moved while paused");
    }

    /// @notice A transition cannot unpause itself at the start to escape the check.
    function test_panic_blocksUnpauseInSameTransition() public {
        bytes32[] memory prot = new bytes32[](1);
        prot[0] = adopter.RESERVE0();
        PanicState p = new PanicState(prot);
        adopter.setPaused(false); // ends live...

        SlotWrite[] memory w = new SlotWrite[](2);
        w[0] = SlotWrite(adopter.PAUSED(), bytes32(uint256(1)), bytes32(uint256(0))); // ...but began paused
        w[1] = SlotWrite(adopter.RESERVE0(), bytes32(uint256(1)), bytes32(uint256(2)));
        (bool ok,) = _check(p, w);
        assertFalse(ok, "either endpoint paused must block protected movement");
    }

    // ----------------------------------------------------------- OracleLiveness

    function test_oracleLiveness_allowsFreshFeed() public {
        vm.warp(10_000);
        adopter.setOracleUpdatedAt(9_950);
        OracleLiveness p = new OracleLiveness(100);
        (bool ok,) = _check(p, new SlotWrite[](0));
        assertTrue(ok);
    }

    function test_oracleLiveness_blocksStaleFeed() public {
        vm.warp(10_000);
        adopter.setOracleUpdatedAt(9_800);
        OracleLiveness p = new OracleLiveness(100);
        (bool ok, string memory reason) = _check(p, new SlotWrite[](0));
        assertFalse(ok);
        assertEq(reason, "oracle timestamp is staler than the bound");
    }

    function test_oracleLiveness_blocksNeverUpdated() public {
        vm.warp(10_000);
        OracleLiveness p = new OracleLiveness(100);
        (bool ok, string memory reason) = _check(p, new SlotWrite[](0));
        assertFalse(ok);
        assertEq(reason, "oracle has never been updated");
    }

    // ---------------------------------------------------------- OracleDeviation

    function test_oracleDeviation_allowsSmallGap() public {
        adopter.setPrices(1010, 1000);
        OracleDeviation p = new OracleDeviation(200); // 2%
        (bool ok,) = _check(p, new SlotWrite[](0));
        assertTrue(ok);
    }

    function test_oracleDeviation_blocksManipulatedSpot() public {
        adopter.setPrices(1500, 1000);
        OracleDeviation p = new OracleDeviation(200);
        (bool ok, string memory reason) = _check(p, new SlotWrite[](0));
        assertFalse(ok);
        assertEq(reason, "spot deviates from twap beyond the bound");
    }

    /// @notice The diff's own spot value is what gets judged, not the stale live read.
    function test_oracleDeviation_readsSpotThroughTheDiff() public {
        adopter.setPrices(1000, 1000);
        OracleDeviation p = new OracleDeviation(200);
        (bool ok,) = _check(p, _one(adopter.SPOT(), 1000, 1500));
        assertFalse(ok, "a diff that manipulates spot must be caught before it lands");
    }

    // ----------------------------------------------------------- FeeConsistency

    function test_feeConsistency_allowsCorrectAccrual() public {
        adopter.setFees(0, 0, 100); // 1%
        FeeConsistency p = new FeeConsistency();
        SlotWrite[] memory w = new SlotWrite[](2);
        w[0] = SlotWrite(adopter.FEE_BASE(), bytes32(uint256(0)), bytes32(uint256(10_000)));
        w[1] = SlotWrite(adopter.FEE_ACCRUED(), bytes32(uint256(0)), bytes32(uint256(100)));
        (bool ok,) = _check(p, w);
        assertTrue(ok);
    }

    function test_feeConsistency_blocksOverCollection() public {
        adopter.setFees(0, 0, 100);
        FeeConsistency p = new FeeConsistency();
        SlotWrite[] memory w = new SlotWrite[](2);
        w[0] = SlotWrite(adopter.FEE_BASE(), bytes32(uint256(0)), bytes32(uint256(10_000)));
        w[1] = SlotWrite(adopter.FEE_ACCRUED(), bytes32(uint256(0)), bytes32(uint256(500)));
        (bool ok, string memory reason) = _check(p, w);
        assertFalse(ok);
        assertEq(reason, "fee accrued does not match the declared rate");
    }

    // ---------------------------------------------------------- ValueRangeGuard

    function test_valueRange_allowsInRangeChange() public {
        ValueRangeGuard.Range[] memory r = new ValueRangeGuard.Range[](1);
        r[0] = ValueRangeGuard.Range(adopter.FEE_BASE(), 1, 1000);
        ValueRangeGuard p = new ValueRangeGuard(r);
        (bool ok,) = _check(p, _one(adopter.FEE_BASE(), 10, 500));
        assertTrue(ok);
    }

    function test_valueRange_blocksOutOfRangeChange() public {
        ValueRangeGuard.Range[] memory r = new ValueRangeGuard.Range[](1);
        r[0] = ValueRangeGuard.Range(adopter.FEE_BASE(), 1, 1000);
        ValueRangeGuard p = new ValueRangeGuard(r);
        (bool ok, string memory reason) = _check(p, _one(adopter.FEE_BASE(), 10, 5000));
        assertFalse(ok);
        assertEq(reason, "a configuration slot left its permitted range");
    }

    /// @notice Zeroing a timelock delay is the canonical compromised-governance move.
    function test_valueRange_blocksZeroedDelay() public {
        ValueRangeGuard.Range[] memory r = new ValueRangeGuard.Range[](1);
        r[0] = ValueRangeGuard.Range(adopter.FEE_BASE(), 86_400, 604_800);
        ValueRangeGuard p = new ValueRangeGuard(r);
        (bool ok,) = _check(p, _one(adopter.FEE_BASE(), 172_800, 0));
        assertFalse(ok);
    }

    // ---------------------------------------------------------- SpecConformance

    function test_specConformance_acceptsMatchingDiff() public {
        SlotWrite[] memory spec = new SlotWrite[](2);
        spec[0] = SlotWrite(adopter.RESERVE0(), bytes32(uint256(1)), bytes32(uint256(2)));
        spec[1] = SlotWrite(adopter.RESERVE1(), bytes32(uint256(3)), bytes32(uint256(4)));
        adopter.setPreview(spec);

        SpecConformance p = new SpecConformance();
        (bool ok,) = _check(p, spec);
        assertTrue(ok);
    }

    /// @notice Enumeration order is not part of the transition.
    function test_specConformance_isOrderIndependent() public {
        SlotWrite[] memory spec = new SlotWrite[](2);
        spec[0] = SlotWrite(adopter.RESERVE0(), bytes32(uint256(1)), bytes32(uint256(2)));
        spec[1] = SlotWrite(adopter.RESERVE1(), bytes32(uint256(3)), bytes32(uint256(4)));
        adopter.setPreview(spec);

        SlotWrite[] memory reordered = new SlotWrite[](2);
        reordered[0] = spec[1];
        reordered[1] = spec[0];

        SpecConformance p = new SpecConformance();
        (bool ok,) = _check(p, reordered);
        assertTrue(ok);
    }

    function test_specConformance_blocksSmuggledWrite() public {
        SlotWrite[] memory spec = new SlotWrite[](1);
        spec[0] = SlotWrite(adopter.RESERVE0(), bytes32(uint256(1)), bytes32(uint256(2)));
        adopter.setPreview(spec);

        SlotWrite[] memory smuggled = new SlotWrite[](2);
        smuggled[0] = spec[0];
        smuggled[1] = SlotWrite(adopter.RESERVE1(), bytes32(uint256(0)), bytes32(uint256(1e18)));

        SpecConformance p = new SpecConformance();
        (bool ok, string memory reason) = _check(p, smuggled);
        assertFalse(ok);
        assertEq(reason, "diff has a different number of writes than the spec");
    }

    function test_specConformance_blocksAlteredValue() public {
        SlotWrite[] memory spec = new SlotWrite[](1);
        spec[0] = SlotWrite(adopter.RESERVE0(), bytes32(uint256(1)), bytes32(uint256(2)));
        adopter.setPreview(spec);

        SpecConformance p = new SpecConformance();
        (bool ok, string memory reason) = _check(p, _one(adopter.RESERVE0(), 1, 999));
        assertFalse(ok);
        assertEq(reason, "diff contains a write the spec does not produce");
    }
}
