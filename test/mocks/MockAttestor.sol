// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IAttestor} from "../../src/interfaces/IProperty.sol";

/// @notice Stands in for the real quorum check so the guard layer is testable without EigenLayer.
/// @dev Production swaps this for a wrapper around GasKillerSDK's aggregated BLS (or aggregate
///      Schnorr) verification. The guard layer deliberately knows nothing about which scheme
///      signed — only whether the digest carries quorum approval.
contract MockAttestor is IAttestor {
    /// @dev An attestation is "valid" when it is the digest signed by a known operator key.
    ///      Crude, but it exercises the real failure mode: a diff nobody attested to is refused.
    mapping(bytes32 => bool) public attested;
    bool public acceptAll;

    function setAcceptAll(bool v) external {
        acceptAll = v;
    }

    function attest(bytes32 digest) external {
        attested[digest] = true;
    }

    function verify(bytes32 digest, bytes calldata attestation) external view returns (bool) {
        if (acceptAll) return true;
        if (attestation.length == 32 && bytes32(attestation) == digest) return attested[digest];
        return false;
    }
}
