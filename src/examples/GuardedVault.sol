// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {GuardedState} from "../GuardedState.sol";
import {PropertyRegistry} from "../PropertyRegistry.sol";
import {IAttestor, IGuardedDomain, SlotWrite} from "../interfaces/IProperty.sol";
import {IConservable} from "../properties/Conservation.sol";
import {ISolvent} from "../properties/Solvency.sol";
import {IConcentrated} from "../properties/ConcentrationCap.sol";

/// @title GuardedVault
/// @notice A worked integration: a share vault with no direct writers to guarded state.
///
/// @dev Every function that would move value is a `request()`. The only thing that mutates
///      shares or totals is `settle()`, and that only runs against an attested diff. So the
///      properties registered against this vault — conservation, solvency, concentration, and
///      the slot domain — hold over *all* state changes, not just the expensive ones.
///
///      `register()` is the deliberate exception, and the asymmetry is the point: it appends to
///      the holder set without touching value. Registering an address grants nothing; it only
///      makes that address eligible to appear in the conservation sweep. Meanwhile SlotDomain
///      refuses any diff writing shares to an address that is *not* registered — so the
///      phantom-holder escape (write value to an address the sum never visits) is closed by
///      construction rather than by remembering to add another sum.
contract GuardedVault is GuardedState, IGuardedDomain, IConservable, ISolvent, IConcentrated {
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalAssets;
    address[] public holders;
    mapping(address => bool) public isHolder;

    uint256 public immutable maxConcentrationBps;

    error AlreadyRegistered(address who);
    error NotRegistered(address who);

    event Registered(address who);

    constructor(PropertyRegistry registry_, IAttestor attestor_, Mode mode_, uint256 maxConcentrationBps_)
        GuardedState(registry_, attestor_, mode_)
    {
        maxConcentrationBps = maxConcentrationBps_;
    }

    /// @notice Join the holder set. Grants no value — only eligibility to hold it.
    function register() external {
        if (isHolder[msg.sender]) revert AlreadyRegistered(msg.sender);
        isHolder[msg.sender] = true;
        holders.push(msg.sender);
        emit Registered(msg.sender);
    }

    // ------------------------------------------------- the spec operators reproduce

    /// @notice Reference implementation of a deposit, as a diff.
    /// @dev The Gas Killer pattern: this body *is* the specification. Operators reproduce it
    ///      off-chain, evaluate the properties on the result, and sign only if they hold. Keeping
    ///      it on-chain and public means the spec is auditable and testable by exactly the code
    ///      path an operator claims to have run.
    function previewDeposit(address who, uint256 assets) public view returns (SlotWrite[] memory writes) {
        if (!isHolder[who]) revert NotRegistered(who);
        writes = new SlotWrite[](3);
        writes[0] = SlotWrite(sharesSlot(who), bytes32(shares[who] + assets));
        writes[1] = SlotWrite(totalSharesSlot(), bytes32(totalShares + assets));
        writes[2] = SlotWrite(totalAssetsSlot(), bytes32(totalAssets + assets));
    }

    /// @notice Reference implementation of a transfer between holders, as a diff.
    function previewTransfer(address from, address to, uint256 amount) public view returns (SlotWrite[] memory writes) {
        if (!isHolder[from]) revert NotRegistered(from);
        if (!isHolder[to]) revert NotRegistered(to);
        writes = new SlotWrite[](2);
        writes[0] = SlotWrite(sharesSlot(from), bytes32(shares[from] - amount));
        writes[1] = SlotWrite(sharesSlot(to), bytes32(shares[to] + amount));
    }

    // ------------------------------------------------------------ declared domain

    function sharesSlot(address who) public pure returns (bytes32) {
        uint256 base;
        assembly {
            base := shares.slot
        }
        return keccak256(abi.encode(who, base));
    }

    function totalSharesSlot() public pure returns (bytes32) {
        uint256 s;
        assembly {
            s := totalShares.slot
        }
        return bytes32(s);
    }

    function totalAssetsSlot() public pure returns (bytes32) {
        uint256 s;
        assembly {
            s := totalAssets.slot
        }
        return bytes32(s);
    }

    /// @inheritdoc IGuardedDomain
    /// @dev O(holders) per slot. Unaffordable on-chain per transition, free off-chain — which is
    ///      precisely the trade the guard exists to make.
    function isGuardedSlot(bytes32 slot) external view returns (bool) {
        if (slot == totalSharesSlot() || slot == totalAssetsSlot()) return true;
        uint256 n = holders.length;
        for (uint256 i; i < n; ++i) {
            if (slot == sharesSlot(holders[i])) return true;
        }
        return false;
    }

    // ------------------------------------------------------------- property views

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
