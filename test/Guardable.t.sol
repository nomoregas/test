// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Guardable} from "../src/subscribe/Guardable.sol";
import {LegacyVault} from "../src/subscribe/examples/LegacyVault.sol";
import {PropertyRegistry} from "../src/PropertyRegistry.sol";
import {TransitionContext, SlotWrite} from "../src/interfaces/IProperty.sol";
import {Conservation} from "../src/properties/Conservation.sol";
import {Solvency} from "../src/properties/Solvency.sol";
import {MockAttestor} from "./mocks/MockAttestor.sol";

/// @notice The additive-adoption path: an existing synchronous contract protected by annotation.
contract GuardableTest is Test {
    MockAttestor attestor;
    LegacyVault vault;
    PropertyRegistry registry;

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        attestor = new MockAttestor();
        vault = new LegacyVault(attestor);
        registry = new PropertyRegistry(address(this));
        registry.add(new Conservation());
        registry.add(new Solvency());

        vm.warp(1_000);
        _refresh(1, 1_000 ether, 2_000);

        vm.prank(alice);
        vault.deposit(500 ether);
    }

    function _refresh(uint256 epoch, uint256 budget, uint256 expiry) internal {
        bytes32 d = vault.budgetDigest(epoch, budget, expiry);
        attestor.attest(d);
        vault.refreshBudget(epoch, budget, expiry, abi.encode(d));
    }

    /// @dev What an operator actually does before refreshing: evaluate every property against the
    ///      live contract with no diff in flight. This is the one place `checkNow()`-shaped
    ///      evaluation is the correct oracle, because there is no proposed diff to judge.
    function _propertiesHold() internal view returns (bool ok) {
        TransitionContext memory ctx = TransitionContext({
            target: address(vault), transitionIndex: 0, intentIds: new bytes32[](0), writes: new SlotWrite[](0)
        });
        (ok,,) = registry.checkAll(ctx);
    }

    // ------------------------------------------------------------- happy path

    function test_normalWithdrawalWorks() public {
        vm.prank(alice);
        vault.withdraw(100 ether);
        assertEq(vault.shares(alice), 400 ether);
        assertEq(vault.outflowSpent(), 100 ether);
    }

    function test_depositAndTransferAreUnguarded() public {
        // Unannotated functions are untouched by the guard — no budget consumed, no revert.
        vm.prank(alice);
        vault.transfer(attacker, 10 ether);
        assertEq(vault.outflowSpent(), 0);
    }

    // -------------------------------------------------------- the actual guard

    function test_outflowBeyondBudgetReverts() public {
        _refresh(2, 50 ether, 2_000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Guardable.BudgetExceeded.selector, 100 ether, 50 ether));
        vault.withdraw(100 ether);
    }

    function test_expiredBudgetStopsOutflows() public {
        vm.warp(2_001);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Guardable.BudgetExpired.selector, 2_000, 2_001));
        vault.withdraw(1 ether);
        assertEq(vault.outflowRemaining(), 0);
    }

    /// @notice The end-to-end story: state gets corrupted, and the value still cannot leave.
    /// @dev State corruption is *not* prevented — the guard makes no such claim. What it prevents is
    ///      the extraction. Operators see conservation broken, decline to refresh, the budget lapses,
    ///      and the attacker's inflated balance is unspendable.
    function test_corruptedStateCannotBeCashedOut() public {
        // The attacker is a known holder, so the conservation sweep visits their balance.
        vm.prank(attacker);
        vault.deposit(1 ether);

        // Exploit lands. Nothing on-chain stops it; the write is synchronous.
        vault.buggyMint(attacker, 1_000 ether);
        assertEq(vault.shares(attacker), 1_001 ether);
        assertFalse(_propertiesHold(), "operators can see the books are broken");

        // Within the live budget the attacker extracts only what was already attested.
        vm.prank(attacker);
        vault.withdraw(400 ether);

        // Operators decline to refresh, because the property set fails. The budget lapses.
        vm.warp(2_001);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Guardable.BudgetExpired.selector, 2_000, 2_001));
        vault.withdraw(1 ether);
    }

    /// @notice The phantom-holder hole is worse here than in the async model, and unclosable.
    /// @dev In the async model `SlotDomain` refuses a diff that writes value to an unenumerated
    ///      address, which shuts this class structurally. There is no diff here — operators read the
    ///      live contract — so there is nothing to bound the domain of. Value credited to an address
    ///      the conservation sweep never visits is invisible, the property set keeps passing, and
    ///      operators keep refreshing the budget.
    ///
    ///      The outflow cap still bounds the damage per epoch, which is the containment the design
    ///      actually promises. But the detector is blind, so it never escalates. The mitigation is
    ///      not another property: it is that a legacy adopter's properties must enumerate reachable
    ///      state rather than a registration list.
    function test_phantomHolderEscapesDetectionEntirely() public {
        vault.buggyMint(attacker, 1_000 ether); // attacker never deposited, so never a holder
        assertEq(vault.shares(attacker), 1_000 ether);
        assertTrue(_propertiesHold(), "the books balance while 1000 ether exists off the register");

        // Operators would happily keep refreshing. Only the outflow cap limits the bleed — and the
        // phantom balance is far larger than the vault's real assets, so the cap is all that stands
        // between the attacker and everything other depositors put in.
        vm.prank(attacker);
        vault.withdraw(500 ether);
        assertEq(vault.outflowSpent(), 500 ether);
        assertEq(vault.totalAssets(), 0, "alice's deposit is gone and the guard never objected");
    }

    /// @notice The exposure window is the current budget, and that is the honest bound on the design.
    /// @dev A smaller budget or shorter expiry buys tighter containment at the cost of more frequent
    ///      attestation. That dial is the whole risk decision an integrator makes.
    function test_exposureIsBoundedByTheLiveBudget() public {
        _refresh(2, 10 ether, 3_000);
        vault.buggyMint(attacker, 1_000 ether);

        vm.prank(attacker);
        vault.withdraw(10 ether); // drains the budget, not the vault

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Guardable.BudgetExceeded.selector, 1 ether, 0));
        vault.withdraw(1 ether);
    }

    // ------------------------------------------------------ attestation plumbing

    function test_unattestedRefreshReverts() public {
        vm.expectRevert(Guardable.NotAttested.selector);
        vault.refreshBudget(2, 1_000 ether, 3_000, abi.encode(keccak256("garbage")));
    }

    function test_refreshCannotBeReplayed() public {
        bytes32 d = vault.budgetDigest(2, 100 ether, 3_000);
        attestor.attest(d);
        vault.refreshBudget(2, 100 ether, 3_000, abi.encode(d));

        vm.expectRevert(abi.encodeWithSelector(Guardable.StaleEpoch.selector, 2, 3));
        vault.refreshBudget(2, 100 ether, 3_000, abi.encode(d));
    }

    function test_refreshRejectsPastExpiry() public {
        bytes32 d = vault.budgetDigest(2, 100 ether, 500);
        attestor.attest(d);
        vm.expectRevert(Guardable.ExpiryInPast.selector);
        vault.refreshBudget(2, 100 ether, 500, abi.encode(d));
    }

    function test_refreshResetsSpend() public {
        vm.prank(alice);
        vault.withdraw(100 ether);
        assertEq(vault.outflowSpent(), 100 ether);
        _refresh(2, 1_000 ether, 3_000);
        assertEq(vault.outflowSpent(), 0);
    }

    /// @notice Fail-closed cuts both ways: a quorum that stops attesting freezes withdrawals.
    /// @dev Worth a test rather than a footnote. This is the liveness cost of the design, and an
    ///      integrator should choose it knowingly rather than discover it during an outage.
    function test_silentQuorumFreezesWithdrawalsEvenWhenHealthy() public {
        assertTrue(_propertiesHold(), "nothing is wrong with the vault");
        vm.warp(2_001); // operators simply went away
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Guardable.BudgetExpired.selector, 2_000, 2_001));
        vault.withdraw(1 ether);
    }
}
