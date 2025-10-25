// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IClearingHouse Interface
/// @notice Margin, PnL, funding, fee routing, and liquidation orchestration for perpetual vAMM markets only.
interface IClearingHouse {
    // ========= User Actions =========

    function deposit(address token, uint256 amount) external;

    function withdraw(address token, uint256 amount) external;

    /// @notice Open or increase a position.
    /// @param marketId Bytes32 key (e.g., keccak256("H100-PERP"))
    /// @param isLong True for long (buy base), false for short (sell base)
    /// @param size Base units (1e18) to add in absolute value
    /// @param priceLimitX18 Slippage guard on execution (1e18)
    function openPosition(bytes32 marketId, bool isLong, uint128 size, uint256 priceLimitX18) external;

    /// @notice Close or reduce a position size in base units.
    function closePosition(bytes32 marketId, uint128 size, uint256 priceLimitX18) external;

    function addMargin(bytes32 marketId, uint256 amount) external;

    function removeMargin(bytes32 marketId, uint256 amount) external;

    /// @notice Liquidate a portion or full position if below maintenance margin.
    function liquidate(address account, bytes32 marketId, uint128 size) external;

    /// @notice Settle funding up to latest index for a given account on a market.
    function settleFunding(bytes32 marketId, address account) external;

    // ========= Views =========
    struct PositionView {
        int256 size;                // signed base (1e18)
        uint256 margin;             // quote collateral (1e18)
        uint256 entryPriceX18;      // avg entry (1e18)
        int256 lastFundingIndex;    // funding checkpoint (signed)
        int256 realizedPnL;         // accumulated PnL
    }

    function getPosition(address account, bytes32 marketId) external view returns (PositionView memory);
    function getNotional(address account, bytes32 marketId) external view returns (uint256);
    function getMarginRatio(address account, bytes32 marketId) external view returns (uint256);
    function getAccountValue(address account) external view returns (int256);
    function isLiquidatable(address account, bytes32 marketId) external view returns (bool);

    // ========= Admin =========
    function setRiskParams(
        bytes32 marketId,
        uint256 imrBps,
        uint256 mmrBps,
        uint256 liquidationPenaltyBps,
        uint256 penaltyCap
    ) external;

    function pauseMarket(bytes32 marketId, bool paused) external;
}
