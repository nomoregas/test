// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty} from "../interfaces/IProperty.sol";

/// @title PropertyCatalogue
/// @notice The published list of properties an adopter can subscribe to.
///
/// @dev What turns 21 contracts into a library. Without it, integrating means finding a property's
///      address somewhere and trusting it — there is no way to ask what exists, what a listing is
///      called, or whether the deployment you are about to point at is the audited one.
///
///      Listings are versioned and immutable once published: a property's behaviour is a security
///      assumption, so silently repointing a listing at new code would repoint every subscriber's
///      guarantees with it. A revision is a new listing, and subscribers migrate deliberately.
///      Deprecation marks a listing as unrecommended without breaking anyone already on it.
contract PropertyCatalogue {
    struct Listing {
        IProperty property;
        string name;
        uint16 version;
        bool deprecated;
        /// @notice Whether the property reads only the diff, so it needs nothing from the adopter.
        bool selfContained;
    }

    address public owner;
    Listing[] private _listings;
    mapping(address => uint256) private _idByAddress;
    mapping(address => bool) public isListed;

    error NotOwner();
    error AlreadyListed(address property);
    error UnknownListing(uint256 id);

    event Listed(uint256 id, address property, string name, uint16 version, bool selfContained);
    event Deprecated(uint256 id);
    event OwnerTransferred(address from, address to);

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function list(IProperty property, string calldata name, uint16 version, bool selfContained)
        external
        onlyOwner
        returns (uint256 id)
    {
        if (isListed[address(property)]) revert AlreadyListed(address(property));
        id = _listings.length;
        _listings.push(
            Listing({property: property, name: name, version: version, deprecated: false, selfContained: selfContained})
        );
        _idByAddress[address(property)] = id;
        isListed[address(property)] = true;
        emit Listed(id, address(property), name, version, selfContained);
    }

    /// @notice Mark a listing as no longer recommended.
    /// @dev Does not unsubscribe anyone. Breaking live subscribers to signal a preference would make
    ///      deprecation more dangerous than the thing being deprecated.
    function deprecate(uint256 id) external onlyOwner {
        if (id >= _listings.length) revert UnknownListing(id);
        _listings[id].deprecated = true;
        emit Deprecated(id);
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnerTransferred(owner, to);
        owner = to;
    }

    function count() external view returns (uint256) {
        return _listings.length;
    }

    function listing(uint256 id) external view returns (Listing memory) {
        if (id >= _listings.length) revert UnknownListing(id);
        return _listings[id];
    }

    function idOf(address property) external view returns (uint256) {
        if (!isListed[property]) revert UnknownListing(0);
        return _idByAddress[property];
    }
}
