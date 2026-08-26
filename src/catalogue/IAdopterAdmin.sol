// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/// @notice Decides who may configure guard subscriptions on behalf of an adopter.
///
/// @dev Needed because the obvious answer does not work. A contract being written now can call
///      `subscribe` itself, so `msg.sender == adopter` suffices. A contract already deployed cannot —
///      it has no such function and never will. Something off-contract has to vouch for who speaks
///      for it, and the registry cannot determine that generically.
///
///      Phylax hit the same wall and solved it with pluggable admin verifiers on their `StateOracle`
///      (owner / whitelist / super-admin). This is that idea, and the audit listed its absence as a
///      gap on our side.
interface IAdopterAdmin {
    function isAdopterAdmin(address adopter, address who) external view returns (bool);
}

interface IOwnableLike {
    function owner() external view returns (address);
}

/// @notice The adopter speaks for itself. Correct for contracts written against this system.
contract AdminVerifierSelf is IAdopterAdmin {
    function isAdopterAdmin(address adopter, address who) external pure returns (bool) {
        return adopter == who;
    }
}

/// @notice Whoever `owner()` returns speaks for the adopter.
/// @dev Fits the large population of already-deployed Ownable contracts without touching them, which
///      is the whole point of the additive path. Fails closed if the call reverts or the adopter has
///      no `owner()`, rather than falling back to something permissive.
contract AdminVerifierOwnable is IAdopterAdmin {
    function isAdopterAdmin(address adopter, address who) external view returns (bool) {
        (bool ok, bytes memory data) = adopter.staticcall(abi.encodeCall(IOwnableLike.owner, ()));
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (address)) == who;
    }
}

/// @notice A curated binding, maintained by the catalogue operator.
/// @dev The onboarding path for an adopter whose admin cannot be read on-chain — a multisig-governed
///      protocol, a proxy whose admin lives elsewhere. Verification happens off-chain and the result
///      is recorded here, which is a trust assumption worth naming rather than hiding: whoever owns
///      this verifier can hand an adopter's guard configuration to anyone.
contract AdminVerifierAllowlist is IAdopterAdmin {
    address public owner;
    mapping(address => mapping(address => bool)) public allowed;

    error NotOwner();

    event AdminSet(address adopter, address who, bool allowed);

    constructor(address _owner) {
        owner = _owner;
    }

    function setAdmin(address adopter, address who, bool value) external {
        if (msg.sender != owner) revert NotOwner();
        allowed[adopter][who] = value;
        emit AdminSet(adopter, who, value);
    }

    function isAdopterAdmin(address adopter, address who) external view returns (bool) {
        return allowed[adopter][who];
    }
}
