// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Guarded} from "../Guarded.sol";
import {SubscriptionRegistry} from "../catalogue/SubscriptionRegistry.sol";
import {IConservable} from "../properties/Conservation.sol";
import {ISolvent} from "../properties/Solvency.sol";
import {IConcentrated} from "../properties/ConcentrationCap.sol";

/// @title Vault
/// @notice An ordinary share vault. Synchronous, unremarkable, and guarded.
///
/// @dev The point of this file is how little there is to it. Against the same vault without guards,
///      the diff is:
///
///        1. `is Guarded`, and pass the registry to the constructor;
///        2. `guarded` on the three functions that move value.
///
///      Nothing else changes. No queue, no attestation, no waiting. `deposit` still credits the
///      caller in the same transaction. What changed is that the call now also verifies the vault's
///      books add up, that it is solvent, and that no holder has grown past its cap — checks that
///      sweep every holder, which is why a normal vault does not do them.
///
///      Running those on-chain costs real gas. That is the cost Gas Killer removes: it executes the
///      call off-chain and settles the result, so the sweep is free to the user. The vault does not
///      know or care whether that is happening. Deploy it on any EVM and it still refuses to break
///      its own rules; it just pays for the privilege.
contract Vault is Guarded, IConservable, ISolvent, IConcentrated {
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalAssets;
    address[] public holders;
    mapping(address => bool) public isHolder;

    uint256 public immutable maxConcentrationBps;

    constructor(SubscriptionRegistry registry_, uint256 maxConcentrationBps_) Guarded(registry_) {
        maxConcentrationBps = maxConcentrationBps_;
    }

    function deposit(uint256 assets) external guarded {
        _track(msg.sender);
        shares[msg.sender] += assets;
        totalShares += assets;
        totalAssets += assets;
    }

    function withdraw(uint256 assets) external guarded {
        shares[msg.sender] -= assets;
        totalShares -= assets;
        totalAssets -= assets;
    }

    function transfer(address to, uint256 amount) external guarded {
        _track(to);
        shares[msg.sender] -= amount;
        shares[to] += amount;
    }

    /// @notice Deliberate bug, so tests can prove the guard is what stops it.
    /// @dev Credits shares without moving the total. Stands in for the accounting slip or unguarded
    ///      privileged path that these incidents actually start with. It is `guarded` like everything
    ///      else, so the call reverts and the bad state never lands.
    function buggyMint(address to, uint256 amount) external guarded {
        _track(to);
        shares[to] += amount;
    }

    /// @notice The same bug with no guard, to show what the modifier is worth.
    function unguardedBuggyMint(address to, uint256 amount) external {
        _track(to);
        shares[to] += amount;
    }

    function _track(address who) private {
        if (!isHolder[who]) {
            isHolder[who] = true;
            holders.push(who);
        }
    }

    // ------------------------------------------------- what the rules read

    /// @dev The O(holders) sweep. This is the check a normal vault cannot afford per call.
    function sumOfParts() external view returns (uint256 sum) {
        uint256 n = holders.length;
        for (uint256 i; i < n; ++i) {
            sum += shares[holders[i]];
        }
    }

    function declaredTotal() external view override(IConservable, IConcentrated) returns (uint256) {
        return totalShares;
    }

    function backingAssets() external view returns (uint256) {
        return totalAssets;
    }

    function outstandingClaims() external view returns (uint256) {
        return totalShares;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    function sharesOf(address who) external view returns (uint256) {
        return shares[who];
    }

    function capBps() external view returns (uint256) {
        return maxConcentrationBps;
    }
}
