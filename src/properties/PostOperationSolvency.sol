// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

interface IAccountHealth {
    /// @notice Accounts this transition touches, so the sweep is bounded by the work done.
    function accountsTouchedBy(bytes32[] calldata intentIds) external view returns (address[] memory);
    /// @notice Slot holding the account's health figure, so pre and post are both recoverable.
    function accountHealthSlot(address account) external view returns (bytes32);
    function accountHealth(address account) external view returns (uint256);
    /// @notice The value at or above which an account is considered solvent.
    function healthFloor() external view returns (uint256);
}

/// @title PostOperationSolvency
/// @notice Every account a transition touches must end solvent — and an account that was already
///         underwater must come out no worse.
///
/// @dev Port of Phylax's `PostOperationSolvency` micro-pattern, and the most valuable property in
///      the ported set: it is the one that stops a lending protocol leaving a position underwater.
///      Their wording — "risk-increasing operations must leave the touched account solvent;
///      liquidations must improve it" — is exactly the two-branch rule below.
///
///      The second branch is what makes liquidation expressible without a call-trace classifier. A
///      naive "everyone must be solvent" property would block every liquidation, since a liquidation
///      by definition operates on an account that is already under the floor. Comparing pre against
///      post instead lets the repair through while still refusing anything that deepens the hole.
contract PostOperationSolvency is IProperty {
    using PreState for TransitionContext;

    function name() external pure returns (string memory) {
        return "PostOperationSolvency";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        IAccountHealth t = IAccountHealth(ctx.target);

        address[] memory accounts = t.accountsTouchedBy(ctx.intentIds);
        uint256 floor = t.healthFloor();

        for (uint256 i; i < accounts.length; ++i) {
            bytes32 slot = t.accountHealthSlot(accounts[i]);
            bytes32 current = bytes32(t.accountHealth(accounts[i]));
            uint256 healthPre = uint256(c.pre(slot, current));
            uint256 healthPost = uint256(c.post(slot, current));

            if (healthPre >= floor) {
                if (healthPost < floor) return (false, "a solvent account was left insolvent");
            } else {
                if (healthPost < healthPre) return (false, "an insolvent account was made worse");
            }
        }
        return (true, "");
    }
}
