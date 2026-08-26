// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Guardable} from "../Guardable.sol";
import {IAttestor} from "../../interfaces/IProperty.sol";
import {IConservable} from "../../properties/Conservation.sol";
import {ISolvent} from "../../properties/Solvency.sol";

/// @title LegacyVault
/// @notice An ordinary synchronous vault, of the kind that is already deployed everywhere, shown
///         adopting the guard by annotation alone.
///
/// @dev The point of this file is the size of the diff a real integrator would write. Against the
///      unguarded original it is:
///
///        1. `is Guardable` on the contract, and pass an attestor to the constructor;
///        2. `guardedOutflow(assets)` on `withdraw`.
///
///      `deposit`, `transfer` and every view are untouched, and no existing line changes. State still
///      moves synchronously and can still be corrupted by a bug — the guard does not claim otherwise.
///      What it claims is that corrupted state cannot be cashed out faster than a quorum has recently
///      agreed value may leave, and that a quorum which sees a broken invariant stops agreeing.
///
///      The properties operators evaluate against this are the same contracts the async model uses;
///      here they read the vault's views with no diff, which is exactly the case `checkNow()` is for.
contract LegacyVault is Guardable, IConservable, ISolvent {
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalAssets;
    address[] public holders;
    mapping(address => bool) public isHolder;

    constructor(IAttestor attestor_) Guardable(attestor_) {}

    function deposit(uint256 assets) external {
        if (!isHolder[msg.sender]) {
            isHolder[msg.sender] = true;
            holders.push(msg.sender);
        }
        shares[msg.sender] += assets;
        totalShares += assets;
        totalAssets += assets;
    }

    function transfer(address to, uint256 amount) external {
        if (!isHolder[to]) {
            isHolder[to] = true;
            holders.push(to);
        }
        shares[msg.sender] -= amount;
        shares[to] += amount;
    }

    /// @dev The whole integration: one annotation. Body unchanged.
    function withdraw(uint256 assets) external guardedOutflow(assets) {
        shares[msg.sender] -= assets;
        totalShares -= assets;
        totalAssets -= assets;
    }

    // ------------------------------------------------- views the properties read

    function sumOfParts() external view returns (uint256 sum) {
        uint256 n = holders.length;
        for (uint256 i; i < n; ++i) {
            sum += shares[holders[i]];
        }
    }

    function declaredTotal() external view returns (uint256) {
        return totalShares;
    }

    function backingAssets() external view returns (uint256) {
        return totalAssets;
    }

    function outstandingClaims() external view returns (uint256) {
        return totalShares;
    }

    /// @notice Deliberate bug, so a test can corrupt state the way a real exploit would.
    /// @dev Credits shares without moving the total, breaking conservation. Stands in for the
    ///      accounting bug or unguarded privileged path that every one of these incidents starts with.
    function buggyMint(address to, uint256 amount) external {
        shares[to] += amount;
    }
}
