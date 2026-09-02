// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {Guarded} from "../src/Guarded.sol";
import {IProperty} from "../src/interfaces/IProperty.sol";
import {PropertyCatalogue} from "../src/catalogue/PropertyCatalogue.sol";
import {SubscriptionRegistry} from "../src/catalogue/SubscriptionRegistry.sol";
import {AdminVerifierAllowlist} from "../src/catalogue/IAdopterAdmin.sol";
import {LendingProtocol} from "../src/examples/LendingProtocol.sol";
import {
    MarketSolvency,
    MarketCapsRule,
    MarketOracleFreshness,
    MarketIndexFloor,
    MarketRiskParams,
    GlobalAccounting
} from "../src/properties/portfolio/MarketRules.sol";

/// @notice Deploys the catalogue, the six-rule risk policy and the lending example to a real
///         chain, then sends one guarded and one unguarded `borrow()` so their receipts can be
///         compared against the local benchmark in `docs/GAS.md`.
///
/// @dev Every measurement here is a separate transaction, which is the point: a Foundry test runs
///      as one transaction, so anything its setup touches stays warm. On a real chain each call
///      pays its own cold access, so these receipts are the unambiguous version of the same
///      numbers.
///
///      MARKETS defaults to 30, roughly what Aave carries. Seeding is chunked one market per
///      transaction to stay well inside the block gas limit.
contract GuardBench is Script {
    uint256 constant DEFAULT_MARKETS = 30;

    function run() external {
        uint256 markets = vm.envOr("MARKETS", DEFAULT_MARKETS);
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        console.log("deployer:", me);
        console.log("markets: ", markets);
        console.log("balance: ", me.balance);

        vm.startBroadcast(pk);

        PropertyCatalogue cat = new PropertyCatalogue(me);
        AdminVerifierAllowlist verifier = new AdminVerifierAllowlist(me);
        SubscriptionRegistry subs = new SubscriptionRegistry(cat, verifier, me);
        LendingProtocol proto = new LendingProtocol(subs, Guarded.GuardMode.Enforce);

        IProperty[6] memory rules = [
            IProperty(new MarketSolvency()),
            IProperty(new MarketCapsRule()),
            IProperty(new MarketOracleFreshness(3600)),
            IProperty(new MarketIndexFloor(1e27)),
            IProperty(new MarketRiskParams()),
            IProperty(new GlobalAccounting())
        ];

        verifier.setAdmin(address(proto), me, true);
        for (uint256 i; i < rules.length; ++i) {
            cat.list(rules[i], rules[i].name(), 1, false);
            subs.subscribe(address(proto), rules[i], "");
        }

        // Seed every market with non-zero totals, so the measured write is a steady-state
        // rewrite rather than a first-touch 20k allocation.
        for (uint256 i; i < markets; ++i) {
            proto.listMarket(1e24, 1e24, 7000, 8000);
            proto.supply(i, 1_000e18);
            proto.unguardedBorrow(i, 1e18);
        }

        // The two measurements. Each is its own transaction — read the gas from the receipts.
        proto.borrow(0, 1e18);
        proto.unguardedBorrow(1, 1e18);

        vm.stopBroadcast();

        console.log("");
        console.log("catalogue:          ", address(cat));
        console.log("subscriptions:      ", address(subs));
        console.log("lending protocol:   ", address(proto));
        console.log("");
        console.log("The last two transactions are guarded borrow() then unguarded borrow().");
        console.log("Compare their gasUsed against docs/GAS.md: 747,775 and 15,635 at 30 markets.");
    }
}
