// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {GuardedState} from "../GuardedState.sol";
import {PropertyRegistry} from "../PropertyRegistry.sol";
import {IAttestor, IGuardedDomain, SlotWrite} from "../interfaces/IProperty.sol";
import {IConservable} from "../properties/Conservation.sol";
import {ISolvent} from "../properties/Solvency.sol";
import {IConcentrated} from "../properties/ConcentrationCap.sol";
import {IShareVault} from "../properties/SharePriceFloor.sol";
import {IFlowVault} from "../properties/AssetFlowConsistency.sol";

/// @notice What a caller is asking the vault to do.
/// @dev Intents are structured rather than opaque bytes so the adopter can answer questions about
///      them — `declaredNetFlow` in particular. An opaque blob would leave the vault unable to say
///      what flow a transition is supposed to represent, and `AssetFlowConsistency` would have
///      nothing to hold the diff against.
enum ActionKind {
    Deposit,
    Transfer,
    Withdraw
}

struct VaultAction {
    ActionKind kind;
    address from;
    address to;
    uint256 amount;
}

/// @title GuardedVault
/// @notice A worked integration: a share vault with no direct writers to guarded state.
///
/// @dev Every function that would move value is a `request()`. The only thing that mutates
///      shares or totals is `settle()`, and that only runs against an attested diff. So the
///      properties registered against this vault hold over *all* state changes, not just the
///      expensive ones.
///
///      `register()` is the deliberate exception, and the asymmetry is the point: it appends to
///      the holder set without touching value. Registering an address grants nothing; it only
///      makes that address eligible to appear in the conservation sweep. Meanwhile SlotDomain
///      refuses any diff writing shares to an address that is *not* registered — so the
///      phantom-holder escape is closed by construction rather than by remembering to add
///      another sum.
contract GuardedVault is GuardedState, IGuardedDomain, IConservable, ISolvent, IConcentrated, IShareVault, IFlowVault {
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public override(IShareVault, IFlowVault) totalAssets;
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
        writes[0] = SlotWrite(sharesSlot(who), bytes32(shares[who]), bytes32(shares[who] + assets));
        writes[1] = SlotWrite(totalSharesSlot(), bytes32(totalShares), bytes32(totalShares + assets));
        writes[2] = SlotWrite(totalAssetsSlot(), bytes32(totalAssets), bytes32(totalAssets + assets));
    }

    /// @notice Reference implementation of a transfer between holders, as a diff.
    function previewTransfer(address from, address to, uint256 amount) public view returns (SlotWrite[] memory writes) {
        if (!isHolder[from]) revert NotRegistered(from);
        if (!isHolder[to]) revert NotRegistered(to);
        writes = new SlotWrite[](2);
        writes[0] = SlotWrite(sharesSlot(from), bytes32(shares[from]), bytes32(shares[from] - amount));
        writes[1] = SlotWrite(sharesSlot(to), bytes32(shares[to]), bytes32(shares[to] + amount));
    }

    /// @notice Reference implementation of a withdrawal, as a diff.
    function previewWithdraw(address who, uint256 amount) public view returns (SlotWrite[] memory writes) {
        if (!isHolder[who]) revert NotRegistered(who);
        writes = new SlotWrite[](3);
        writes[0] = SlotWrite(sharesSlot(who), bytes32(shares[who]), bytes32(shares[who] - amount));
        writes[1] = SlotWrite(totalSharesSlot(), bytes32(totalShares), bytes32(totalShares - amount));
        writes[2] = SlotWrite(totalAssetsSlot(), bytes32(totalAssets), bytes32(totalAssets - amount));
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

    function totalAssetsSlot() public pure override(IShareVault, IFlowVault) returns (bytes32) {
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

    // ------------------------------------------- views for the ported vault properties

    /// @inheritdoc IShareVault
    function totalSupply() external view returns (uint256) {
        return totalShares;
    }

    /// @inheritdoc IShareVault
    function totalSupplySlot() external pure returns (bytes32) {
        return totalSharesSlot();
    }

    /// @inheritdoc IFlowVault
    function zeroAddressShares() external view returns (uint256) {
        return shares[address(0)];
    }

    /// @inheritdoc IFlowVault
    function zeroAddressSharesSlot() external pure returns (bytes32) {
        return sharesSlot(address(0));
    }

    /// @inheritdoc IFlowVault
    /// @dev Sums the flow the pending intents claim. Deposits bring assets in, withdrawals take
    ///      them out, transfers move shares between holders without touching assets. Holding the
    ///      diff against this is what catches a settlement whose arithmetic disagrees with the
    ///      request it purports to settle.
    function declaredNetFlow(bytes32[] calldata intentIds) external view returns (int256 net) {
        for (uint256 i; i < intentIds.length; ++i) {
            bytes memory action = _intents[intentIds[i]].action;
            if (action.length == 0) continue;
            VaultAction memory a = abi.decode(action, (VaultAction));
            if (a.kind == ActionKind.Deposit) {
                net += int256(a.amount);
            } else if (a.kind == ActionKind.Withdraw) {
                net -= int256(a.amount);
            }
        }
    }

    /// @notice Helper so callers and tests encode intents the same way the vault decodes them.
    function encodeAction(ActionKind kind, address from, address to, uint256 amount)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(VaultAction({kind: kind, from: from, to: to, amount: amount}));
    }
}
