// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Minimal Chainlink AggregatorV3Interface used by Oracle
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    /// @notice Returns the address of the underlying aggregator
    function aggregator() external view returns (address);
}

/// @notice Interface for the underlying Chainlink aggregator to get min/max answer bounds
interface AggregatorInterface {
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}
