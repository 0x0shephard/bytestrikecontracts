// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFeeRouter
/// @notice Splits and routes protocol fees and liquidation penalties.
interface IFeeRouter {
    /// @param amount Quote units (1e18) paid as trading fee.
    function onTradeFee(uint256 amount) external;

    /// @param amount Quote units (1e18) collected as liquidation penalty.
    function onLiquidationPenalty(uint256 amount) external;
}
