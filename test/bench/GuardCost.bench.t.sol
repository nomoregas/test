// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {console} from "forge-std/console.sol";
import {BenchBase} from "./BenchBase.sol";
import {IProperty} from "../../src/interfaces/IProperty.sol";
import {Vault} from "../../src/examples/Vault.sol";
import {Conservation} from "../../src/properties/Conservation.sol";
import {Solvency} from "../../src/properties/Solvency.sol";
import {ConcentrationCap} from "../../src/properties/ConcentrationCap.sol";
import {CatalogueFixture} from "../helpers/CatalogueFixture.sol";

/// @notice What the rules cost on-chain, as the contract grows.
///
/// @dev The whole argument for this product is a cost curve, so this measures it rather than
///      asserting it. Two vaults with identical code and identical holder sets; one subscribes to
///      rules and one does not. The difference is the price of the safety.
///
///      **Measurement conditions, because they move the numbers.**
///      - Every holder already has a non-zero balance before measuring, so no write in the measured
///        call is a 20k zero-to-non-zero. Steady state, not first touch.
///      - Nothing is zeroed, so no refunds and no interaction with the 20% refund cap.
///      - The rule sweep reads holder slots cold at 2100 each (EIP-2929). That is the honest figure
///        for a call that touches them for the first time, which a deposit does.
///      - Gas is measured around the external call only, so the harness is not in the number.
contract GuardCostBench is BenchBase, CatalogueFixture {
    Vault guardedVault;
    Vault plainVault;

    function setUp() public {
        _deployCatalogue();
        guardedVault = new Vault(subs, 10_000);
        plainVault = new Vault(subs, 10_000);

        adminVerifier.setAdmin(address(guardedVault), address(this), true);

        // Only the first vault subscribes. The second runs the same code with nothing registered.
        _protect(address(guardedVault), new Conservation(), "Conservation");
        _protect(address(guardedVault), new Solvency(), "Solvency");
        _protect(address(guardedVault), new ConcentrationCap(0), "ConcentrationCap");
    }

    function _protect(address adopter, IProperty p, string memory n) internal {
        cat.list(p, n, 1, false);
        subs.subscribe(adopter, p, "");
    }

    /// @dev Bring both vaults to `n` holders, each already holding a balance.
    function _fill(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            address h = _holder(i);
            vm.prank(h);
            plainVault.deposit(1_000);
            vm.prank(h);
            guardedVault.deposit(1_000);
        }
    }

    /// @dev One more deposit from an existing holder, measured as a standalone transaction would be.
    ///
    ///      `vm.cool` is load-bearing. Foundry runs a whole test as a single transaction, so by the
    ///      time the fill loop finishes every holder slot is warm and each SLOAD costs 100 instead of
    ///      2100. A real deposit is its own transaction and touches those slots cold. Measuring warm
    ///      would understate the rule sweep roughly twentyfold and push break-even far to the right.
    function _measure(Vault v, address who) internal returns (uint256 used) {
        vm.cool(address(v));
        vm.cool(address(subs));
        for (uint256 i; i < subs.subscriptionCount(address(v)); ++i) {
            vm.cool(subs.subscriptionsOf(address(v))[i]);
        }
        vm.prank(who);
        uint256 before = gasleft();
        v.deposit(1_000);
        used = before - gasleft();
    }

    function test_gasCurve() public {
        uint256[8] memory points = [uint256(1), 10, 25, 50, 100, 200, 400, 800];

        uint256 filled;
        for (uint256 p; p < points.length; ++p) {
            uint256 n = points[p];
            for (uint256 i = filled; i < n; ++i) {
                address h = _holder(i);
                vm.prank(h);
                plainVault.deposit(1_000);
                vm.prank(h);
                guardedVault.deposit(1_000);
            }
            filled = n;

            address measured = _holder(0);
            uint256 unguarded = _measure(plainVault, measured);
            uint256 guarded = _measure(guardedVault, measured);
            _record(n, unguarded, guarded);
        }

        _report("Deposit: Conservation + Solvency + ConcentrationCap", 3);
    }

    /// @notice Find the holder count where a guarded deposit stops fitting in a mainnet block.
    /// @dev Past this point the check cannot run on-chain at any price, which is a stronger claim
    ///      than "it is expensive". Reported rather than asserted, since the answer is the finding.
    function test_whereTheCheckStopsFittingInABlock() public {
        uint256 n = 2_000;
        for (uint256 i; i < n; ++i) {
            address h = _holder(i);
            vm.prank(h);
            guardedVault.deposit(1_000);
        }

        address measured = _holder(0);
        uint256 used = _measure(guardedVault, measured);

        console.log("");
        console.log("Guarded deposit at 2000 holders:", used);
        console.log("Mainnet block gas limit:        ", MAINNET_BLOCK_GAS);
        console.log("Fraction of a whole block (pct):", (used * 100) / MAINNET_BLOCK_GAS);
        console.log("Extrapolated holders per block: ", (MAINNET_BLOCK_GAS * n) / used);
        console.log("");
    }
}
