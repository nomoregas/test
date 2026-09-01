// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Guarded} from "../../src/Guarded.sol";
import {console} from "forge-std/console.sol";
import {IProperty} from "../../src/interfaces/IProperty.sol";
import {LendingProtocol} from "../../src/examples/LendingProtocol.sol";
import {
    MarketSolvency,
    MarketCapsRule,
    MarketOracleFreshness,
    MarketIndexFloor,
    MarketRiskParams,
    GlobalAccounting
} from "../../src/properties/portfolio/MarketRules.sol";
import {CatalogueFixture} from "../helpers/CatalogueFixture.sol";

/// @notice The cost of a whole risk policy on a multi-asset lending protocol.
///
/// @dev **Why the structure is odd.** Gas here is dominated by EIP-2929 cold access — 2,100 for a
///      first `SLOAD` of a slot, 100 thereafter — and a Foundry test runs as a single transaction, so
///      anything a setup loop touches is warm for the rest of the test. `vm.cool` does not fix this:
///      probed directly (`CoolProbe`), it resets EIP-2200 dirty-store tracking and leaves access
///      warmth alone, and a call measured "after cooling" came out *cheaper* than the same call
///      measured warm.
///
///      The only unambiguous cold measurement is one per transaction. Each test function is its own
///      transaction with a fresh access list, so every data point below is a separate test in a
///      separate contract, with all the fill work done in `setUp`. Verbose, and correct.
///
///      Six rules, each a genuine lending concern: per-market solvency, supply and borrow caps,
///      oracle freshness, index floors, risk-parameter consistency, and recomputing the protocol's
///      running totals from the per-market figures. Aave carries around thirty markets.
abstract contract PortfolioBenchBase is Test, CatalogueFixture {
    /// @dev What settling this transition costs, and the target the policy is measured against.
    ///      Constant in off-chain compute under either scheme, which is what lets a flat cost beat
    ///      a growing one.
    ///
    ///      `SETTLEMENT_BLS` is measured on Sepolia by Gas Killer, not modelled: a real
    ///      `verifyAndUpdate` cost 300,944 gas, 224,827 of it BLS verification.
    ///
    ///      `SETTLEMENT` is the Schnorr path and is **modelled**: the same measured transaction
    ///      minus BLS verification (76,117), plus roughly 10,000 for one `ecrecover`, two cold
    ///      `SchnorrStakeRegistry` reads and challenge hashing. Pessimistic, since a 64-byte
    ///      signature is far less calldata than a BLS certificate. Replace it the moment a real
    ///      Schnorr settlement can be measured — see `docs/GAS.md`.
    uint256 internal constant SETTLEMENT = 86_000;
    uint256 internal constant SETTLEMENT_BLS = 300_944;

    LendingProtocol internal proto;
    IProperty[] internal rules;

    function _marketCount() internal view virtual returns (uint256);
    function _ruleCount() internal view virtual returns (uint256);

    function setUp() public {
        _deployCatalogue();
        proto = new LendingProtocol(subs, Guarded.GuardMode.Enforce);
        adminVerifier.setAdmin(address(proto), address(this), true);

        rules.push(new MarketSolvency());
        rules.push(new MarketCapsRule());
        rules.push(new MarketOracleFreshness(3600));
        rules.push(new MarketIndexFloor(1e27));
        rules.push(new MarketRiskParams());
        rules.push(new GlobalAccounting());

        for (uint256 i; i < rules.length; ++i) {
            cat.list(rules[i], rules[i].name(), 1, false);
        }
        for (uint256 i; i < _ruleCount(); ++i) {
            subs.subscribe(address(proto), rules[i], "");
        }

        // List the markets and give every one non-zero totals, so the measured call is a
        // steady-state write rather than a first-touch 20k zero-to-non-zero.
        for (uint256 i; i < _marketCount(); ++i) {
            proto.listMarket(1e24, 1e24, 7000, 8000);
            proto.supply(i, 1_000e18);
            proto.unguardedBorrow(i, 1e18);
        }
    }

    function _log(string memory label, uint256 used) internal view {
        console.log(
            string.concat(
                "markets=",
                vm.toString(_marketCount()),
                " rules=",
                vm.toString(_ruleCount()),
                " ",
                label,
                "=",
                vm.toString(used),
                used > SETTLEMENT ? "  [GasKiller wins]" : ""
            )
        );
    }

    /// @notice One guarded borrow, measured in a transaction that has touched nothing.
    function test_guardedBorrow() public {
        uint256 before = gasleft();
        proto.borrow(0, 1e18);
        _log("guarded", before - gasleft());
    }

    /// @notice The same call with the policy off, as the baseline.
    function test_unguardedBorrow() public {
        uint256 before = gasleft();
        proto.unguardedBorrow(0, 1e18);
        _log("unguarded", before - gasleft());
    }
}

// ------------------------------------------- full 6-rule policy, by market count

contract Portfolio_M1_R6 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 1;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 6;
    }
}

contract Portfolio_M5_R6 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 5;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 6;
    }
}

contract Portfolio_M10_R6 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 10;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 6;
    }
}

contract Portfolio_M20_R6 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 20;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 6;
    }
}

contract Portfolio_M30_R6 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 30;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 6;
    }
}

contract Portfolio_M40_R6 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 40;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 6;
    }
}

// ------------------------------------ cost built up rule by rule, at 30 markets

contract Portfolio_M30_R1 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 30;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 1;
    }
}

contract Portfolio_M30_R2 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 30;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 2;
    }
}

contract Portfolio_M30_R3 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 30;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 3;
    }
}

contract Portfolio_M30_R4 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 30;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 4;
    }
}

contract Portfolio_M30_R5 is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 30;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 5;
    }
}

// -------------------------------------------------- the policy actually blocks

contract PortfolioEnforcement is PortfolioBenchBase {
    function _marketCount() internal pure override returns (uint256) {
        return 5;
    }

    function _ruleCount() internal pure override returns (uint256) {
        return 6;
    }

    /// @notice A benchmark of a guard that does not work is noise, so prove it works.
    function test_policyBlocksBadTransitions() public {
        vm.expectRevert();
        proto.overBorrow(0, 1e30); // past the borrow cap

        vm.expectRevert();
        proto.rewindIndex(0, 1); // index below its floor

        (bool ok,,) = proto.checkGuards();
        assertTrue(ok, "protocol still healthy after both attempts were refused");
    }
}
