// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProperty, TransitionContext} from "../../interfaces/IProperty.sol";

/// @notice The views a multi-market protocol exposes so a risk policy can sweep it.
interface IMarkets {
    function marketCount() external view returns (uint256);
    function marketTotals(uint256 id) external view returns (uint256 supplied, uint256 borrowed);
    function marketCaps(uint256 id) external view returns (uint256 supplyCap, uint256 borrowCap);
    function marketRiskParams(uint256 id) external view returns (uint256 ltvBps, uint256 liqThresholdBps);
    function marketIndices(uint256 id) external view returns (uint256 liquidityIndex, uint256 borrowIndex);
    function marketOracle(uint256 id) external view returns (uint256 price, uint256 updatedAt);
    function protocolTotalBorrowed() external view returns (uint256);
    function protocolTotalSupplied() external view returns (uint256);
}

/// @notice Every market must have more supplied than borrowed.
/// @dev The check a lending protocol most wants and least can afford, because it is per-asset and
///      there is no single number that captures it.
contract MarketSolvency is IProperty {
    function name() external pure returns (string memory) {
        return "MarketSolvency";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IMarkets p = IMarkets(ctx.target);
        uint256 n = p.marketCount();
        for (uint256 i; i < n; ++i) {
            (uint256 supplied, uint256 borrowed) = p.marketTotals(i);
            if (borrowed > supplied) return (false, "a market is borrowed beyond what is supplied");
        }
        return (true, "");
    }
}

/// @notice Supply and borrow caps hold on every market.
/// @dev Caps exist to bound exposure to one asset. They are enforced on the paths someone remembered
///      to annotate, which is exactly the sort of thing that gets missed on a new path.
contract MarketCapsRule is IProperty {
    function name() external pure returns (string memory) {
        return "MarketCaps";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IMarkets p = IMarkets(ctx.target);
        uint256 n = p.marketCount();
        for (uint256 i; i < n; ++i) {
            (uint256 supplied, uint256 borrowed) = p.marketTotals(i);
            (uint256 supplyCap, uint256 borrowCap) = p.marketCaps(i);
            if (supplyCap != 0 && supplied > supplyCap) return (false, "a market exceeded its supply cap");
            if (borrowCap != 0 && borrowed > borrowCap) return (false, "a market exceeded its borrow cap");
        }
        return (true, "");
    }
}

/// @notice No market is priced by a stale oracle.
/// @dev Stale-price exploitation does not need the feed to be wrong, only old. Checking one feed is
///      cheap; checking all of them on every interaction is what nobody does.
contract MarketOracleFreshness is IProperty {
    uint256 public immutable maxStaleness;

    constructor(uint256 _maxStaleness) {
        maxStaleness = _maxStaleness;
    }

    function name() external pure returns (string memory) {
        return "MarketOracleFreshness";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IMarkets p = IMarkets(ctx.target);
        uint256 n = p.marketCount();
        for (uint256 i; i < n; ++i) {
            (, uint256 updatedAt) = p.marketOracle(i);
            if (updatedAt == 0) return (false, "a market has never been priced");
            if (block.timestamp > updatedAt && block.timestamp - updatedAt > maxStaleness) {
                return (false, "a market's oracle is stale");
            }
        }
        return (true, "");
    }
}

/// @notice Interest indices never fall below their starting value.
/// @dev Rewinding an accumulator is a favourite exploit primitive precisely because the increment
///      path is audited and the value itself never is.
contract MarketIndexFloor is IProperty {
    uint256 public immutable floor;

    constructor(uint256 _floor) {
        floor = _floor;
    }

    function name() external pure returns (string memory) {
        return "MarketIndexFloor";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IMarkets p = IMarkets(ctx.target);
        uint256 n = p.marketCount();
        for (uint256 i; i < n; ++i) {
            (uint256 liq, uint256 borrow) = p.marketIndices(i);
            if (liq < floor || borrow < floor) return (false, "a market index fell below its floor");
        }
        return (true, "");
    }
}

/// @notice Risk parameters stay internally consistent on every market.
/// @dev LTV above the liquidation threshold means a position is born liquidatable. The shape a
///      fat-fingered or compromised parameter update takes.
contract MarketRiskParams is IProperty {
    function name() external pure returns (string memory) {
        return "MarketRiskParams";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IMarkets p = IMarkets(ctx.target);
        uint256 n = p.marketCount();
        for (uint256 i; i < n; ++i) {
            (uint256 ltv, uint256 liq) = p.marketRiskParams(i);
            if (ltv > liq) return (false, "a market's LTV exceeds its liquidation threshold");
            if (liq > 10_000) return (false, "a market's liquidation threshold exceeds 100%");
        }
        return (true, "");
    }
}

/// @notice Per-market totals add up to the protocol's own totals.
/// @dev The cross-check that catches accounting drift. A protocol keeps running totals because
///      recomputing them is expensive; this is the recomputation it cannot normally afford.
contract GlobalAccounting is IProperty {
    function name() external pure returns (string memory) {
        return "GlobalAccounting";
    }

    function check(TransitionContext calldata ctx) external view returns (bool, string memory) {
        IMarkets p = IMarkets(ctx.target);
        uint256 n = p.marketCount();
        uint256 supplied;
        uint256 borrowed;
        for (uint256 i; i < n; ++i) {
            (uint256 s, uint256 b) = p.marketTotals(i);
            supplied += s;
            borrowed += b;
        }
        if (supplied != p.protocolTotalSupplied()) return (false, "market supplies do not sum to the protocol total");
        if (borrowed != p.protocolTotalBorrowed()) return (false, "market borrows do not sum to the protocol total");
        return (true, "");
    }
}
