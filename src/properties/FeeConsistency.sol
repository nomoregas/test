// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

interface IFeeAccruing {
    function feeAccruedSlot() external view returns (bytes32);
    function feeBaseSlot() external view returns (bytes32);
    function feeAccrued() external view returns (uint256);
    function feeBase() external view returns (uint256);
    function feeRateBps() external view returns (uint256);
}

/// @title FeeConsistency
/// @notice Fees accrued must match the declared rate applied to the base that moved.
///
/// @dev Port of Assertions Book #14. Fee logic is a recurring source of quiet loss: an
///      over-collection is a slow drain on users, an under-collection a slow drain on the protocol,
///      and neither trips any other property because the books still balance either way.
///
///      Allows a one-unit rounding slack, since integer fee maths cannot hit the exact figure. A
///      wider tolerance would let a systematic skim hide inside it, so it is deliberately fixed at
///      one rather than configurable.
contract FeeConsistency is IProperty {
    using PreState for TransitionContext;

    function name() external pure returns (string memory) {
        return "FeeConsistency";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        IFeeAccruing t = IFeeAccruing(ctx.target);

        bytes32 feeSlot = t.feeAccruedSlot();
        bytes32 baseSlot = t.feeBaseSlot();
        if (!c.touched(feeSlot) && !c.touched(baseSlot)) return (true, "");

        uint256 feeDelta = c.absDelta(feeSlot, bytes32(t.feeAccrued()));
        uint256 baseDelta = c.absDelta(baseSlot, bytes32(t.feeBase()));
        uint256 expected = (baseDelta * t.feeRateBps()) / 10_000;

        uint256 gap = feeDelta >= expected ? feeDelta - expected : expected - feeDelta;
        if (gap > 1) {
            return (false, "fee accrued does not match the declared rate");
        }
        return (true, "");
    }
}
