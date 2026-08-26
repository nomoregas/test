// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {SubscriptionRegistry} from "./SubscriptionRegistry.sol";

/// @notice Base for a stateless, catalogue-listed property.
///
/// @dev Holds only the registry address — one immutable, set once per chain — and reads its
///      per-adopter configuration at check time. That is the whole difference between a property that
///      is a shared library and one that has to be redeployed per integrator.
///
///      `_rawConfig` fails closed on an unconfigured adopter. A `SlotProtection` with no slots would
///      otherwise pass every transition while appearing in the subscription list, which is worse than
///      no guard at all: it reads as protection. `SubscriptionRegistry.subscribe` also refuses an
///      empty config for these properties, so this is the second of two locks on the same door.
abstract contract Configured {
    SubscriptionRegistry public immutable subscriptions;

    constructor(SubscriptionRegistry _subscriptions) {
        subscriptions = _subscriptions;
    }

    function _rawConfig(address adopter) internal view returns (bytes memory config, bool present) {
        config = subscriptions.configOf(adopter, address(this));
        present = config.length != 0;
    }
}
