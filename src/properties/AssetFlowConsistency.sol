// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PreState} from "../PreState.sol";

/// @notice What a vault must expose for its accounting to be checked against declared flow.
interface IFlowVault {
    function totalAssets() external view returns (uint256);
    function totalAssetsSlot() external view returns (bytes32);
    /// @notice Net asset movement the transition claims to have caused, as signed units.
    /// @dev The adopter's own accounting of the flow, which this property holds the diff against.
    function declaredNetFlow(bytes32[] calldata intentIds) external view returns (int256);
    /// @notice Shares credited to the zero address, which must always be nothing.
    function zeroAddressShares() external view returns (uint256);
    /// @notice Slot holding the zero address's shares, so the check works either side of apply.
    function zeroAddressSharesSlot() external view returns (bytes32);
}

/// @title AssetFlowConsistency
/// @notice The change in `totalAssets` matches the flow the transition claims, and the zero
///         address never holds shares.
///
/// @dev Port of Phylax's `ERC4626AssetFlowAssertion`, and the place where the two models diverge
///      most sharply. Theirs compares the change in `totalAssets` against the *observed* net ERC-20
///      flow, read from the transaction journal via `getErc20Transfers` — which is what lets it
///      catch transfer-fee tokens, rebasing tokens, and accounting that has drifted from the actual
///      token ledger.
///
///      A property here cannot see a token contract's ledger; the diff describes the adopter's own
///      storage. So this checks internal consistency instead: `Δ totalAssets` must equal the flow
///      the adopter itself declares for these intents. That catches accounting bugs and diffs whose
///      arithmetic disagrees with the request they claim to settle. It does **not** catch a token
///      that moved a different amount than the vault believed — for that the operator would have to
///      attest to foreign state, which the diff has no way to express.
///
///      Worth stating plainly rather than papering over: this is a real capability gap, not a
///      different flavour of the same check.
contract AssetFlowConsistency is IProperty {
    using PreState for TransitionContext;

    function name() external pure returns (string memory) {
        return "AssetFlowConsistency";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        TransitionContext memory c = ctx;
        IFlowVault v = IFlowVault(ctx.target);

        // Read through the diff rather than off live state, so a transition that credits the zero
        // address is caught when the operator inspects it, not only once it has landed.
        if (uint256(c.post(v.zeroAddressSharesSlot(), bytes32(v.zeroAddressShares()))) != 0) {
            return (false, "zero address holds shares");
        }

        uint256 assetsPost = v.totalAssets();
        bytes32 slot = v.totalAssetsSlot();
        int256 observed = c.delta(slot, bytes32(assetsPost));
        int256 declared = v.declaredNetFlow(ctx.intentIds);

        if (observed != declared) {
            return (false, "totalAssets delta disagrees with declared net flow");
        }
        return (true, "");
    }
}
