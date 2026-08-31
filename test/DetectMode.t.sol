// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Guarded} from "../src/Guarded.sol";
import {Vault} from "../src/examples/Vault.sol";
import {Conservation} from "../src/properties/Conservation.sol";
import {IProperty} from "../src/interfaces/IProperty.sol";
import {CatalogueFixture} from "./helpers/CatalogueFixture.sol";

/// @notice Detect mode: the violation lands, and leaves evidence.
///
/// @dev Two things this is for. Rolling a new rule out over a live protocol in Enforce mode means
///      discovering a false positive by breaking user transactions; Detect measures the
///      false-positive rate against real traffic first. And a violation in Enforce mode leaves no
///      on-chain trace at all — the call reverted — so anything needing *evidence* a rule was broken
///      has nothing to point at.
///
///      It provides no protection, and the tests say so explicitly rather than leaving it implied.
contract DetectModeTest is Test, CatalogueFixture {
    Vault vault;

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    event GuardViolation(string indexed propertyName, string reason, address caller, uint256 blockNumber);
    event GuardModeChanged(Guarded.GuardMode from, Guarded.GuardMode to);

    function setUp() public {
        _deployCatalogue();
        vault = new Vault(subs, 10_000, Guarded.GuardMode.Detect);
        adminVerifier.setAdmin(address(vault), address(this), true);

        IProperty p = new Conservation();
        cat.list(p, "Conservation", 1, false);
        subs.subscribe(address(vault), p, "");
    }

    function test_normalCallsAreUnaffected() public {
        vm.prank(alice);
        vault.deposit(100);
        assertEq(vault.shares(alice), 100);
    }

    /// @notice The violation is emitted and the call still succeeds.
    function test_violationIsRecordedNotReverted() public {
        vm.prank(alice);
        vault.deposit(100);

        vm.expectEmit(true, false, false, true, address(vault));
        emit GuardViolation("Conservation", "sum of parts != declared total", address(this), block.number);
        vault.buggyMint(attacker, 1_000);

        assertEq(vault.shares(attacker), 1_000, "detect mode does not protect; that is the point");
    }

    /// @notice The evidence Enforce mode cannot produce.
    /// @dev A claims process, an incident timeline or an insurer needs a record that a rule broke.
    ///      In Enforce mode the transaction reverted, so there is nothing on-chain to cite.
    function test_detectLeavesEvidenceThatEnforceCannot() public {
        vm.prank(alice);
        vault.deposit(100);

        vm.recordLogs();
        vault.buggyMint(attacker, 1_000);
        assertEq(vm.getRecordedLogs().length > 0, true, "a violation must be observable");

        // Same contract, switched to Enforce: the call reverts and emits nothing at all.
        vault.setGuardMode(Guarded.GuardMode.Enforce);
        vm.expectRevert(
            abi.encodeWithSelector(Guarded.PropertyViolated.selector, "Conservation", "sum of parts != declared total")
        );
        vault.buggyMint(attacker, 1);
    }

    function test_switchingToEnforceStartsBlocking() public {
        vm.prank(alice);
        vault.deposit(100);

        vault.buggyMint(attacker, 500); // recorded, allowed
        assertEq(vault.shares(attacker), 500);

        vm.expectEmit(false, false, false, true, address(vault));
        emit GuardModeChanged(Guarded.GuardMode.Detect, Guarded.GuardMode.Enforce);
        vault.setGuardMode(Guarded.GuardMode.Enforce);

        vm.expectRevert();
        vault.buggyMint(attacker, 500);
        assertEq(vault.shares(attacker), 500, "nothing further landed");
    }

    /// @notice A healthy call in Detect mode emits nothing, so the log is a real signal.
    function test_healthyCallsEmitNoViolation() public {
        vm.prank(alice);
        vm.recordLogs();
        vault.deposit(100);
        // deposit itself emits nothing in this example, so any log would be a violation record.
        assertEq(vm.getRecordedLogs().length, 0);
    }
}
