// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

interface IConstantProductPool {
    function reserve0Slot() external view returns (bytes32);
    function reserve1Slot() external view returns (bytes32);
    function reserve0() external view returns (uint256);
    function reserve1() external view returns (uint256);
}

/// @title ConstantProduct
/// @notice The product of the two reserves may not fall.
///
/// @dev Port of Assertions Book #6. The property an AMM's whole safety argument rests on: a swap
///      moves value between the reserves and fees push `k` up, so any transition that leaves `k`
///      lower has taken value out of the pool.
///
///      `toleranceBps` exists for integer rounding, which legitimately shaves the product on small
///      trades. Set it to zero for a pool whose maths is exact.
///
///      Fully expressible here because reserves are the adopter's own storage — no foreign ledger
///      and no call trace required.
contract ConstantProduct is IProperty {
    using PreState for TransitionContext;

    uint256 public immutable toleranceBps;

    constructor(uint256 _toleranceBps) {
        toleranceBps = _toleranceBps;
    }

    function name() external pure returns (string memory) {
        return "ConstantProduct";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        IConstantProductPool p = IConstantProductPool(ctx.target);

        bytes32 s0 = p.reserve0Slot();
        bytes32 s1 = p.reserve1Slot();
        bytes32 c0 = bytes32(p.reserve0());
        bytes32 c1 = bytes32(p.reserve1());

        uint256 kPre = uint256(c.pre(s0, c0)) * uint256(c.pre(s1, c1));
        uint256 kPost = uint256(c.post(s0, c0)) * uint256(c.post(s1, c1));

        if (kPost * 10_000 < kPre * (10_000 - toleranceBps)) {
            return (false, "reserve product fell beyond tolerance");
        }
        return (true, "");
    }
}
