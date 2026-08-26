// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

interface IOracleMirror {
    function oracleUpdatedAtSlot() external view returns (bytes32);
    function oracleUpdatedAt() external view returns (uint256);
}

/// @title OracleLiveness
/// @notice The adopter's mirrored oracle timestamp may not be staler than a bound.
///
/// @dev Port of Assertions Book #10. Stale-price exploitation does not need the oracle to be wrong,
///      only old: a feed frozen through a volatile hour lets positions be opened against a price
///      the market has left behind.
///
///      **The constraint that makes this weaker than theirs.** Phylax reads the oracle contract
///      directly across forks. A property here cannot read foreign state, so this checks a timestamp
///      the *adopter* mirrors into its own storage. That only protects you if the mirror is
///      maintained — an adopter that never refreshes it will pass this check while consuming a dead
///      feed. Worth pairing with a `Monotonic` on the same slot so the mirror cannot go backwards.
contract OracleLiveness is IProperty {
    using PreState for TransitionContext;

    uint256 public immutable maxStaleness;

    constructor(uint256 _maxStaleness) {
        maxStaleness = _maxStaleness;
    }

    function name() external pure returns (string memory) {
        return "OracleLiveness";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        IOracleMirror t = IOracleMirror(ctx.target);

        bytes32 slot = t.oracleUpdatedAtSlot();
        uint256 updatedAt = uint256(c.post(slot, bytes32(t.oracleUpdatedAt())));

        if (updatedAt == 0) return (false, "oracle has never been updated");
        if (block.timestamp > updatedAt && block.timestamp - updatedAt > maxStaleness) {
            return (false, "oracle timestamp is staler than the bound");
        }
        return (true, "");
    }
}
