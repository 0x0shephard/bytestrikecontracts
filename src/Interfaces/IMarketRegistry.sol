// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMarketRegistry
/// @notice Registers and configures perpetual markets with vAMM (Oracle + params) addressable by marketId.
interface IMarketRegistry {
    /// @dev Optimized struct layout for perpetual markets only
    /// Slot 0: vamm(20) + feeBps(2) + paused(1) = 23 bytes
    /// Slot 1: oracle(20)
    /// Slot 2: feeRouter(20)
    /// Slot 3: insuranceFund(20)
    /// Slot 4: baseAsset(20)
    /// Slot 5: quoteToken(20)
    /// Slot 6: baseUnit(32)
    struct Market {
        address vamm;                  // 20 bytes
        uint16 feeBps;                 // 2 bytes - trade fee in bps
        bool paused;                   // 1 byte - whether market is paused
        address oracle;                // 20 bytes (new slot)
        address feeRouter;             // 20 bytes (new slot)
        address insuranceFund;         // 20 bytes (new slot)
        address baseAsset;             // 20 bytes (new slot)
        address quoteToken;            // 20 bytes (new slot, e.g USDC, WETH)
        uint256 baseUnit;              // 32 bytes (new slot)
    }

    struct AddMarketConfig {
        bytes32 marketId;
        address vamm;
        address oracle;
        address baseAsset;
        address quoteToken;
        uint256 baseUnit;
        uint16 feeBps;
        address feeRouter;
        address insuranceFund;
    }

    event MarketAdded(
        bytes32 indexed marketId,
        address indexed vamm
    );
    event MarketPaused(bytes32 indexed marketId, bool paused);
    event MarketParamsUpdated(bytes32 indexed marketId, uint16 feeBps, address feeRouter, address insuranceFund);
    event VammUpdated(bytes32 indexed marketId, address indexed oldVamm, address indexed newVamm);
    event OracleUpdated(bytes32 indexed marketId, address indexed oldOracle, address indexed newOracle);

    function addMarket(AddMarketConfig calldata config) external;

    function setMarketParams(
        bytes32 marketId,
        uint16 feeBps,
        address feeRouter,
        address insuranceFund
    ) external;

    function setVamm(bytes32 marketId, address newVamm) external;
    function setOracle(bytes32 marketId, address newOracle) external;

    function pauseMarket(bytes32 marketId, bool paused) external;

    function getMarket(bytes32 marketId) external view returns (Market memory);
    function isActive(bytes32 marketId) external view returns (bool);
}
