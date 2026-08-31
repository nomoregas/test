// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IProperty, SlotWrite, TransitionContext, CallEntry, LogEntry} from "../src/interfaces/IProperty.sol";
import {PropertyCatalogue} from "../src/catalogue/PropertyCatalogue.sol";
import {SubscriptionRegistry} from "../src/catalogue/SubscriptionRegistry.sol";
import {AdminVerifierSelf, AdminVerifierOwnable, AdminVerifierAllowlist} from "../src/catalogue/IAdopterAdmin.sol";
import {SlotProtection} from "../src/properties/SlotProtection.sol";
import {Monotonic} from "../src/properties/Monotonic.sol";

contract OwnedThing {
    address public owner;

    constructor(address o) {
        owner = o;
    }
}

contract SelfSubscribingThing {
    function doSubscribe(SubscriptionRegistry subs, IProperty p, bytes calldata config) external {
        subs.subscribe(address(this), p, config);
    }
}

/// @notice The subscription model: one property deployment, many adopters, config per adopter.
contract CatalogueTest is Test {
    PropertyCatalogue cat;
    SubscriptionRegistry subs;
    AdminVerifierAllowlist allowlist;

    SlotProtection slotProtection;
    Monotonic monotonic;

    address adopterA = address(0xA1);
    address adopterB = address(0xB2);
    address stranger = address(0xDEAD);

    bytes32 constant SLOT_A = bytes32(uint256(0xAA));
    bytes32 constant SLOT_B = bytes32(uint256(0xBB));

    function setUp() public {
        cat = new PropertyCatalogue(address(this));
        allowlist = new AdminVerifierAllowlist(address(this));
        subs = new SubscriptionRegistry(cat, allowlist, address(this));

        slotProtection = new SlotProtection(subs);
        monotonic = new Monotonic(subs);
        cat.list(slotProtection, "SlotProtection", 1, true);
        cat.list(monotonic, "Monotonic", 1, true);

        allowlist.setAdmin(adopterA, address(this), true);
        allowlist.setAdmin(adopterB, address(this), true);
    }

    function _slots(bytes32 a) internal pure returns (bytes32[] memory s) {
        s = new bytes32[](1);
        s[0] = a;
    }

    function _ctx(address target, bytes32 slot) internal pure returns (TransitionContext memory) {
        SlotWrite[] memory w = new SlotWrite[](1);
        w[0] = SlotWrite(slot, bytes32(uint256(9)), bytes32(uint256(5)));
        return TransitionContext({
            target: target,
            transitionIndex: 0,
            intentIds: new bytes32[](0),
            writes: w,
            calls: new CallEntry[](0),
            logs: new LogEntry[](0)
        });
    }

    // ------------------------------------------------------------- the payoff

    /// @notice One deployment protects two adopters under different configurations.
    /// @dev The whole point of the refactor. Before, config lived in the constructor, so a shared
    ///      property was impossible: every integrator deployed their own copy and the "library" was a
    ///      library in name only.
    function test_oneDeploymentServesManyAdoptersWithDifferentConfig() public {
        subs.subscribe(adopterA, slotProtection, abi.encode(_slots(SLOT_A)));
        subs.subscribe(adopterB, slotProtection, abi.encode(_slots(SLOT_B)));

        // A freezes SLOT_A, so writing SLOT_A violates for A but not for B.
        (bool okA,) = slotProtection.check(_ctx(adopterA, SLOT_A));
        (bool okB,) = slotProtection.check(_ctx(adopterB, SLOT_A));
        assertFalse(okA);
        assertTrue(okB);

        // And symmetrically for SLOT_B.
        (bool okA2,) = slotProtection.check(_ctx(adopterA, SLOT_B));
        (bool okB2,) = slotProtection.check(_ctx(adopterB, SLOT_B));
        assertTrue(okA2);
        assertFalse(okB2);
    }

    function test_checkAllEvaluatesOnlyWhatTheAdopterSubscribedTo() public {
        subs.subscribe(adopterA, monotonic, abi.encode(_slots(SLOT_A)));
        // adopterB subscribes to nothing.

        (bool okA, string memory nameA,) = subs.checkAll(adopterA, _ctx(adopterA, SLOT_A));
        assertFalse(okA);
        assertEq(nameA, "Monotonic");

        (bool okB,,) = subs.checkAll(adopterB, _ctx(adopterB, SLOT_A));
        assertTrue(okB, "an adopter with no subscriptions is unguarded, not blocked");
    }

    function test_subscriptionsAreListable() public {
        subs.subscribe(adopterA, slotProtection, abi.encode(_slots(SLOT_A)));
        subs.subscribe(adopterA, monotonic, abi.encode(_slots(SLOT_B)));
        assertEq(subs.subscriptionCount(adopterA), 2);
        assertEq(subs.subscriptionsOf(adopterA).length, 2);
    }

    function test_configCanBeUpdatedWithoutResubscribing() public {
        subs.subscribe(adopterA, slotProtection, abi.encode(_slots(SLOT_A)));
        (bool ok,) = slotProtection.check(_ctx(adopterA, SLOT_B));
        assertTrue(ok);

        subs.updateConfig(adopterA, slotProtection, abi.encode(_slots(SLOT_B)));
        (bool ok2,) = slotProtection.check(_ctx(adopterA, SLOT_B));
        assertFalse(ok2, "the new config takes effect immediately");
    }

    function test_unsubscribeRemovesProtection() public {
        subs.subscribe(adopterA, slotProtection, abi.encode(_slots(SLOT_A)));
        subs.unsubscribe(adopterA, slotProtection);
        assertEq(subs.subscriptionCount(adopterA), 0);
        assertFalse(subs.isSubscribed(adopterA, address(slotProtection)));
        (bool ok,,) = subs.checkAll(adopterA, _ctx(adopterA, SLOT_A));
        assertTrue(ok);
    }

    // ----------------------------------------------------------- fail-closed

    /// @notice An unconfigured self-contained property refuses everything rather than allowing it.
    /// @dev A `SlotProtection` with no slots would otherwise pass every transition while appearing in
    ///      the subscription list — protection in name only, which is worse than no guard because it
    ///      reads as one.
    function test_unconfiguredPropertyFailsClosed() public view {
        (bool ok, string memory reason) = slotProtection.check(_ctx(adopterA, SLOT_A));
        assertFalse(ok);
        assertEq(reason, "property is not configured for this adopter");
    }

    function test_subscribeRejectsEmptyConfigForSelfContained() public {
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionRegistry.EmptyConfigForSelfContained.selector, address(slotProtection))
        );
        subs.subscribe(adopterA, slotProtection, "");
    }

    // -------------------------------------------------------- authorisation

    function test_strangerCannotSubscribeOnBehalfOfAnAdopter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionRegistry.NotAdopterAdmin.selector, adopterA, stranger));
        subs.subscribe(adopterA, slotProtection, abi.encode(_slots(SLOT_A)));
    }

    function test_unlistedPropertyCannotBeSubscribedTo() public {
        SlotProtection rogue = new SlotProtection(subs);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionRegistry.NotListed.selector, address(rogue)));
        subs.subscribe(adopterA, rogue, abi.encode(_slots(SLOT_A)));
    }

    /// @notice A contract written against this system authorises itself.
    function test_selfVerifierLetsAnAdopterSubscribeItself() public {
        SubscriptionRegistry s2 = new SubscriptionRegistry(cat, new AdminVerifierSelf(), address(this));
        SlotProtection p = new SlotProtection(s2);
        cat.list(p, "SlotProtection", 1, true);

        SelfSubscribingThing thing = new SelfSubscribingThing();
        thing.doSubscribe(s2, p, abi.encode(_slots(SLOT_A)));
        assertTrue(s2.isSubscribed(address(thing), address(p)));
    }

    /// @notice An already-deployed Ownable contract is onboarded by its owner, untouched.
    function test_ownableVerifierLetsTheOwnerSubscribeADeployedContract() public {
        SubscriptionRegistry s2 = new SubscriptionRegistry(cat, new AdminVerifierOwnable(), address(this));
        SlotProtection p = new SlotProtection(s2);
        cat.list(p, "SlotProtection", 1, true);

        OwnedThing legacy = new OwnedThing(address(this));
        s2.subscribe(address(legacy), p, abi.encode(_slots(SLOT_A)));
        assertTrue(s2.isSubscribed(address(legacy), address(p)));

        vm.prank(stranger);
        vm.expectRevert();
        s2.subscribe(address(legacy), p, abi.encode(_slots(SLOT_B)));
    }

    /// @notice A contract with no `owner()` fails closed under the Ownable verifier.
    /// @dev The staticcall reverts; falling back to something permissive here would let anyone
    ///      configure the guard on any contract that happens not to be Ownable.
    function test_ownableVerifierFailsClosedWithoutAnOwner() public {
        AdminVerifierOwnable v = new AdminVerifierOwnable();
        assertFalse(v.isAdopterAdmin(address(new SelfSubscribingThing()), address(this)));
    }

    // ------------------------------------------------------------- catalogue

    function test_listingsAreEnumerable() public view {
        assertEq(cat.count(), 2);
        PropertyCatalogue.Listing memory l = cat.listing(cat.idOf(address(monotonic)));
        assertEq(l.name, "Monotonic");
        assertEq(l.version, 1);
        assertTrue(l.selfContained);
        assertFalse(l.deprecated);
    }

    function test_deprecationDoesNotBreakExistingSubscribers() public {
        subs.subscribe(adopterA, slotProtection, abi.encode(_slots(SLOT_A)));
        cat.deprecate(cat.idOf(address(slotProtection)));

        assertTrue(cat.listing(cat.idOf(address(slotProtection))).deprecated);
        (bool ok,,) = subs.checkAll(adopterA, _ctx(adopterA, SLOT_A));
        assertFalse(ok, "a deprecated property still protects whoever is subscribed");
    }

    function test_cannotListTheSamePropertyTwice() public {
        vm.expectRevert(abi.encodeWithSelector(PropertyCatalogue.AlreadyListed.selector, address(slotProtection)));
        cat.list(slotProtection, "SlotProtection", 2, true);
    }

    function test_onlyOwnerCanList() public {
        SlotProtection p = new SlotProtection(subs);
        vm.prank(stranger);
        vm.expectRevert(PropertyCatalogue.NotOwner.selector);
        cat.list(p, "SlotProtection", 1, true);
    }
}
