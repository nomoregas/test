// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GuardedState} from "../src/GuardedState.sol";
import {PropertyRegistry} from "../src/PropertyRegistry.sol";
import {SlotWrite} from "../src/interfaces/IProperty.sol";
import {SlotDomain} from "../src/properties/SlotDomain.sol";
import {Conservation} from "../src/properties/Conservation.sol";
import {Solvency} from "../src/properties/Solvency.sol";
import {ConcentrationCap} from "../src/properties/ConcentrationCap.sol";
import {GuardedVault} from "../src/examples/GuardedVault.sol";
import {MockAttestor} from "./mocks/MockAttestor.sol";

/// @notice An operator that behaves the way the product assumes operators behave.
/// @dev The interesting part is `_operatorSettle`. A real operator simulates the transition
///      off-chain, evaluates every property on the resulting post-state, and signs only if they
///      all hold. We reproduce that faithfully in-EVM: snapshot, apply, check, roll back, and
///      only settle for real when the check passed. So this handler is not "the honest path" by
///      construction — it is honest because it runs the same veto a node would.
contract VaultHandler is Test {
    GuardedVault public vault;
    MockAttestor public attestor;

    address[] public actors;
    uint256 public settled;
    uint256 public vetoed;

    constructor(GuardedVault _vault, MockAttestor _attestor) {
        vault = _vault;
        attestor = _attestor;
    }

    function _actor(uint256 seed) internal view returns (address) {
        if (actors.length == 0) return address(0);
        return actors[seed % actors.length];
    }

    function addActor(uint256 seed) external {
        address a = address(uint160(uint256(keccak256(abi.encode("actor", seed)))));
        if (a == address(0) || vault.isHolder(a)) return;
        vm.prank(a);
        vault.register();
        actors.push(a);
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        if (a == address(0)) return;
        amount = bound(amount, 0, 1e21);
        vm.prank(a);
        bytes32 id = vault.request(abi.encode("deposit", amount));
        _operatorSettle(id, vault.previewDeposit(a, amount));
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == address(0) || to == address(0) || from == to) return;
        uint256 bal = vault.sharesOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        vm.prank(from);
        bytes32 id = vault.request(abi.encode("transfer", amount));
        _operatorSettle(id, vault.previewTransfer(from, to, amount));
    }

    /// @notice A diff that mints shares without moving the total. Operators must veto it.
    function attemptNonConservingMint(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        if (a == address(0)) return;
        amount = bound(amount, 1, 1e21);
        vm.prank(a);
        bytes32 id = vault.request(abi.encode("bad mint", amount));
        SlotWrite[] memory bad = new SlotWrite[](1);
        bad[0] = SlotWrite(vault.sharesSlot(a), bytes32(vault.sharesOf(a) + amount));
        _operatorSettle(id, bad);
    }

    /// @notice A diff crediting an address that never registered. Operators must veto it.
    function attemptPhantomCredit(uint256 seed, uint256 amount) external {
        address phantom = address(uint160(uint256(keccak256(abi.encode("phantom", seed)))));
        if (phantom == address(0) || vault.isHolder(phantom)) return;
        address a = _actor(seed);
        if (a == address(0)) return;
        amount = bound(amount, 1, 1e21);
        vm.prank(a);
        bytes32 id = vault.request(abi.encode("phantom", amount));
        SlotWrite[] memory bad = new SlotWrite[](1);
        bad[0] = SlotWrite(vault.sharesSlot(phantom), bytes32(amount));
        _operatorSettle(id, bad);
    }

    /// @notice A diff nobody attested to. Must never apply.
    function attemptUnattestedSettle(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        if (a == address(0)) return;
        amount = bound(amount, 1, 1e21);
        vm.prank(a);
        bytes32 id = vault.request(abi.encode("unattested", amount));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        SlotWrite[] memory writes = vault.previewDeposit(a, amount);
        try vault.settle(ids, writes, abi.encode(keccak256("garbage"))) {
            revert("an unattested diff was applied");
        } catch {
            vetoed++;
        }
    }

    /// @dev Simulate, evaluate, then decide — the operator's actual job.
    function _operatorSettle(bytes32 id, SlotWrite[] memory writes) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;

        bytes32 digest = vault.transitionDigest(ids, writes);
        attestor.attest(digest);

        // The index the diff is bound to, captured before settling increments it.
        uint256 idx = vault.transitionIndex();

        uint256 snap = vm.snapshotState();
        bool ok;
        try vault.settle(ids, writes, abi.encode(digest)) {
            // Evaluate against the post-state *and* the proposed diff. Using `checkNow()` here
            // instead would be a subtle hole: it passes an empty diff, so a diff-inspecting
            // property like SlotDomain sees nothing to object to and the phantom credit sails
            // through. An operator's oracle has to be the same ctx the property was written for.
            (ok,,) = vault.checkAll(ids, writes, idx);
        } catch {
            ok = false;
        }
        vm.revertToState(snap);

        if (!ok) {
            vetoed++;
            return;
        }

        // Re-attest: rolling back the snapshot restored the attestor's storage too.
        attestor.attest(vault.transitionDigest(ids, writes));
        vault.settle(ids, writes, abi.encode(vault.transitionDigest(ids, writes)));
        settled++;
    }
}

