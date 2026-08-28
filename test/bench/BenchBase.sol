// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

/// @notice Shared setup and reporting for the gas benchmarks.
///
/// @dev Mirrors the conventions in `gas-killer/example-contracts/test/helpers/BenchmarkBase.sol` so
///      figures from the two repos can sit in the same table.
///
///      **Numbers to compare against, all from the Gas Killer gas report.** A real `verifyAndUpdate`
///      on Sepolia cost 300,944 gas, traced into 224,827 of BLS signature verification and 76,117 for
///      everything else. The BLS figure is the load-bearing one: it is constant in how much compute
///      the operators did off-chain, which is the entire reason settlement can beat a growing
///      on-chain cost.
abstract contract BenchBase is Test {
    /// @dev Real mainnet block ceiling. Foundry's own limits are raised in `foundry.toml` so a
    ///      deliberately expensive call can execute long enough to be measured; this is the figure
    ///      that actually matters and is asserted against separately.
    uint256 internal constant MAINNET_BLOCK_GAS = 30_000_000;

    /// @dev Measured on Sepolia, not modelled. `debug_traceTransaction` of the settlement below.
    uint256 internal constant BLS_VERIFY_GAS = 224_827;

    /// @dev tx base cost. Part of any transaction, guarded or not.
    uint256 internal constant TX_BASE_GAS = 21_000;

    /// @dev https://eth-sepolia.blockscout.com/tx/0x865bf3ab1d23566bce98261c1096822fb9a7ff8a52fbd07da9b5e804ec17fb7c
    uint256 internal constant SEPOLIA_SETTLEMENT_TOTAL = 300_944;

    struct Row {
        uint256 holders;
        uint256 unguarded;
        uint256 guarded;
    }

    Row[] internal rows;

    function _record(uint256 holders, uint256 unguarded, uint256 guarded) internal {
        rows.push(Row({holders: holders, unguarded: unguarded, guarded: guarded}));
    }

    /// @dev A guard performs no storage writes, so the diff a guarded call produces is identical to
    ///      the unguarded one. Settlement therefore costs the same either way, and the cost of the
    ///      rules is exactly what Gas Killer removes.
    function _settlementCost(uint256 diffWords) internal pure returns (uint256) {
        // 76,117 covered tx base, calldata, applying the diff and the transition counter for a
        // three-word diff. Scale only the per-word part, keeping the rest fixed.
        uint256 perWord = 22_100;
        uint256 fixedOverhead = 76_117 - (3 * perWord);
        return BLS_VERIFY_GAS + fixedOverhead + (diffWords * perWord);
    }

    function _report(string memory title, uint256 diffWords) internal view {
        uint256 settle = _settlementCost(diffWords);

        console.log("");
        console.log("=====================================================================");
        console.log(title);
        console.log("=====================================================================");
        console.log("holders | unguarded |   guarded | rules cost | via GasKiller |  saving");
        console.log("---------------------------------------------------------------------");

        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            uint256 rulesCost = r.guarded - r.unguarded;
            string memory saving;
            if (r.guarded > settle) {
                saving = string.concat("+", vm.toString(r.guarded - settle));
            } else {
                saving = string.concat("-", vm.toString(settle - r.guarded));
            }
            console.log(
                string.concat(
                    _pad(vm.toString(r.holders), 7),
                    " | ",
                    _pad(vm.toString(r.unguarded), 9),
                    " | ",
                    _pad(vm.toString(r.guarded), 9),
                    " | ",
                    _pad(vm.toString(rulesCost), 10),
                    " | ",
                    _pad(vm.toString(settle), 13),
                    " | ",
                    saving
                )
            );
        }
        console.log("");
        console.log("Settlement (flat, any holder count):", settle);
        console.log("  of which BLS verification:", BLS_VERIFY_GAS);
        console.log("");
    }

    function _pad(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return s;
        bytes memory out = new bytes(width);
        uint256 padding = width - b.length;
        for (uint256 i; i < padding; ++i) {
            out[i] = " ";
        }
        for (uint256 i; i < b.length; ++i) {
            out[padding + i] = b[i];
        }
        return string(out);
    }

    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("holder", i)))));
    }
}
