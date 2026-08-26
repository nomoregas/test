// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, IAttestor, SlotWrite, TransitionContext} from "./interfaces/IProperty.sol";
import {PropertyRegistry} from "./PropertyRegistry.sol";

/// @title GuardedState
/// @notice Base for a contract whose entire guarded state can only change through a
///         transition that an operator quorum has attested preserves every registered property.
///
/// @dev **Why writes are asynchronous.** An off-chain veto can only block a transition that
///      waits for a quorum. A function that mutates state the moment it is mined gives
///      operators nothing to veto — by the time they see it, the bad state has landed. So a
///      guarded contract has no direct writers: callers `request()` an intent, operators
///      simulate applying the pending intents, evaluate every property on the resulting
///      post-state, and only then sign. `settle()` applies a diff that has been attested.
///      Nothing reaches guarded storage unattested, which is what makes "block the violation"
///      true for *all* state changes rather than only for the expensive ones.
///
///      **What the guarantee rests on.** There is no on-chain re-execution in the default
///      mode. If a quorum signs a property-violating diff, this contract applies it. The
///      guarantee is crypto-economic — an honest supermajority — not a proof. `Mode.OnchainVerify`
///      exists for contracts that can afford real teeth, and for tests to prove the guard is
///      load-bearing rather than decorative.
abstract contract GuardedState {
    /// @notice How a violation is prevented.
    /// @dev OffchainVeto  — operators refuse to sign; costs the chain nothing; trusts the quorum.
    ///      OnchainVerify — `settle` re-runs every property after applying and reverts on
    ///                      violation. Objective, but you pay for the check you were avoiding.
    ///                      Sane for cheap property sets, or as a belt-and-braces rollout mode.
    enum Mode {
        OffchainVeto,
        OnchainVerify
    }

    struct Intent {
        address requester;
        bytes action;
        uint64 requestedAt;
        bool settled;
    }

    PropertyRegistry public immutable registry;
    IAttestor public attestor;
    Mode public mode;

    mapping(bytes32 => Intent) internal _intents;
    bytes32[] internal _pending;
    mapping(bytes32 => uint256) private _pendingIndex;
    uint256 private _transitionIndex;
    uint256 private _nonce;

    error NotAttested();
    error PropertyViolated(string propertyName, string reason);
    error UnknownIntent(bytes32 id);
    error AlreadySettled(bytes32 id);
    error NothingToSettle();
    error StaleWrite(bytes32 slot, bytes32 expected, bytes32 actual);

    event IntentRequested(bytes32 indexed id, address indexed requester, bytes action);
    event TransitionSettled(uint256 indexed transitionIndex, bytes32[] intentIds, uint256 writeCount);

    constructor(PropertyRegistry _registry, IAttestor _attestor, Mode _mode) {
        registry = _registry;
        attestor = _attestor;
        mode = _mode;
    }

    // ---------------------------------------------------------------- intents

    /// @notice Ask for a state change. Nothing is applied here.
    /// @dev Deliberately cheap and unconditional: an intent is a request, not a right. It
    ///      carries no authority, so accepting one costs the contract nothing to be wrong about.
    function request(bytes calldata action) external returns (bytes32 id) {
        id = keccak256(abi.encode(address(this), msg.sender, action, _nonce++));
        _intents[id] =
            Intent({requester: msg.sender, action: action, requestedAt: uint64(block.timestamp), settled: false});
        _pendingIndex[id] = _pending.length;
        _pending.push(id);
        emit IntentRequested(id, msg.sender, action);
    }

    function intent(bytes32 id) external view returns (Intent memory) {
        return _intents[id];
    }

    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    function pendingAt(uint256 i) external view returns (bytes32) {
        return _pending[i];
    }

    function transitionIndex() external view returns (uint256) {
        return _transitionIndex;
    }

    // ------------------------------------------------------------ settlement

    /// @notice The digest an operator quorum signs.
    /// @dev Binds the diff to this contract and to a specific transition index, so an attested
    ///      transition cannot be replayed, reordered, or retargeted at a sibling deployment.
    ///      Shape follows GasKillerSDK's own message hash.
    function transitionDigest(bytes32[] calldata ids, SlotWrite[] calldata writes) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), _transitionIndex, ids, writes));
    }

    /// @notice Apply an attested, property-preserving diff.
    function settle(bytes32[] calldata ids, SlotWrite[] calldata writes, bytes calldata attestation) external {
        if (ids.length == 0) revert NothingToSettle();
        if (!attestor.verify(transitionDigest(ids, writes), attestation)) revert NotAttested();

        for (uint256 i; i < ids.length; ++i) {
            Intent storage it = _intents[ids[i]];
            if (it.requester == address(0)) revert UnknownIntent(ids[i]);
            if (it.settled) revert AlreadySettled(ids[i]);
        }

        _applyWrites(writes);

        for (uint256 i; i < ids.length; ++i) {
            _intents[ids[i]].settled = true;
            _dropPending(ids[i]);
        }

        uint256 idx = _transitionIndex;
        _transitionIndex = idx + 1;

        if (mode == Mode.OnchainVerify) {
            (bool ok, string memory propertyName, string memory reason) = checkAll(ids, writes, idx);
            if (!ok) revert PropertyViolated(propertyName, reason);
        }

        emit TransitionSettled(idx, ids, writes.length);
    }

    /// @notice Evaluate every registered property against the current state and a given diff.
    /// @dev Public so operators, monitors, and tests all judge a transition by exactly the same
    ///      code path the contract would. A property set that only the operator can evaluate is
    ///      a property set nobody can audit.
    function checkAll(bytes32[] memory ids, SlotWrite[] memory writes, uint256 idx)
        public
        view
        returns (bool ok, string memory propertyName, string memory reason)
    {
        TransitionContext memory ctx =
            TransitionContext({target: address(this), transitionIndex: idx, intentIds: ids, writes: writes});
        return registry.checkAll(ctx);
    }

    /// @notice Evaluate properties against the state as it stands right now, with no diff.
    ///
    /// @dev The health check a monitor calls when no transition is in flight — "is this contract
    ///      currently sound?".
    ///
    ///      **Not an operator oracle.** It passes an empty diff, so any property that judges the
    ///      *writes* rather than the resulting state — SlotDomain above all — has nothing to
    ///      object to and returns true. An operator deciding whether to sign must call
    ///      `checkAll(ids, writes, idx)` with the real diff. Using this instead silently disables
    ///      the domain check, which is how a phantom-holder credit gets attested by an operator
    ///      that believed it was verifying.
    function checkNow() external view returns (bool ok, string memory propertyName, string memory reason) {
        return checkAll(new bytes32[](0), new SlotWrite[](0), _transitionIndex);
    }

    // ------------------------------------------------------------- internals

    /// @dev Raw `sstore`, exactly as Gas Killer settlement applies a diff — but gated on the
    ///      before-image matching live storage, making each write a compare-and-swap.
    ///
    ///      Two things depend on this. Every pre/post property reads `oldValue` as the truth about
    ///      what the state used to be, so an unverified before-image would let an operator fabricate
    ///      the history a property is judged against — monotonicity, delta caps and share-price
    ///      floors would all be trivially satisfiable. And a diff assembled against an older state
    ///      would otherwise apply silently on top of an unrelated one, which is the same staleness
    ///      hazard `blockStaleMeasure` bounds on the quorum side.
    ///
    ///      This is also why SlotDomain is not optional: the applier has no opinion about *which*
    ///      slots are legitimate, only that it was told the right prior contents.
    function _applyWrites(SlotWrite[] calldata writes) private {
        for (uint256 i; i < writes.length; ++i) {
            bytes32 slot = writes[i].slot;
            bytes32 expected = writes[i].oldValue;
            bytes32 value = writes[i].newValue;
            bytes32 actual;
            assembly {
                actual := sload(slot)
            }
            if (actual != expected) revert StaleWrite(slot, expected, actual);
            assembly {
                sstore(slot, value)
            }
        }
    }

    function _dropPending(bytes32 id) private {
        uint256 i = _pendingIndex[id];
        uint256 last = _pending.length - 1;
        if (i != last) {
            bytes32 moved = _pending[last];
            _pending[i] = moved;
            _pendingIndex[moved] = i;
        }
        _pending.pop();
        delete _pendingIndex[id];
    }
}
