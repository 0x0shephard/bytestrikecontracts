// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IOracle {
    function getPrice() external view returns (uint256);
    function getPrice(string memory symbol) external view returns (uint256);
}

/// @notice Optional extension of a symbol oracle: when a symbol's price stopped being readable.
interface IOracleAvailability {
    /// @notice Timestamp from which getPrice(symbol) has been unreadable (stale round, sequencer down
    ///         or in its grace period), or 0 when the price is readable or that moment is unknown.
    function priceUnavailableSince(string memory symbol) external view returns (uint256);
}
