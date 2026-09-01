// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {SchnorrStakeRegistry} from "../src/schnorr/SchnorrStakeRegistry.sol";
import {SchnorrGasKillerSDK} from "../src/schnorr/SchnorrGasKillerSDK.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {Secp256k1} from "../src/schnorr/libraries/Secp256k1.sol";

/// @notice End-to-end gas for a **Schnorr** `verifyAndUpdate`, against the real registry and a
///         real aggregate signature — not a mock and not a fixture replay.
///
/// @dev Why this exists. Settlement cost has been quoted as a composition: a measured BLS receipt
///      (300,944, of which 224,827 is BLS verification) with its signature term swapped for a
///      measured Schnorr one. That composition carries the BLS transaction's *diff* with it, and
///      diff application scales with storage words written, so the borrowed remainder is only
///      right for a transition the same shape as the one it came from. This measures the whole
///      call directly instead, at a chosen word count.
///
///      Gas is deterministic for a given EVM version, so this is the same number a Sepolia
///      receipt would show for the same diff. Sepolia would validate the *pipeline* — router,
///      operators, aggregation — not the gas.
///
///      Signatures are generated here rather than fixtured, because `verifyAndUpdate` binds
///      `msgHash` to `sha256(transitionIndex, target, targetFunction, storageUpdates)`; a
///      pre-baked message cannot satisfy it. Convention must match the Rust signer exactly:
///
///        e = keccak256(Xx ‖ Xparity ‖ message ‖ Raddr) mod n
///        s = k − e·x (mod n)
contract SchnorrSettlementGasTest is Test {
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 constant GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 constant GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    uint96 constant WEIGHT = 100;
    /// keccak256("gasKiller.stateTracker") - 1
    bytes32 constant STATE_TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    /// Settlements this contract has already done, so the counter write is not an allocation.
    uint256 constant PRIOR_TRANSITIONS = 5;

    SchnorrStakeRegistry registry;
    Target target;

    uint256[] privKeys;

    function setUp() public {
        registry = new SchnorrStakeRegistry(2, 3, address(this), 0);
        target = new Target(registry);
    }

    // ------------------------------------------------------------------ crypto helpers

    /// @dev `k·G` by double-and-add over the SDK's own affine arithmetic. The installed forge
    ///      predates the `ecMulAffine` cheatcode, and upgrading the toolchain to get it could
    ///      reprice modexp (EIP-7883) and silently shift every number here — so this stays in
    ///      Solidity. Only ever runs in setup, never inside a measured region.
    function _mul(uint256 k) internal view returns (uint256 x, uint256 y) {
        uint256 bx = GX;
        uint256 by = GY;
        while (k != 0) {
            if (k & 1 == 1) (x, y) = Secp256k1.add(x, y, bx, by);
            (bx, by) = Secp256k1.add(bx, by, bx, by);
            k >>= 1;
        }
    }

    function _add(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256, uint256) {
        return Secp256k1.add(x1, y1, x2, y2);
    }

    function _addr(uint256 x, uint256 y) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    function _challenge(uint256 Xx, uint8 parity, bytes32 message, address Raddr)
        internal
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(Xx, parity, message, Raddr))) % N;
    }

    /// @dev Single-signer Schnorr, used for each operator's proof of possession.
    function _signSingle(uint256 priv, bytes32 message, uint256 nonce)
        internal
        view
        returns (uint256 s, address Raddr)
    {
        (uint256 Xx, uint256 Xy) = _mul(priv);
        (uint256 Rx, uint256 Ry) = _mul(nonce);
        Raddr = _addr(Rx, Ry);
        uint256 e = _challenge(Xx, uint8(Xy & 1), message, Raddr);
        s = addmod(nonce, N - mulmod(e, priv, N), N);
    }

    /// @dev Aggregate Schnorr over `signers`. Returns `(s, Raddr)` verifying against
    ///      `X = Σ X_i` for the signer subset.
    function _signAggregate(uint256[] memory signers, bytes32 message, uint256 nonceSeed)
        internal
        view
        returns (uint256 s, address Raddr)
    {
        uint256 Xx;
        uint256 Xy;
        uint256 Rx;
        uint256 Ry;
        uint256[] memory ks = new uint256[](signers.length);

        for (uint256 i; i < signers.length; ++i) {
            (uint256 px, uint256 py) = _mul(signers[i]);
            (Xx, Xy) = _add(Xx, Xy, px, py);

            ks[i] = uint256(keccak256(abi.encodePacked(nonceSeed, i))) % N;
            (uint256 rx, uint256 ry) = _mul(ks[i]);
            (Rx, Ry) = _add(Rx, Ry, rx, ry);
        }

        Raddr = _addr(Rx, Ry);
        uint256 e = _challenge(Xx, uint8(Xy & 1), message, Raddr);

        for (uint256 i; i < signers.length; ++i) {
            s = addmod(s, addmod(ks[i], N - mulmod(e, signers[i], N), N), N);
        }
    }

    function _register(uint256 count) internal {
        for (uint256 i; i < count; ++i) {
            uint256 priv = uint256(keccak256(abi.encodePacked("op", i))) % N;
            privKeys.push(priv);
            (uint256 x, uint256 y) = _mul(priv);
            address id = _addr(x, y);
            (uint256 s, address R) = _signSingle(priv, registry.popMessage(id), priv / 3 + 7);
            registry.registerOperator(x, y, WEIGHT, s, R);
        }
    }

    // ------------------------------------------------------------------ the measurement

    /// @dev `words` distinct STOREs, each non-zero → non-zero, matching a steady-state protocol
    ///      write rather than a first-touch 20k allocation.
    function _updates(uint256 words) internal returns (StateUpdateType[] memory types, bytes[] memory args) {
        types = new StateUpdateType[](words);
        args = new bytes[](words);
        for (uint256 i; i < words; ++i) {
            types[i] = StateUpdateType.STORE;
            args[i] = abi.encode(bytes32(uint256(100 + i)), bytes32(uint256(999 + i)));
            // seed the slot so the measured write is a rewrite, not an allocation
            vm.store(address(target), bytes32(uint256(100 + i)), bytes32(uint256(1)));
        }
    }

    function _settle(uint256 operators, uint256 nonSignerCount, uint256 words)
        internal
        returns (uint256 gasUsed)
    {
        _register(operators);

        (StateUpdateType[] memory types, bytes[] memory args) = _updates(words);
        bytes memory payload = abi.encode(types, args);

        // `_verifyAndUpdateOne` is `trackState`, so the counter is bumped before the index
        // check: transitionIndex must equal the count read *before* the call. Seed it non-zero
        // so the counter write is a steady-state rewrite (2,900) rather than a first-touch
        // allocation (20,000) — a contract that has settled before is the realistic case.
        vm.store(address(target), STATE_TRACKER_SLOT, bytes32(PRIOR_TRANSITIONS));
        uint256 ti = PRIOR_TRANSITIONS;
        bytes4 fn = bytes4(keccak256("doWork()"));
        bytes32 msgHash = sha256(abi.encode(ti, address(target), fn, payload));

        // Signers are operators[nonSignerCount..]; the first `nonSignerCount` abstain.
        uint256 signerCount = operators - nonSignerCount;
        uint256[] memory signers = new uint256[](signerCount);
        for (uint256 i; i < signerCount; ++i) signers[i] = privKeys[nonSignerCount + i];

        address[] memory nonSigners = new address[](nonSignerCount);
        for (uint256 i; i < nonSignerCount; ++i) {
            (uint256 x, uint256 y) = _mul(privKeys[i]);
            nonSigners[i] = _addr(x, y);
        }
        _sort(nonSigners);

        (uint256 s, address Raddr) = _signAggregate(signers, msgHash, 42);

        vm.roll(block.number + 1);
        uint32 refBlock = uint32(block.number - 1);

        // Cold: nothing in this transaction has touched the registry or the target yet.
        vm.cool(address(registry));
        vm.cool(address(target));

        uint256 intrinsic = _intrinsic(
            abi.encodeCall(
                target.verifyAndUpdate, (msgHash, refBlock, payload, ti, fn, s, Raddr, nonSigners)
            )
        );

        uint256 before = gasleft();
        target.verifyAndUpdate(msgHash, refBlock, payload, ti, fn, s, Raddr, nonSigners);
        uint256 execGas = before - gasleft();
        console2.log("    exec", execGas, "+ intrinsic", intrinsic);
        gasUsed = execGas + intrinsic;
    }

    /// @dev 21,000 base plus EIP-2028 calldata: 16 gas per non-zero byte, 4 per zero byte.
    ///      The execution measurement cannot see this, but a receipt does.
    function _intrinsic(bytes memory cd) internal view returns (uint256 g) {
        g = 21000;
        for (uint256 i; i < cd.length; ++i) g += cd[i] == 0 ? 4 : 16;
        console2.log("    calldata bytes", cd.length);
    }

    function _sort(address[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; ++i) {
            address k = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > k) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = k;
        }
    }

    /// @notice Two storage words — the diff a guarded `borrow()` on the lending example produces.
    function test_gas_settle_3ops_fullParticipation_2words() public {
        uint256 g = _settle(3, 0, 2);
        console2.log("settle 3ops k=0 words=2:", g);
    }

    function test_gas_settle_3ops_oneNonSigner_2words() public {
        uint256 g = _settle(3, 1, 2);
        console2.log("settle 3ops k=1 words=2:", g);
    }

    function test_gas_settle_10ops_threeNonSigners_2words() public {
        uint256 g = _settle(10, 3, 2);
        console2.log("settle 10ops k=3 words=2:", g);
    }

    /// @notice How settlement scales with diff size, which is what the borrowed BLS remainder
    ///         silently fixed at whatever Gas Killer's own transition wrote.
    function test_gas_settle_byWordCount() public {
        uint256 g1 = _settle(3, 0, 1);
        console2.log("settle 3ops k=0 words=1:", g1);
    }

    function test_gas_settle_8words() public {
        uint256 g = _settle(3, 0, 8);
        console2.log("settle 3ops k=0 words=8:", g);
    }
}

/// @dev Minimal SDK consumer. The router calls `verifyAndUpdate` on it directly, which is
///      what a settlement receipt reflects — so there is no wrapper to inflate the measurement.
contract Target is SchnorrGasKillerSDK {
    constructor(SchnorrStakeRegistry r) {
        _setAvsAddress(address(0xA5));
        _setSchnorrRegistry(address(r));
    }
}
