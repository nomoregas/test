// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

interface ITwapMirror {
    function spotPriceSlot() external view returns (bytes32);
    function twapPriceSlot() external view returns (bytes32);
    function spotPrice() external view returns (uint256);
    function twapPrice() external view returns (uint256);
}

/// @title OracleDeviation
/// @notice Spot price may not diverge from the TWAP by more than a bound.
///
/// @dev Port of Assertions Book #11. The manipulation detector: a flash-loaned spot move shows up as
///      a spot/TWAP gap long before it shows up as a loss, because the TWAP is expensive to shift.
///
///      Judged on the post endpoint, since the question is whether the transition *leaves* prices
///      diverged. Same mirrored-state caveat as `OracleLiveness`: both figures must be adopter
///      storage, so the property is only as good as the mirror.
contract OracleDeviation is IProperty {
    using PreState for TransitionContext;

    uint256 public immutable maxDeviationBps;

    constructor(uint256 _maxDeviationBps) {
        maxDeviationBps = _maxDeviationBps;
    }

    function name() external pure returns (string memory) {
        return "OracleDeviation";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        ITwapMirror t = ITwapMirror(ctx.target);

        uint256 spot = uint256(c.post(t.spotPriceSlot(), bytes32(t.spotPrice())));
        uint256 twap = uint256(c.post(t.twapPriceSlot(), bytes32(t.twapPrice())));

        if (twap == 0) return (true, ""); // no reference yet
        uint256 gap = spot >= twap ? spot - twap : twap - spot;
        if (gap * 10_000 > twap * maxDeviationBps) {
            return (false, "spot deviates from twap beyond the bound");
        }
        return (true, "");
    }
}
