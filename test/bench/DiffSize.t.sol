// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {Guarded} from "../../src/Guarded.sol";
import {IProperty} from "../../src/interfaces/IProperty.sol";
import {LendingProtocol} from "../../src/examples/LendingProtocol.sol";
import {
    MarketSolvency, MarketCapsRule, MarketOracleFreshness,
    MarketIndexFloor, MarketRiskParams, GlobalAccounting
} from "../../src/properties/portfolio/MarketRules.sol";
import {CatalogueFixture} from "../helpers/CatalogueFixture.sol";

/// @notice How many storage words a guarded borrow actually writes.
/// @dev Settlement applies the diff with raw `sstore`, so the word count is what the
///      diff-application term costs. A guard writes nothing, so this must equal the
///      unguarded diff — that equality is the claim "settlement is flat" rests on.
contract DiffSizeTest is Test, CatalogueFixture {
    LendingProtocol proto;

    function setUp() public {
        _deployCatalogue();
        proto = new LendingProtocol(subs, Guarded.GuardMode.Enforce);
        adminVerifier.setAdmin(address(proto), address(this), true);

        IProperty[6] memory rules = [
            IProperty(new MarketSolvency()), IProperty(new MarketCapsRule()),
            IProperty(new MarketOracleFreshness(3600)), IProperty(new MarketIndexFloor(1e27)),
            IProperty(new MarketRiskParams()), IProperty(new GlobalAccounting())
        ];
        for (uint256 i; i < 6; ++i) {
            cat.list(rules[i], rules[i].name(), 1, false);
            subs.subscribe(address(proto), rules[i], "");
        }
        for (uint256 i; i < 30; ++i) {
            proto.listMarket(1e24, 1e24, 7000, 8000);
            proto.supply(i, 1_000e18);
            proto.unguardedBorrow(i, 1e18);
        }
    }

    function _uniqueWrites(bytes32[] memory w) internal pure returns (uint256 n) {
        for (uint256 i; i < w.length; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) if (w[j] == w[i]) { seen = true; break; }
            if (!seen) ++n;
        }
    }

    function test_diffWordCount() public {
        vm.record();
        proto.borrow(0, 1e18);
        (, bytes32[] memory guardedW) = vm.accesses(address(proto));
        uint256 g = _uniqueWrites(guardedW);

        vm.record();
        proto.unguardedBorrow(1, 1e18);
        (, bytes32[] memory plainW) = vm.accesses(address(proto));
        uint256 u = _uniqueWrites(plainW);

        console.log("guarded borrow   distinct slots written:", g);
        console.log("unguarded borrow distinct slots written:", u);
        assertEq(g, u, "a guard must write nothing, or settlement is not flat");
    }
}
