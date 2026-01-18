// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "../Interfaces/IOracle.sol";
import {MultiAssetOracle} from "./MultiAssetOracle.sol";

/**
 * @title MultiAssetOracleAdapter
 * @notice Wraps the MultiAssetOracle for a specific asset to implement the IOracle interface
 * @dev Each vAMM requires an IOracle that returns a single price. This adapter wraps the
 *      MultiAssetOracle for a specific assetId, allowing multiple markets to share one oracle contract.
 */
contract MultiAssetOracleAdapter is IOracle {
    // --- Errors ---
    error MultiAssetOracleAdapter_OracleZeroAddress();
    error MultiAssetOracleAdapter_AssetIdZero();
    error MultiAssetOracleAdapter_PriceZero();
    error MultiAssetOracleAdapter_PriceStale();

    // --- Immutable State ---

    /// @notice The underlying MultiAssetOracle contract
    MultiAssetOracle public immutable oracle;

    /// @notice The asset identifier this adapter wraps
    bytes32 public immutable assetId;

    /// @notice Maximum allowed age of price data in seconds. 0 disables staleness check.
    uint256 public immutable maxAge;

    // --- Constructor ---

    /// @param _oracle Address of the MultiAssetOracle contract
    /// @param _assetId The asset identifier to wrap (e.g., keccak256("H100_HOURLY"))
    /// @param _maxAge Maximum allowed age of price in seconds (0 to disable)
    constructor(address _oracle, bytes32 _assetId, uint256 _maxAge) {
        if (_oracle == address(0)) revert MultiAssetOracleAdapter_OracleZeroAddress();
        if (_assetId == bytes32(0)) revert MultiAssetOracleAdapter_AssetIdZero();

        oracle = MultiAssetOracle(_oracle);
        assetId = _assetId;
        maxAge = _maxAge;
    }

    // --- IOracle Implementation ---

    /// @inheritdoc IOracle
    /// @notice Returns the price for this adapter's asset in 1e18 format
    function getPrice() external view override returns (uint256) {
        (uint256 price, uint256 updatedAt) = oracle.getPriceData(assetId);

        if (price == 0) revert MultiAssetOracleAdapter_PriceZero();

        // Check staleness if maxAge is set
        if (maxAge != 0 && block.timestamp - updatedAt > maxAge) {
            revert MultiAssetOracleAdapter_PriceStale();
        }

        return price;
    }

    // --- View Functions ---

    /// @notice Get the full price data from the underlying oracle
    /// @return price The price in 1e18 format
    /// @return updatedAt The timestamp of the last update
    function getPriceData() external view returns (uint256 price, uint256 updatedAt) {
        return oracle.getPriceData(assetId);
    }

    /// @notice Check if the price is stale based on maxAge
    /// @return True if the price is stale
    function isStale() external view returns (bool) {
        if (maxAge == 0) return false;
        (, uint256 updatedAt) = oracle.getPriceData(assetId);
        return block.timestamp - updatedAt > maxAge;
    }
}
