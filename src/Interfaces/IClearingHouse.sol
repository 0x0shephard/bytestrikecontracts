// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IClearingHouse Interface
/// @notice Margin, PnL, funding, fee routing, and liquidation orchestration for perpetual vAMM markets only.
interface IClearingHouse {
    struct PositionView {
        int256 size;
        uint256 margin;
        uint256 entryPriceX18;
        int256 lastFundingIndex;
        int256 realizedPnL;
    }

    /// @notice Deposit collateral into the vault.
    function deposit(address token, uint256 amount) external;

    /// @notice Withdraw collateral from the vault.
    function withdraw(address token, uint256 amount) external;

    /// @notice Add margin to a specific position.
    function addMargin(bytes32 marketId, uint256 amount) external;

    /// @notice Remove margin from a specific position.
    function removeMargin(bytes32 marketId, uint256 amount) external;

    /// @notice Open or increase a position.
    /// @param marketId Bytes32 key (e.g., keccak256("H100-PERP"))
    /// @param isLong True for long (buy base), false for short (sell base)
    /// @param size Base units (1e18) to add in absolute value
    /// @param priceLimitX18 Slippage guard on execution (1e18)
    function openPosition(bytes32 marketId, bool isLong, uint128 size, uint256 priceLimitX18) external;

    /// @notice Close or reduce a position size in base units.
    function closePosition(bytes32 marketId, uint128 size, uint256 priceLimitX18) external;

    /// @notice Liquidate a portion or full position if below maintenance margin.
    function liquidate(address account, bytes32 marketId, uint128 size, uint256 priceLimitX18) external;

    /// @notice Settle funding up to latest index for a given account on a market.
    function settleFunding(bytes32 marketId, address account) external;

    /// @notice Set risk parameters for a market.
    function setRiskParams(
        bytes32 marketId,
        uint256 imrBps,
        uint256 mmrBps,
        uint256 liquidationPenaltyBps,
        uint256 penaltyCap,
        uint256 maxPositionSize,
        uint256 minPositionSize
    ) external;

    /// @notice Pause or unpause a market.
    function pauseMarket(bytes32 marketId, bool paused) external;

    /// @notice Check if a position is liquidatable.
    function isLiquidatable(address account, bytes32 marketId) external view returns (bool);

    /// @notice Get position details.
    function getPosition(address account, bytes32 marketId) external view returns (PositionView memory);

    /// @notice Get notional value of a position.
    function getNotional(address account, bytes32 marketId) external view returns (uint256);

    /// @notice Get margin ratio of a position.
    function getMarginRatio(address account, bytes32 marketId) external view returns (uint256);

    /// @notice Get total account value.
    function getAccountValue(address account) external view returns (int256);
}
