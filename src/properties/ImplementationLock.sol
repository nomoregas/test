// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

/// @title ImplementationLock
/// @notice The proxy implementation and admin slots may only change to a pre-approved address.
///
/// @dev Port of Phylax's `AnomalyGatedUpgradeAssertion`, minus the anomaly gate. Their version
///      blocks an upgrade only when the transaction *also* scores as anomalous, on the reasoning
///      that "a contract does not rewrite its own implementation in normal use, so the upgrade
///      heuristic adds almost no false blocks".
///
///      The gate does not port: it needs a heuristic scoring the transaction, which their executor
///      computes and Gas Killer has no equivalent for. So this is ungated, and the allowlist carries
///      the weight the anomaly score carried for them — an empty allowlist freezes the slots
///      outright, a populated one permits exactly the planned upgrade.
///
///      Slots default to the EIP-1967 constants, with an optional owner slot alongside them, matching
///      the three they watch.
contract ImplementationLock is IProperty {
    using PreState for TransitionContext;

    /// @dev keccak256("eip1967.proxy.implementation") - 1
    bytes32 public constant EIP1967_IMPLEMENTATION = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev keccak256("eip1967.proxy.admin") - 1
    bytes32 public constant EIP1967_ADMIN = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 public immutable ownerSlot;

    mapping(bytes32 => bool) public approvedValue;

    constructor(bytes32 _ownerSlot, bytes32[] memory approvedValues) {
        ownerSlot = _ownerSlot;
        for (uint256 i; i < approvedValues.length; ++i) {
            approvedValue[approvedValues[i]] = true;
        }
    }

    function name() external pure returns (string memory) {
        return "ImplementationLock";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;

        if (!_permitted(c, EIP1967_IMPLEMENTATION)) return (false, "unapproved proxy implementation change");
        if (!_permitted(c, EIP1967_ADMIN)) return (false, "unapproved proxy admin change");
        if (ownerSlot != bytes32(0) && !_permitted(c, ownerSlot)) return (false, "unapproved owner change");

        return (true, "");
    }

    /// @dev A no-op write is permitted here, unlike in `SlotProtection`. These slots legitimately
    ///      change under governance, so what matters is the destination, not that the slot was
    ///      touched. Use `SlotProtection` when the intent is a hard freeze.
    function _permitted(TransitionContext memory c, bytes32 slot) private view returns (bool) {
        if (!c.touched(slot)) return true;
        bytes32 before = c.pre(slot, bytes32(0));
        bytes32 after_ = c.post(slot, bytes32(0));
        if (before == after_) return true;
        return approvedValue[after_];
    }
}
