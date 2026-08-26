// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {SlotWrite} from "../../src/interfaces/IProperty.sol";
import {IAccountHealth} from "../../src/properties/PostOperationSolvency.sol";
import {IConstantProductPool} from "../../src/properties/ConstantProduct.sol";
import {IParticipantRegistry} from "../../src/properties/ParticipantAllowlist.sol";
import {IPausable} from "../../src/properties/PanicState.sol";
import {IOracleMirror} from "../../src/properties/OracleLiveness.sol";
import {ITwapMirror} from "../../src/properties/OracleDeviation.sol";
import {IFeeAccruing} from "../../src/properties/FeeConsistency.sol";
import {IPreviewable} from "../../src/properties/SpecConformance.sol";

/// @notice A configurable stand-in adopter, so each property can be tested against the views it
///         needs without bending the example vault into every shape at once.
/// @dev Slots are arbitrary constants rather than real storage locations; these properties read
///      values through the diff and the view functions, never by `sload`ing the returned slot.
contract MockAdopter is
    IAccountHealth,
    IConstantProductPool,
    IParticipantRegistry,
    IPausable,
    IOracleMirror,
    ITwapMirror,
    IFeeAccruing,
    IPreviewable
{
    bytes32 public constant HEALTH_BASE = bytes32(uint256(0x100));
    bytes32 public constant RESERVE0 = bytes32(uint256(0x200));
    bytes32 public constant RESERVE1 = bytes32(uint256(0x201));
    bytes32 public constant PAUSED = bytes32(uint256(0x300));
    bytes32 public constant ORACLE_UPDATED_AT = bytes32(uint256(0x400));
    bytes32 public constant SPOT = bytes32(uint256(0x500));
    bytes32 public constant TWAP = bytes32(uint256(0x501));
    bytes32 public constant FEE_ACCRUED = bytes32(uint256(0x600));
    bytes32 public constant FEE_BASE = bytes32(uint256(0x601));

    address[] internal _touched;
    mapping(address => uint256) internal _health;
    uint256 internal _floor;

    uint256 internal _r0;
    uint256 internal _r1;

    address[] internal _participants;
    mapping(address => bool) internal _allowed;

    bool internal _paused;
    uint256 internal _oracleUpdatedAt;
    uint256 internal _spot;
    uint256 internal _twap;

    uint256 internal _feeAccrued;
    uint256 internal _feeBase;
    uint256 internal _feeRateBps;

    SlotWrite[] internal _preview;

    // ---------------------------------------------------------------- setters

    function setTouched(address[] memory a) external {
        _touched = a;
    }

    function setHealth(address a, uint256 h) external {
        _health[a] = h;
    }

    function setFloor(uint256 f) external {
        _floor = f;
    }

    function setReserves(uint256 r0, uint256 r1) external {
        _r0 = r0;
        _r1 = r1;
    }

    function setParticipants(address[] memory p) external {
        _participants = p;
    }

    function setAllowed(address a, bool v) external {
        _allowed[a] = v;
    }

    function setPaused(bool v) external {
        _paused = v;
    }

    function setOracleUpdatedAt(uint256 t) external {
        _oracleUpdatedAt = t;
    }

    function setPrices(uint256 spot_, uint256 twap_) external {
        _spot = spot_;
        _twap = twap_;
    }

    function setFees(uint256 accrued, uint256 base, uint256 rateBps) external {
        _feeAccrued = accrued;
        _feeBase = base;
        _feeRateBps = rateBps;
    }

    function setPreview(SlotWrite[] memory w) external {
        delete _preview;
        for (uint256 i; i < w.length; ++i) {
            _preview.push(w[i]);
        }
    }

    // ------------------------------------------------------------------ views

    function accountsTouchedBy(bytes32[] calldata) external view returns (address[] memory) {
        return _touched;
    }

    function accountHealthSlot(address account) external pure returns (bytes32) {
        return keccak256(abi.encode(account, HEALTH_BASE));
    }

    function accountHealth(address account) external view returns (uint256) {
        return _health[account];
    }

    function healthFloor() external view returns (uint256) {
        return _floor;
    }

    function reserve0Slot() external pure returns (bytes32) {
        return RESERVE0;
    }

    function reserve1Slot() external pure returns (bytes32) {
        return RESERVE1;
    }

    function reserve0() external view returns (uint256) {
        return _r0;
    }

    function reserve1() external view returns (uint256) {
        return _r1;
    }

    function participantsOf(bytes32[] calldata) external view returns (address[] memory) {
        return _participants;
    }

    function isAllowedParticipant(address account) external view returns (bool) {
        return _allowed[account];
    }

    function pausedSlot() external pure returns (bytes32) {
        return PAUSED;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function oracleUpdatedAtSlot() external pure returns (bytes32) {
        return ORACLE_UPDATED_AT;
    }

    function oracleUpdatedAt() external view returns (uint256) {
        return _oracleUpdatedAt;
    }

    function spotPriceSlot() external pure returns (bytes32) {
        return SPOT;
    }

    function twapPriceSlot() external pure returns (bytes32) {
        return TWAP;
    }

    function spotPrice() external view returns (uint256) {
        return _spot;
    }

    function twapPrice() external view returns (uint256) {
        return _twap;
    }

    function feeAccruedSlot() external pure returns (bytes32) {
        return FEE_ACCRUED;
    }

    function feeBaseSlot() external pure returns (bytes32) {
        return FEE_BASE;
    }

    function feeAccrued() external view returns (uint256) {
        return _feeAccrued;
    }

    function feeBase() external view returns (uint256) {
        return _feeBase;
    }

    function feeRateBps() external view returns (uint256) {
        return _feeRateBps;
    }

    function previewFor(bytes32[] calldata) external view returns (SlotWrite[] memory) {
        return _preview;
    }
}
