// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVAMM (Virtual AMM) Interface — Option A: single global liquidity
/// @notice Exposes swap, pricing, funding, and admin hooks for the Clearinghouse and governance.
interface IVAMM {
    // ========= Swaps (Clearinghouse-only) =========
    /// @notice Buy base asset by specifying the amount of base to receive.
    /// @param baseAmount Target base quantity to acquire (1e18-scaled base units).
    /// @param priceLimitX18 Slippage protection: max acceptable price (1e18).
    /// @return baseDelta Signed base change for the trader (positive when receiving base).
    /// @return quoteDelta Signed quote change for the trader (negative when paying quote).
    /// @return avgPriceX18 Volume-weighted execution price (1e18).
    function buyBase(
        uint128 baseAmount,
        uint256 priceLimitX18
    ) external returns (int256 baseDelta, int256 quoteDelta, uint256 avgPriceX18);

    /// @notice Buy base asset by specifying the amount of quote to pay.
    /// @param quoteAmount Quote notional spent (1e18-scaled quote units).
    /// @param priceLimitX18 Slippage protection: max acceptable price (1e18).
    /// @return baseDelta Signed base change (positive when receiving base).
    /// @return quoteDelta Signed quote change (negative when paying quote).
    /// @return avgPriceX18 Volume-weighted execution price (1e18).
    function buyBaseWithQuote(
        uint128 quoteAmount,
        uint256 priceLimitX18
    ) external returns (int256 baseDelta, int256 quoteDelta, uint256 avgPriceX18);

    /// @notice Sell base asset to receive quote. Used for shorting or closing longs.
    /// @param baseAmount Target base quantity to sell (1e18-scaled base units).
    /// @param priceLimitX18 Slippage protection: min acceptable price (1e18).
    /// @return baseDelta Signed base change for the trader (negative when providing base).
    /// @return quoteDelta Signed quote change for the trader (positive when receiving quote).
    /// @return avgPriceX18 Volume-weighted execution price (1e18).
    function sellBase(
        uint128 baseAmount,
        uint256 priceLimitX18
    ) external returns (int256 baseDelta, int256 quoteDelta, uint256 avgPriceX18);

    // ========= Views =========
    /// @notice Current mark price derived from sqrtPrice (1e18-scaled quote per base).
    function getMarkPrice() external view returns (uint256);

    /// @notice Current sqrt price (Q96) and tick for diagnostics.
    function getSqrtPriceX96() external view returns (uint160);
    function getTick() external view returns (int24);

    /// @notice Active virtual liquidity used for price impact and slippage.
    function getLiquidity() external view returns (uint128);

    /// @notice Time-weighted average mark price over a lookback window (seconds).
    function getTwap(uint32 window) external view returns (uint256);

    /// @notice Global fee growth index per unit liquidity in Q128 (for LP accounting).
    function feeGrowthGlobalX128() external view returns (uint256);

    /// @notice Cumulative funding per unit (1e18) since inception (signed).
    function cumulativeFundingPerUnitX18() external view returns (int256);

    /// @notice Get current virtual reserves
    function getReserves() external view returns (uint256 base, uint256 quote);

    // ========= Admin / Keepers =========
    /// @notice Set total virtual liquidity (used if LP shares are handled externally via cuERC20).
    function setLiquidity(uint128 newLiquidity) external;

    /// @notice Update protocol parameters for fees and funding.
    /// @param feeBps Trade fee in basis points.
    /// @param frMaxBpsPerHour Funding clamp per hour in bps.
    /// @param kFundingX18 Funding scaling factor (1e18 = 1.0).
    /// @param observationWindow TWAP window in seconds.
    function setParams(
        uint16 feeBps,
        uint256 frMaxBpsPerHour,
        uint256 kFundingX18,
        uint32 observationWindow
    ) external;

    /// @notice Keeper/CH trigger to advance funding indices based on mark vs index.
    function pokeFunding() external;

    /// @notice Optional trading pause (e.g., after lastTradeTimestamp for dated futures). Closing-only is enforced by CH.
    function pauseSwaps(bool paused) external;
}
