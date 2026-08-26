// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, SlotWrite, TransitionContext} from "../interfaces/IProperty.sol";

interface IPreviewable {
    /// @notice The diff the adopter's own spec says these intents should produce.
    function previewFor(bytes32[] calldata intentIds) external view returns (SlotWrite[] memory);
}

/// @title SpecConformance
/// @notice The attested diff must be exactly the diff the adopter's spec produces.
///
/// @dev Generalises Phylax's `ERC4626PreviewAssertion` — "preview functions are consistent with the
///      actual results" — into the strongest property in this library. If it holds, the operator
///      computed precisely what the contract said it would, and every other property about the
///      transition follows from the spec rather than from the diff.
///
///      **And it is exactly inverse to Gas Killer's reason for existing.** Checking it requires
///      evaluating the spec, which for the contracts Gas Killer is *for* is the expensive
///      computation that could not run on-chain in the first place. Register this where the spec is
///      cheap and the property set is what you are buying — a vault, a registry, an accounting
///      system. It is unusable on the `OnchainLife`-shaped case, where the whole point is that
///      nobody can afford to recompute the result.
///
///      Where it does not fit, the narrower properties are what you get: they constrain the diff's
///      *shape* without recomputing its *content*. That is the real trade this model makes, and this
///      contract is the clearest place to see it.
contract SpecConformance is IProperty {
    function name() external pure returns (string memory) {
        return "SpecConformance";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        SlotWrite[] memory expected = IPreviewable(ctx.target).previewFor(ctx.intentIds);

        if (expected.length != ctx.writes.length) {
            return (false, "diff has a different number of writes than the spec");
        }

        // Order-independent comparison: the spec and the operator may enumerate slots differently
        // without disagreeing about the transition. Quadratic, which is unremarkable off-chain.
        bool[] memory matched = new bool[](expected.length);
        for (uint256 i; i < ctx.writes.length; ++i) {
            bool found;
            for (uint256 j; j < expected.length; ++j) {
                if (matched[j]) continue;
                if (
                    expected[j].slot == ctx.writes[i].slot && expected[j].oldValue == ctx.writes[i].oldValue
                        && expected[j].newValue == ctx.writes[i].newValue
                ) {
                    matched[j] = true;
                    found = true;
                    break;
                }
            }
            if (!found) return (false, "diff contains a write the spec does not produce");
        }
        return (true, "");
    }
}
