// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

/// @notice The endpoints a vault exposes so its share price can be checked.
/// @dev Slots as well as values: the values give the post-state, the slots let `PreState`
///      recover the pre-state from the diff. That pairing is what replaces a second EVM fork.
interface IShareVault {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssetsSlot() external view returns (bytes32);
    function totalSupplySlot() external view returns (bytes32);
}

/// @title SharePriceFloor
/// @notice Assets per share may not fall by more than a configured tolerance.
///
/// @dev Port of Phylax's `ERC4626SharePriceAssertion`. Catches the dilution class: an entry or exit
///      that leaves remaining holders worse off per share, whether through a rounding direction that
///      favours the caller, a donation attack, or an accounting bug in the mint path.
///
///      Increases are permitted — yield accrual raises the price and that is the point of the vault.
///      Only the downward move is bounded, and `toleranceBps` exists because legitimate fee accrual
///      and loss recognition do move it down a little.
///
///      Follows their endpoint rule: compare pre against post and ignore anything in between.
///      Healthy operations update assets and supply at different internal boundaries, so an
///      intermediate pair describes a state that never existed at a transition boundary.
///      Empty-supply endpoints have no holder share price and are skipped, exactly as they skip them.
///
///      Compares `assetsPost * supplyPre` against `assetsPre * supplyPost` rather than dividing, so
///      a small vault is not judged by a share price that integer division has flattened to zero.
contract SharePriceFloor is IProperty {
    using PreState for TransitionContext;

    uint256 public immutable toleranceBps;

    constructor(uint256 _toleranceBps) {
        toleranceBps = _toleranceBps;
    }

    function name() external pure returns (string memory) {
        return "SharePriceFloor";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        IShareVault v = IShareVault(ctx.target);

        // Both endpoints come from the diff, with the live read as the fallback for a slot the
        // transition never touched. That makes the property independent of *when* it is evaluated:
        // an operator checking a proposed diff before applying it and `settle` re-checking after
        // applying it both reach the same verdict. Reading the post endpoint from the view function
        // instead would silently compare pre against pre in the operator's case — the same class of
        // mistake as using a no-diff health check as an oracle.
        bytes32 assetsSlot = v.totalAssetsSlot();
        bytes32 supplySlot = v.totalSupplySlot();
        bytes32 assetsNow = bytes32(v.totalAssets());
        bytes32 supplyNow = bytes32(v.totalSupply());

        uint256 assetsPre = uint256(c.pre(assetsSlot, assetsNow));
        uint256 assetsPost = uint256(c.post(assetsSlot, assetsNow));
        uint256 supplyPre = uint256(c.pre(supplySlot, supplyNow));
        uint256 supplyPost = uint256(c.post(supplySlot, supplyNow));

        // No holders at either endpoint means there is no share price to protect.
        if (supplyPre == 0 || supplyPost == 0) return (true, "");

        // pricePost >= pricePre * (1 - tolerance), cross-multiplied to avoid division.
        uint256 lhs = assetsPost * supplyPre * 10_000;
        uint256 rhs = assetsPre * supplyPost * (10_000 - toleranceBps);
        if (lhs < rhs) {
            return (false, "assets per share fell beyond tolerance");
        }
        return (true, "");
    }
}
