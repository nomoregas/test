// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "./interfaces/IProperty.sol";

/// @notice The set of properties enforced on one guarded contract.
/// @dev Properties live in their own contracts rather than inside the guarded contract for
///      one reason that only holds because evaluation is off-chain: composability is free.
///      A team can add a property to a live contract without redeploying it, reuse a
///      library property across contracts, and pay nothing on-chain for either.
contract PropertyRegistry {
    address public owner;

    IProperty[] private _properties;
    mapping(address => bool) public isRegistered;

    error NotOwner();
    error AlreadyRegistered(address property);
    error NotFound(address property);

    event PropertyAdded(address property, string name);
    event PropertyRemoved(address property);
    event OwnerTransferred(address from, address to);

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function add(IProperty property) external onlyOwner {
        if (isRegistered[address(property)]) revert AlreadyRegistered(address(property));
        isRegistered[address(property)] = true;
        _properties.push(property);
        emit PropertyAdded(address(property), property.name());
    }

    function remove(IProperty property) external onlyOwner {
        if (!isRegistered[address(property)]) revert NotFound(address(property));
        isRegistered[address(property)] = false;
        uint256 n = _properties.length;
        for (uint256 i; i < n; ++i) {
            if (address(_properties[i]) == address(property)) {
                _properties[i] = _properties[n - 1];
                _properties.pop();
                break;
            }
        }
        emit PropertyRemoved(address(property));
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnerTransferred(owner, to);
        owner = to;
    }

    function count() external view returns (uint256) {
        return _properties.length;
    }

    function at(uint256 i) external view returns (IProperty) {
        return _properties[i];
    }

    /// @notice Evaluate every registered property against `ctx`.
    /// @dev Returns on the first violation. Callers get the offending property's name so a
    ///      rejection is actionable rather than an opaque "transition refused".
    function checkAll(TransitionContext calldata ctx)
        external
        view
        returns (bool ok, string memory propertyName, string memory reason)
    {
        uint256 n = _properties.length;
        for (uint256 i; i < n; ++i) {
            (bool held, string memory why) = _properties[i].check(ctx);
            if (!held) return (false, _properties[i].name(), why);
        }
        return (true, "", "");
    }
}
