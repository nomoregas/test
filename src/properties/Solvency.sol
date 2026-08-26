// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";

interface ISolvent {
    function backingAssets() external view returns (uint256);
    function outstandingClaims() external view returns (uint256);
}

/// @title Solvency
/// @notice Backing assets must cover every outstanding claim against them.
/// @dev Distinct from conservation: conservation says the books are internally consistent,
///      solvency says the books are covered by something real. A vault can be perfectly
///      conserving and still insolvent.
contract Solvency is IProperty {
    function name() external pure returns (string memory) {
        return "Solvency";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        ISolvent t = ISolvent(ctx.target);
        if (t.backingAssets() < t.outstandingClaims()) {
            return (false, "backing assets < outstanding claims");
        }
        return (true, "");
    }
}
