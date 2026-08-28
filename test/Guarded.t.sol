// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Guarded} from "../src/Guarded.sol";
import {Vault} from "../src/examples/Vault.sol";
import {Conservation} from "../src/properties/Conservation.sol";
import {Solvency} from "../src/properties/Solvency.sol";
import {ConcentrationCap} from "../src/properties/ConcentrationCap.sol";
import {CatalogueFixture} from "./helpers/CatalogueFixture.sol";
import {IProperty} from "../src/interfaces/IProperty.sol";

/// @notice The guard enforcing itself, with nothing else present.
/// @dev There is no attestor, no operator, no quorum and no off-chain party anywhere in this file.
///      A rule-breaking call reverts because the Solidity says so. That is the whole security model.
contract GuardedTest is Test, CatalogueFixture {
    Vault vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);

    function setUp() public {
        _deployCatalogue();
        vault = new Vault(subs, 10_000);

        adminVerifier.setAdmin(address(vault), address(this), true);
        _protect(address(vault), new Conservation(), "Conservation");
        _protect(address(vault), new Solvency(), "Solvency");
    }

    /// @dev These rules read the adopter's own views, so they need no per-adopter config.
    function _protect(address adopter, IProperty p, string memory n) internal {
        cat.list(p, n, 1, false);
        subs.subscribe(adopter, p, "");
    }

    // ------------------------------------------------------------ normal use

    function test_ordinaryDepositWorks() public {
        vm.prank(alice);
        vault.deposit(100);
        assertEq(vault.shares(alice), 100);
        assertEq(vault.totalShares(), 100);
    }

    /// @notice Nothing is asynchronous. The caller's balance is credited in the same transaction.
    function test_depositIsImmediate() public {
        vm.prank(alice);
        vault.deposit(100);
        vm.prank(alice);
        vault.withdraw(40);
        assertEq(vault.shares(alice), 60);
    }

    function test_transferKeepsTheBooksBalanced() public {
        vm.prank(alice);
        vault.deposit(100);
        vm.prank(alice);
        vault.transfer(bob, 40);
        assertEq(vault.shares(alice), 60);
        assertEq(vault.shares(bob), 40);
        assertEq(vault.sumOfParts(), vault.totalShares());
    }

    // -------------------------------------------------------- the guard works

    /// @notice A bug that breaks the books reverts. No operator involved.
    function test_guardRevertsTheBuggyMint() public {
        vm.prank(alice);
        vault.deposit(100);

        vm.expectRevert(
            abi.encodeWithSelector(Guarded.PropertyViolated.selector, "Conservation", "sum of parts != declared total")
        );
        vault.buggyMint(attacker, 1_000);

        assertEq(vault.shares(attacker), 0, "the bad state never landed");
    }

    /// @notice The same bug without the modifier, to show what the guard is worth.
    function test_withoutTheGuardTheSameBugLands() public {
        vm.prank(alice);
        vault.deposit(100);

        vault.unguardedBuggyMint(attacker, 1_000);

        assertEq(vault.shares(attacker), 1_000);
        (bool ok, string memory which,) = vault.checkGuards();
        assertFalse(ok);
        assertEq(which, "Conservation");
    }

    function test_guardRevertsAnInsolventOutcome() public {
        // Concentration is off; solvency is what should catch this.
        vm.prank(alice);
        vault.deposit(100);

        // Withdrawing more shares than exist would underflow first, so drive it through the bug:
        // credit shares with no backing assets and let Solvency object.
        vm.expectRevert();
        vault.buggyMint(alice, 50);
    }

    function test_concentrationCapRevertsABreach() public {
        Vault capped = new Vault(subs, 6000);
        adminVerifier.setAdmin(address(capped), address(this), true);
        _protect(address(capped), new ConcentrationCap(100), "ConcentrationCap");

        vm.prank(alice);
        capped.deposit(50);
        vm.prank(bob);
        capped.deposit(50);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Guarded.PropertyViolated.selector, "ConcentrationCap", "a holder exceeds the concentration cap"
            )
        );
        capped.deposit(60); // alice to 110/160 = 68.75%
    }

    // ------------------------------------------------ no external dependencies

    /// @notice A vault subscribed to nothing still functions. Guards are opt-in, not a toll gate.
    function test_unsubscribedVaultIsSimplyUnguarded() public {
        Vault bare = new Vault(subs, 10_000);
        vm.prank(alice);
        bare.deposit(100);
        bare.unguardedBuggyMint(attacker, 1_000);
        vm.prank(bob);
        bare.deposit(1); // guarded, but no rules subscribed, so nothing to violate
        assertEq(bare.shares(attacker), 1_000);
    }

    /// @notice Dropping a rule stops it being enforced, immediately and without redeploying.
    function test_unsubscribingStopsEnforcement() public {
        vm.prank(alice);
        vault.deposit(100);

        subs.unsubscribe(address(vault), IProperty(subs.subscriptionsOf(address(vault))[0]));
        subs.unsubscribe(address(vault), IProperty(subs.subscriptionsOf(address(vault))[0]));

        vault.buggyMint(attacker, 1_000); // no longer reverts
        assertEq(vault.shares(attacker), 1_000);
    }
}
