// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, IGuardedDomain, TransitionContext} from "../interfaces/IProperty.sol";

/// @title SlotDomain
/// @notice Every slot an attested diff writes must be one the target declared as its own.
///
/// @dev This is the property that makes the others trustworthy, and it is worth being precise
///      about why. A value property like conservation is a sum over a set the contract
///      enumerates — its holders. An attacker who writes value to an address that set never
///      visits does not break the sum; the sum simply never sees it. So conservation alone is
///      satisfiable by a diff that mints value out of nothing, which is exactly the phantom-holder
///      hole documented in the original GuardedVault example.
///
///      Bounding the *domain* of the diff closes that class structurally rather than by adding
///      another sum: if a slot is not declared, the write is refused, whatever it contains. Note
///      that this only works because evaluation is off-chain — `isGuardedSlot` typically costs
///      O(holders) per write, which no contract could afford to run on-chain per transition.
contract SlotDomain is IProperty {
    function name() external pure returns (string memory) {
        return "SlotDomain";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IGuardedDomain domain = IGuardedDomain(ctx.target);
        for (uint256 i; i < ctx.writes.length; ++i) {
            if (!domain.isGuardedSlot(ctx.writes[i].slot)) {
                return (false, "diff writes a slot outside the target's declared domain");
            }
        }
        return (true, "");
    }
}
