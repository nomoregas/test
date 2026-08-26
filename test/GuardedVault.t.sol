// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {GuardedState} from "../src/GuardedState.sol";
import {PropertyRegistry} from "../src/PropertyRegistry.sol";
import {SlotWrite} from "../src/interfaces/IProperty.sol";
import {SlotDomain} from "../src/properties/SlotDomain.sol";
import {Conservation} from "../src/properties/Conservation.sol";
import {Solvency} from "../src/properties/Solvency.sol";
import {ConcentrationCap} from "../src/properties/ConcentrationCap.sol";
import {GuardedVault} from "../src/examples/GuardedVault.sol";
import {MockAttestor} from "./mocks/MockAttestor.sol";

contract GuardedVaultTest is Test {
    PropertyRegistry registry;
    MockAttestor attestor;
    GuardedVault vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address phantom = address(0xBAD);

    function _deploy(GuardedState.Mode mode) internal {
        // 10_000 bps = no concentration constraint, so the other properties are what is under test.
        _deployWithCap(mode, 10_000, 0);
    }

    function _deployWithCap(GuardedState.Mode mode, uint256 capBps, uint256 minTotalToEnforce) internal {
        registry = new PropertyRegistry(address(this));
        attestor = new MockAttestor();
        vault = new GuardedVault(registry, attestor, mode, capBps);
        registry.add(new SlotDomain());
        registry.add(new Conservation());
        registry.add(new Solvency());
        registry.add(new ConcentrationCap(minTotalToEnforce));

        vm.prank(alice);
        vault.register();
        vm.prank(bob);
        vault.register();
    }

    /// @dev Produce a quorum attestation for a diff, without settling it.
    /// @dev Split out from `_settle` because `vm.expectRevert` binds to the *next* external call:
    ///      attesting inline would consume the expectation and the settle would go unchecked.
    function _attest(bytes32[] memory ids, SlotWrite[] memory writes) internal returns (bytes memory) {
        bytes32 digest = vault.transitionDigest(ids, writes);
        attestor.attest(digest);
        return abi.encode(digest);
    }

    /// @dev Attest and settle, the way an operator quorum would.
    function _settle(bytes32[] memory ids, SlotWrite[] memory writes) internal {
        vault.settle(ids, writes, _attest(ids, writes));
    }

    function _request(address who, bytes memory action) internal returns (bytes32[] memory ids) {
        vm.prank(who);
        bytes32 id = vault.request(action);
        ids = new bytes32[](1);
        ids[0] = id;
    }

    // ------------------------------------------------------------- happy path

    function test_depositSettlesAndConserves() public {
        _deploy(GuardedState.Mode.OnchainVerify);
        bytes32[] memory ids = _request(alice, abi.encode("deposit", 100));
        _settle(ids, vault.previewDeposit(alice, 100));

        assertEq(vault.shares(alice), 100);
        assertEq(vault.totalShares(), 100);
        assertEq(vault.sumOfParts(), vault.declaredTotal());
        assertEq(vault.transitionIndex(), 1);

        (bool ok,,) = vault.checkNow();
        assertTrue(ok);
    }

    function test_transferPreservesConservation() public {
        _deploy(GuardedState.Mode.OnchainVerify);
        _settle(_request(alice, abi.encode("deposit", 100)), vault.previewDeposit(alice, 100));
        _settle(_request(bob, abi.encode("deposit", 100)), vault.previewDeposit(bob, 100));

        _settle(_request(alice, abi.encode("transfer", 40)), vault.previewTransfer(alice, bob, 40));

        assertEq(vault.shares(alice), 60);
        assertEq(vault.shares(bob), 140);
        assertEq(vault.sumOfParts(), 200);
        assertEq(vault.declaredTotal(), 200);
    }

    function test_intentIsClearedOnSettle() public {
        _deploy(GuardedState.Mode.OffchainVeto);
        bytes32[] memory ids = _request(alice, abi.encode("deposit", 10));
        assertEq(vault.pendingCount(), 1);
        _settle(ids, vault.previewDeposit(alice, 10));
        assertEq(vault.pendingCount(), 0);
        assertTrue(vault.intent(ids[0]).settled);
    }

    // ---------------------------------------------------------- attestation gate

    function test_unattestedDiffIsRefused() public {
        _deploy(GuardedState.Mode.OffchainVeto);
        bytes32[] memory ids = _request(alice, abi.encode("deposit", 100));
        SlotWrite[] memory writes = vault.previewDeposit(alice, 100);

        vm.expectRevert(GuardedState.NotAttested.selector);
        vault.settle(ids, writes, abi.encode(keccak256("not the digest")));
    }

    function test_attestedDiffCannotBeReplayed() public {
        _deploy(GuardedState.Mode.OffchainVeto);
        bytes32[] memory ids = _request(alice, abi.encode("deposit", 100));
        SlotWrite[] memory writes = vault.previewDeposit(alice, 100);
        bytes32 digest = vault.transitionDigest(ids, writes);
        attestor.attest(digest);
        vault.settle(ids, writes, abi.encode(digest));

        // The digest binds the transition index, so the same attestation is dead on arrival.
        vm.expectRevert(GuardedState.NotAttested.selector);
        vault.settle(ids, writes, abi.encode(digest));
    }

    // ------------------------------------------------- properties are load-bearing

    function test_onchainVerifyBlocksNonConservingMint() public {
        _deploy(GuardedState.Mode.OnchainVerify);
        bytes32[] memory ids = _request(alice, abi.encode("mint out of thin air", 500));

        // Credit alice without moving the total: conservation must catch it.
        SlotWrite[] memory bad = new SlotWrite[](1);
        bad[0] = SlotWrite(vault.sharesSlot(alice), bytes32(uint256(500)));
        bytes memory att = _attest(ids, bad);

        vm.expectRevert(
            abi.encodeWithSelector(
                GuardedState.PropertyViolated.selector, "Conservation", "sum of parts != declared total"
            )
        );
        vault.settle(ids, bad, att);
    }

    function test_onchainVerifyBlocksInsolvency() public {
        _deploy(GuardedState.Mode.OnchainVerify);
        bytes32[] memory ids = _request(alice, abi.encode("claims without backing", 100));

        // Shares and total agree, but nothing backs them.
        SlotWrite[] memory bad = new SlotWrite[](2);
        bad[0] = SlotWrite(vault.sharesSlot(alice), bytes32(uint256(100)));
        bad[1] = SlotWrite(vault.totalSharesSlot(), bytes32(uint256(100)));
        bytes memory att = _attest(ids, bad);

        vm.expectRevert(
            abi.encodeWithSelector(
                GuardedState.PropertyViolated.selector, "Solvency", "backing assets < outstanding claims"
            )
        );
        vault.settle(ids, bad, att);
    }

    /// @notice The cap is exempt below its floor, so a vault can actually be bootstrapped.
    /// @dev Without the floor the first depositor holds 100% of the vault and every path to a
    ///      healthy distribution is refused — the property deadlocks the contract it guards.
    function test_concentrationCapIsExemptBelowItsFloor() public {
        _deployWithCap(GuardedState.Mode.OnchainVerify, 6000, 100);

        // total 50 < floor 100: alice holds 100% and settlement is still allowed.
        _settle(_request(alice, abi.encode("deposit", 50)), vault.previewDeposit(alice, 50));
        assertEq(vault.shares(alice), 50);
    }

    function test_onchainVerifyBlocksConcentrationBreach() public {
        _deployWithCap(GuardedState.Mode.OnchainVerify, 6000, 100);

        // Reach a healthy 50/50 split at the floor.
        _settle(_request(alice, abi.encode("deposit", 50)), vault.previewDeposit(alice, 50));
        _settle(_request(bob, abi.encode("deposit", 50)), vault.previewDeposit(bob, 50));

        // Alice to 110/160 = 68.75%, past the 60% cap.
        bytes32[] memory ids = _request(alice, abi.encode("deposit", 60));
        SlotWrite[] memory writes = vault.previewDeposit(alice, 60);
        bytes memory att = _attest(ids, writes);

        vm.expectRevert(
            abi.encodeWithSelector(
                GuardedState.PropertyViolated.selector, "ConcentrationCap", "a holder exceeds the concentration cap"
            )
        );
        vault.settle(ids, writes, att);
    }

    /// @notice The phantom-holder escape, closed.
    /// @dev Conservation alone cannot catch this: the sum only visits registered holders, so
    ///      value written to an unregistered address is invisible to it and the books still
    ///      balance. Bounding the diff's domain rejects the write regardless of its content.
    function test_slotDomainClosesPhantomHolderEscape() public {
        _deploy(GuardedState.Mode.OnchainVerify);
        bytes32[] memory ids = _request(alice, abi.encode("phantom", 1e18));

        SlotWrite[] memory bad = new SlotWrite[](1);
        bad[0] = SlotWrite(vault.sharesSlot(phantom), bytes32(uint256(1e18)));
        bytes memory att = _attest(ids, bad);

        // Conservation would have shrugged. SlotDomain does not.
        vm.expectRevert(
            abi.encodeWithSelector(
                GuardedState.PropertyViolated.selector,
                "SlotDomain",
                "diff writes a slot outside the target's declared domain"
            )
        );
        vault.settle(ids, bad, att);
    }

    function test_conservationAloneWouldMissThePhantom() public {
        _deploy(GuardedState.Mode.OnchainVerify);

        // Same diff, but with SlotDomain removed from the registry: now it sails through,
        // which is exactly why the domain property is not optional.
        registry.remove(registry.at(0)); // SlotDomain was added first

        bytes32[] memory ids = _request(alice, abi.encode("phantom", 1e18));
        SlotWrite[] memory bad = new SlotWrite[](1);
        bad[0] = SlotWrite(vault.sharesSlot(phantom), bytes32(uint256(1e18)));
        _settle(ids, bad);

        // The books "balance" while 1e18 shares exist off the register.
        (bool ok,,) = vault.checkNow();
        assertTrue(ok, "value properties are blind to unenumerated state");
        assertEq(vault.sharesOf(phantom), 1e18);
        assertEq(vault.sumOfParts(), 0);
    }

    // ------------------------------------------------------- honesty about trust

    /// @notice In the default mode the chain does not stop a violating diff — the operator does.
    /// @dev Worth an explicit test rather than a footnote. If a quorum signs a bad diff,
    ///      OffchainVeto applies it: the guarantee is an honest supermajority, not a proof.
    ///      `checkNow()` still reports the corruption, which is what a monitor watches.
    function test_offchainVetoAppliesWhatAQuorumSignsEvenIfWrong() public {
        _deploy(GuardedState.Mode.OffchainVeto);
        bytes32[] memory ids = _request(alice, abi.encode("mint out of thin air", 500));

        SlotWrite[] memory bad = new SlotWrite[](1);
        bad[0] = SlotWrite(vault.sharesSlot(alice), bytes32(uint256(500)));
        _settle(ids, bad); // no revert: nothing on-chain re-checks

        assertEq(vault.shares(alice), 500);
        (bool ok, string memory propertyName,) = vault.checkNow();
        assertFalse(ok);
        assertEq(propertyName, "Conservation");
    }
}
