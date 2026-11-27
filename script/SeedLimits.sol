// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVAMM} from "../src/Interfaces/IVAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {Calculations} from "../src/Libraries/Calculations.sol";

/// @title SeedLimits
/// @notice Slippage limits for a market's seed trades, a few bps from the fill expected at the vAMM's
///         reserves when the script runs.
/// @dev A new market is open to everyone as soon as its index price is revealed, and the seed wallets
///      trade in separate transactions after it. A limit far from the expected fill lets anyone who
///      trades ahead of a seed trade make it fill at that limit and take the difference. With these
///      limits a trade ahead of the seed moves the fill past the limit and the seed trade reverts
///      instead. Read the limit right before each seed trade (after the previous one), since every
///      trade moves the reserves.
library SeedLimits {
    /// @notice Room left between the expected fill and the limit (0.1%).
    uint256 internal constant SEED_SLIPPAGE_BPS = 10;
    uint256 internal constant BPS = 10_000;

    /// @notice The vAMM of a registered market.
    function vammOf(address registry, bytes32 marketId) internal view returns (address vamm) {
        vamm = IMarketRegistry(registry).getMarket(marketId).vamm;
        require(vamm != address(0), "SeedLimits: market not found");
    }

    /// @notice Quote a long of `size` base pays at the vAMM's current reserves (vAMM fee is 0).
    function expectedLongQuoteIn(address vamm, uint128 size) internal view returns (uint256) {
        (uint256 x, uint256 y) = IVAMM(vamm).getReserves();
        require(size < x, "SeedLimits: size >= base reserve");
        return Calculations.mulDivRoundingUp(size, y, x - size);
    }

    /// @notice Quote a short of `size` base receives at the vAMM's current reserves (vAMM fee is 0).
    function expectedShortQuoteOut(address vamm, uint128 size) internal view returns (uint256) {
        (uint256 x, uint256 y) = IVAMM(vamm).getReserves();
        return Calculations.mulDiv(y, size, x + size);
    }

    /// @notice maxQuoteIn for a seed long: the expected fill plus SEED_SLIPPAGE_BPS.
    function longMaxQuoteIn(address vamm, uint128 size) internal view returns (uint256) {
        return Calculations.mulDiv(expectedLongQuoteIn(vamm, size), BPS + SEED_SLIPPAGE_BPS, BPS);
    }

    /// @notice minQuoteOut for a seed short: the expected fill minus SEED_SLIPPAGE_BPS.
    function shortMinQuoteOut(address vamm, uint128 size) internal view returns (uint256) {
        return Calculations.mulDivRoundingUp(expectedShortQuoteOut(vamm, size), BPS - SEED_SLIPPAGE_BPS, BPS);
    }
}
