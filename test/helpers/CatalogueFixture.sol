// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty} from "../../src/interfaces/IProperty.sol";
import {PropertyCatalogue} from "../../src/catalogue/PropertyCatalogue.sol";
import {SubscriptionRegistry} from "../../src/catalogue/SubscriptionRegistry.sol";
import {AdminVerifierAllowlist} from "../../src/catalogue/IAdopterAdmin.sol";

/// @notice Catalogue plumbing for tests, so a property test reads as a property test.
/// @dev Uses the allowlist verifier because a test contract is not the adopter and a `MockAdopter`
///      has no `owner()`. That is also the realistic onboarding path for an already-deployed
///      contract whose admin cannot be read on-chain.
abstract contract CatalogueFixture {
    PropertyCatalogue internal cat;
    SubscriptionRegistry internal subs;
    AdminVerifierAllowlist internal adminVerifier;

    function _deployCatalogue() internal {
        cat = new PropertyCatalogue(address(this));
        adminVerifier = new AdminVerifierAllowlist(address(this));
        subs = new SubscriptionRegistry(cat, adminVerifier, address(this));
    }

    function _listAndSubscribe(IProperty property, string memory name, address adopter, bytes memory config) internal {
        cat.list(property, name, 1, true);
        adminVerifier.setAdmin(adopter, address(this), true);
        subs.subscribe(adopter, property, config);
    }
}
