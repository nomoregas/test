// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Guarded} from "../Guarded.sol";
import {SubscriptionRegistry} from "../catalogue/SubscriptionRegistry.sol";

/// @notice One listed asset, shaped like a real lending market's reserve data.
/// @dev Config bits are packed into a single word, the way Aave packs its reserve configuration
///      bitmap, because not doing so would inflate the benchmark. Totals, indices and the oracle
///      timestamp stay in their own slots, as they do in practice — they change at different times.
struct Market {
    uint256 totalSupplied;
    uint256 totalBorrowed;
    uint256 liquidityIndex;
    uint256 borrowIndex;
    uint256 oraclePrice;
    uint256 oracleUpdatedAt;
    /// @dev ltvBps | liquidationThresholdBps << 16 | supplyCap << 32 | borrowCap << 160
    uint256 packedConfig;
}

/// @title LendingProtocol
/// @notice A multi-asset lending protocol, guarded by a whole risk policy rather than one rule.
///
/// @dev The point of this example is the shape, not the lending maths. A real protocol of this kind
///      lists dozens of assets — Aave carries around thirty — and a genuine "is this protocol still
///      healthy" pass has to visit every one of them: is each market solvent, under its caps, priced
///      by a fresh oracle, with sane risk parameters and indices that have not gone backwards, and do
///      the per-market totals still add up to the protocol's own totals?
///
///      No protocol runs that per transaction. Each individual check is cheap; the *policy* is not,
///      because it is a dozen checks across every listed asset. That is the cost this measures.
contract LendingProtocol is Guarded {
    uint256 public constant RAY = 1e27;

    mapping(uint256 => Market) internal _markets;
    uint256 public marketCount;

    uint256 public protocolTotalSupplied;
    uint256 public protocolTotalBorrowed;

    address public admin;
    uint256 public reserveFactorBps;
    bool public paused;

    constructor(SubscriptionRegistry registry_, GuardMode mode_) Guarded(registry_, mode_) {
        admin = msg.sender;
    }

    // ------------------------------------------------------------ listing

    function listMarket(uint256 supplyCap, uint256 borrowCap, uint256 ltvBps, uint256 liqThresholdBps)
        external
        returns (uint256 id)
    {
        id = marketCount++;
        _markets[id] = Market({
            totalSupplied: 0,
            totalBorrowed: 0,
            liquidityIndex: RAY,
            borrowIndex: RAY,
            oraclePrice: 1e18,
            oracleUpdatedAt: block.timestamp,
            packedConfig: _pack(ltvBps, liqThresholdBps, supplyCap, borrowCap)
        });
    }

    // -------------------------------------------------------- user actions

    function supply(uint256 id, uint256 amount) external guarded {
        Market storage m = _markets[id];
        m.totalSupplied += amount;
        protocolTotalSupplied += amount;
    }

    function borrow(uint256 id, uint256 amount) external guarded {
        Market storage m = _markets[id];
        m.totalBorrowed += amount;
        protocolTotalBorrowed += amount;
    }

    function accrue(uint256 id, uint256 liquidityDelta, uint256 borrowDelta) external guarded {
        Market storage m = _markets[id];
        m.liquidityIndex += liquidityDelta;
        m.borrowIndex += borrowDelta;
    }

    /// @notice Same as `borrow` with no guard, for the benchmark's baseline.
    function unguardedBorrow(uint256 id, uint256 amount) external {
        Market storage m = _markets[id];
        m.totalBorrowed += amount;
        protocolTotalBorrowed += amount;
    }

    // ------------------------------------------------ deliberate bad paths

    /// @notice Pushes a market past its borrow cap. The caps rule must revert it.
    function overBorrow(uint256 id, uint256 amount) external guarded {
        _markets[id].totalBorrowed += amount;
        protocolTotalBorrowed += amount;
    }

    /// @notice Rewinds an index. The index rule must revert it.
    function rewindIndex(uint256 id, uint256 to) external guarded {
        _markets[id].liquidityIndex = to;
    }

    // ---------------------------------------------------- what rules read

    function market(uint256 id) external view returns (Market memory) {
        return _markets[id];
    }

    function marketTotals(uint256 id) external view returns (uint256 supplied, uint256 borrowed) {
        Market storage m = _markets[id];
        return (m.totalSupplied, m.totalBorrowed);
    }

    function marketCaps(uint256 id) external view returns (uint256 supplyCap, uint256 borrowCap) {
        uint256 p = _markets[id].packedConfig;
        return (uint128(p >> 32), uint96(p >> 160));
    }

    function marketRiskParams(uint256 id) external view returns (uint256 ltvBps, uint256 liqThresholdBps) {
        uint256 p = _markets[id].packedConfig;
        return (uint16(p), uint16(p >> 16));
    }

    function marketIndices(uint256 id) external view returns (uint256 liquidityIndex, uint256 borrowIndex) {
        Market storage m = _markets[id];
        return (m.liquidityIndex, m.borrowIndex);
    }

    function marketOracle(uint256 id) external view returns (uint256 price, uint256 updatedAt) {
        Market storage m = _markets[id];
        return (m.oraclePrice, m.oracleUpdatedAt);
    }

    function _pack(uint256 ltv, uint256 liq, uint256 supplyCap, uint256 borrowCap) private pure returns (uint256) {
        return ltv | (liq << 16) | (supplyCap << 32) | (borrowCap << 160);
    }
}
