// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../interfaces/IProperty.sol";
import {PropertyCatalogue} from "./PropertyCatalogue.sol";
import {IAdopterAdmin} from "./IAdopterAdmin.sol";

/// @title SubscriptionRegistry
/// @notice Who is protected by what, and with what configuration.
///
/// @dev The piece that makes one property deployment serve every adopter. Previously a property's
///      configuration lived in its constructor, so `new Monotonic([slots])` was bound to a single
///      contract and "subscribing" meant deploying your own copy — a library in name only.
///
///      Here configuration is stored per (adopter, property) and the property reads it at check time.
///      A property becomes stateless code; subscribing becomes a config write. One `Monotonic` on a
///      chain protects everyone who asks it to.
///
///      Authorisation goes through `IAdopterAdmin` rather than `msg.sender == adopter`, because a
///      contract already deployed cannot call `subscribe` and never will.
///
///      `checkAll` is what a guarded contract calls inside its own transaction. A rule that fails
///      makes the call revert, so the security is the Solidity here and nothing else — no operators,
///      no quorum, no off-chain party.
contract SubscriptionRegistry {
    PropertyCatalogue public immutable catalogue;
    IAdopterAdmin public adminVerifier;
    address public owner;

    mapping(address => address[]) private _subscriptions;
    mapping(address => mapping(address => uint256)) private _index;
    mapping(address => mapping(address => bool)) public isSubscribed;
    mapping(address => mapping(address => bytes)) private _config;

    error NotOwner();
    error NotAdopterAdmin(address adopter, address who);
    error NotListed(address property);
    error AlreadySubscribed(address adopter, address property);
    error NotSubscribedError(address adopter, address property);
    error EmptyConfigForSelfContained(address property);

    event Subscribed(address indexed adopter, address indexed property, bytes config);
    event ConfigUpdated(address indexed adopter, address indexed property, bytes config);
    event Unsubscribed(address indexed adopter, address indexed property);
    event AdminVerifierChanged(address from, address to);

    constructor(PropertyCatalogue _catalogue, IAdopterAdmin _adminVerifier, address _owner) {
        catalogue = _catalogue;
        adminVerifier = _adminVerifier;
        owner = _owner;
    }

    modifier onlyAdopterAdmin(address adopter) {
        if (!adminVerifier.isAdopterAdmin(adopter, msg.sender)) revert NotAdopterAdmin(adopter, msg.sender);
        _;
    }

    function setAdminVerifier(IAdopterAdmin v) external {
        if (msg.sender != owner) revert NotOwner();
        emit AdminVerifierChanged(address(adminVerifier), address(v));
        adminVerifier = v;
    }

    // ------------------------------------------------------------ subscription

    /// @notice Put `adopter` under `property`, configured by `config`.
    /// @dev Rejects an empty config for a self-contained property, since those are the ones whose
    ///      entire behaviour comes from configuration — a `SlotProtection` with no slots protects
    ///      nothing while reading as protected, which is the worst possible state for a guard.
    function subscribe(address adopter, IProperty property, bytes calldata config) external onlyAdopterAdmin(adopter) {
        if (!catalogue.isListed(address(property))) revert NotListed(address(property));
        if (isSubscribed[adopter][address(property)]) revert AlreadySubscribed(adopter, address(property));

        uint256 id = catalogue.idOf(address(property));
        if (catalogue.listing(id).selfContained && config.length == 0) {
            revert EmptyConfigForSelfContained(address(property));
        }

        isSubscribed[adopter][address(property)] = true;
        _index[adopter][address(property)] = _subscriptions[adopter].length;
        _subscriptions[adopter].push(address(property));
        _config[adopter][address(property)] = config;
        emit Subscribed(adopter, address(property), config);
    }

    function updateConfig(address adopter, IProperty property, bytes calldata config)
        external
        onlyAdopterAdmin(adopter)
    {
        if (!isSubscribed[adopter][address(property)]) {
            revert NotSubscribedError(adopter, address(property));
        }
        _config[adopter][address(property)] = config;
        emit ConfigUpdated(adopter, address(property), config);
    }

    function unsubscribe(address adopter, IProperty property) external onlyAdopterAdmin(adopter) {
        if (!isSubscribed[adopter][address(property)]) revert NotSubscribedError(adopter, address(property));

        uint256 i = _index[adopter][address(property)];
        address[] storage subs = _subscriptions[adopter];
        uint256 last = subs.length - 1;
        if (i != last) {
            address moved = subs[last];
            subs[i] = moved;
            _index[adopter][moved] = i;
        }
        subs.pop();

        delete _index[adopter][address(property)];
        delete isSubscribed[adopter][address(property)];
        delete _config[adopter][address(property)];
        emit Unsubscribed(adopter, address(property));
    }

    // ------------------------------------------------------------------ reads

    /// @notice The configuration a property should evaluate `adopter` against.
    /// @dev Properties call this with `ctx.target` and `address(this)`.
    function configOf(address adopter, address property) external view returns (bytes memory) {
        return _config[adopter][property];
    }

    function subscriptionsOf(address adopter) external view returns (address[] memory) {
        return _subscriptions[adopter];
    }

    function subscriptionCount(address adopter) external view returns (uint256) {
        return _subscriptions[adopter].length;
    }

    /// @notice Evaluate every rule `adopter` subscribes to.
    /// @dev Called by the adopter mid-transaction via `Guarded`, and by monitors out of band. Same
    ///      answer either way.
    function checkAll(address adopter, TransitionContext calldata ctx)
        external
        view
        returns (bool ok, string memory propertyName, string memory reason)
    {
        address[] storage subs = _subscriptions[adopter];
        for (uint256 i; i < subs.length; ++i) {
            IProperty p = IProperty(subs[i]);
            (bool held, string memory why) = p.check(ctx);
            if (!held) return (false, p.name(), why);
        }
        return (true, "", "");
    }
}
