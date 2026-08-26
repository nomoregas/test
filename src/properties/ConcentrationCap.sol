// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";

interface IConcentrated {
    function holderCount() external view returns (uint256);
    function holderAt(uint256 i) external view returns (address);
    function sharesOf(address who) external view returns (uint256);
    function declaredTotal() external view returns (uint256);
    function capBps() external view returns (uint256);
}

/// @title ConcentrationCap
/// @notice No single holder may exceed a configured share of the total.
///
/// @dev A risk-limit property rather than a correctness one, and a good example of what becomes
///      possible once checks are free: enforcing this on-chain per transition means an O(N) sweep
///      on every write, so in practice protocols enforce it in a monitoring script and hope
///      someone is awake. Here it is a precondition of settlement.
///
///      **The bootstrap floor.** A percentage cap is unsatisfiable on an empty vault: the first
///      depositor necessarily holds 100% of it, so a naive cap would refuse every transition that
///      could ever reach a healthy distribution. `minTotalToEnforce` is the floor below which
///      concentration is not yet a meaningful notion. Getting this wrong is a good illustration of
///      why properties need their own tests — the property was deadlocked, not the contract.
contract ConcentrationCap is IProperty {
    uint256 public immutable minTotalToEnforce;

    constructor(uint256 _minTotalToEnforce) {
        minTotalToEnforce = _minTotalToEnforce;
    }

    function name() external pure returns (string memory) {
        return "ConcentrationCap";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IConcentrated t = IConcentrated(ctx.target);
        uint256 total = t.declaredTotal();
        if (total == 0 || total < minTotalToEnforce) return (true, "");

        uint256 cap = (total * t.capBps()) / 10_000;
        uint256 n = t.holderCount();
        for (uint256 i; i < n; ++i) {
            if (t.sharesOf(t.holderAt(i)) > cap) {
                return (false, "a holder exceeds the concentration cap");
            }
        }
        return (true, "");
    }
}
