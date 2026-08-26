// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";

/// @notice Minimal view a target exposes to be checked for conservation.
interface IConservable {
    /// @dev The O(N) sweep. Expensive by design — it is never called on-chain in OffchainVeto mode.
    function sumOfParts() external view returns (uint256);
    function declaredTotal() external view returns (uint256);
}

/// @title Conservation
/// @notice The parts must add up to the declared whole.
/// @dev The canonical example of a property that is cheap to state, expensive to check, and
///      catastrophic to get wrong: any accounting bug that mints or burns value out of band
///      breaks it. Contracts normally maintain a running total instead and hope the increments
///      are right; this checks the thing the running total is supposed to be.
contract Conservation is IProperty {
    function name() external pure returns (string memory) {
        return "Conservation";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IConservable t = IConservable(ctx.target);
        if (t.sumOfParts() != t.declaredTotal()) {
            return (false, "sum of parts != declared total");
        }
        return (true, "");
    }
}
