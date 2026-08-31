// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Guarded} from "../src/Guarded.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IProperty} from "../src/interfaces/IProperty.sol";
import {Vault} from "../src/examples/Vault.sol";
import {Conservation} from "../src/properties/Conservation.sol";
import {Solvency} from "../src/properties/Solvency.sol";
import {CatalogueFixture} from "./helpers/CatalogueFixture.sol";

/// @notice Drives the vault with random calls, including calls that would break its rules.
contract VaultHandler is Test {
    Vault public vault;
    address[] public actors;
    uint256 public succeeded;
    uint256 public reverted;

    constructor(Vault v) {
        vault = v;
        for (uint256 i; i < 5; ++i) {
            actors.push(address(uint160(uint256(keccak256(abi.encode("actor", i))))));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        amount = bound(amount, 0, 1e21);
        vm.prank(_actor(seed));
        try vault.deposit(amount) {
            succeeded++;
        } catch {
            reverted++;
        }
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, 1e21);
        vm.prank(a);
        try vault.withdraw(amount) {
            succeeded++;
        } catch {
            reverted++;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        amount = bound(amount, 0, 1e21);
        vm.prank(_actor(fromSeed));
        try vault.transfer(_actor(toSeed), amount) {
            succeeded++;
        } catch {
            reverted++;
        }
    }

    /// @notice A call that breaks conservation. The guard must revert it every time.
    function attemptBuggyMint(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1, 1e21);
        try vault.buggyMint(_actor(seed), amount) {
            revert("a conservation-breaking mint was allowed through");
        } catch {
            reverted++;
        }
    }
}

/// @notice Properties that must hold over every reachable sequence of calls.
/// @dev No operators, no attestation, no simulation. The vault refuses violating calls itself, so if
///      these hold it is because the Solidity held.
contract GuardedInvariantTest is StdInvariant, Test, CatalogueFixture {
    Vault vault;
    VaultHandler handler;

    function setUp() public {
        _deployCatalogue();
        vault = new Vault(subs, 10_000, Guarded.GuardMode.Enforce);
        adminVerifier.setAdmin(address(vault), address(this), true);

        _protect(new Conservation(), "Conservation");
        _protect(new Solvency(), "Solvency");

        handler = new VaultHandler(vault);
        targetContract(address(handler));
    }

    function _protect(IProperty p, string memory n) internal {
        cat.list(p, n, 1, false);
        subs.subscribe(address(vault), p, "");
    }

    function invariant_rulesAlwaysHold() public view {
        (bool ok, string memory which, string memory why) = vault.checkGuards();
        assertTrue(ok, string.concat("violated: ", which, " - ", why));
    }

    /// @dev Stated directly rather than through the rule contracts, so a broken rule cannot make this
    ///      pass vacuously.
    function invariant_booksBalance() public view {
        assertEq(vault.sumOfParts(), vault.totalShares());
    }

    function invariant_solvent() public view {
        assertGe(vault.totalAssets(), vault.totalShares());
    }

    /// @notice Guards against the invariants holding because nothing ever happened.
    function test_handlerActuallyMovesValueAndAttacksAreRefused() public {
        handler.deposit(0, 500);
        handler.deposit(1, 300);
        assertGt(vault.totalShares(), 0, "no value ever entered the vault");

        uint256 before = vault.totalShares();
        handler.attemptBuggyMint(0, 1_000);
        assertEq(vault.totalShares(), before, "the attack changed state");
        (bool ok,,) = vault.checkGuards();
        assertTrue(ok);
    }
}