/// @notice Properties that must hold over every reachable sequence of requests and settlements.
/// @dev The vault runs in OffchainVeto mode here on purpose. Nothing on-chain re-checks anything,
///      so if these invariants hold it is because the operator's veto held — which is the claim
///      the product actually makes.
contract GuardedVaultInvariantTest is StdInvariant, Test {
    PropertyRegistry registry;
    MockAttestor attestor;
    GuardedVault vault;
    VaultHandler handler;

    function setUp() public {
        registry = new PropertyRegistry(address(this));
        attestor = new MockAttestor();
        vault = new GuardedVault(registry, attestor, GuardedState.Mode.OffchainVeto, 10_000);
        registry.add(new SlotDomain());
        registry.add(new Conservation());
        registry.add(new Solvency());
        registry.add(new ConcentrationCap(0));

        handler = new VaultHandler(vault, attestor);
        targetContract(address(handler));

        for (uint256 i; i < 5; ++i) {
            handler.addActor(i);
        }
    }

    /// @notice Every registered property holds after every settled transition.
    function invariant_allPropertiesHold() public view {
        (bool ok, string memory propertyName, string memory reason) = vault.checkNow();
        assertTrue(ok, string.concat("violated: ", propertyName, " - ", reason));
    }

    /// @notice The books balance, stated independently of the property contracts.
    /// @dev Deliberately not routed through the registry: if a property contract were itself
    ///      broken, `invariant_allPropertiesHold` could pass vacuously. This one cannot.
    function invariant_sumEqualsDeclaredTotal() public view {
        assertEq(vault.sumOfParts(), vault.declaredTotal());
    }

    /// @notice Claims never exceed backing.
    function invariant_solvent() public view {
        assertGe(vault.backingAssets(), vault.outstandingClaims());
    }

    /// @notice No value exists outside the registered holder set.
    /// @dev The phantom-holder property, asserted directly against reachable state rather than
    ///      through the sum that was blind to it.
    function invariant_noValueOffTheRegister() public view {
        uint256 n = vault.holderCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += vault.sharesOf(vault.holderAt(i));
        }
        assertEq(sum, vault.totalShares());
    }

    /// @notice Guards against the invariants passing vacuously.
    /// @dev An invariant suite where the honest path never settles anything, or where the attacks
    ///      are never actually attempted, holds trivially and tells you nothing. This drives the
    ///      handler directly and asserts both halves really happen: value accrues, and violating
    ///      diffs get refused. Without it, `reverts: 0` on every attack selector reads like
    ///      success when it could equally mean the attacks were never reachable.
    function test_handlerMakesRealProgressAndVetoesRealAttacks() public {
        handler.deposit(0, 500);
        handler.deposit(1, 300);
        assertGt(handler.settled(), 0, "honest operator never settled anything");
        assertGt(vault.totalShares(), 0, "no value ever entered the vault");
        assertEq(vault.sumOfParts(), vault.totalShares());

        uint256 vetoesBefore = handler.vetoed();
        uint256 totalBefore = vault.totalShares();

        handler.attemptNonConservingMint(0, 1000);
        handler.attemptPhantomCredit(1, 1000);
        handler.attemptUnattestedSettle(0, 1000);

        assertEq(handler.vetoed(), vetoesBefore + 3, "an attack was not refused");
        assertEq(vault.totalShares(), totalBefore, "an attack moved value");
        (bool ok,,) = vault.checkNow();
        assertTrue(ok);
    }
}
