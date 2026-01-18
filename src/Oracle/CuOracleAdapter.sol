// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "../Interfaces/IOracle.sol";
import {CuOracle} from "./CuOracle.sol";

/// @title CuOracleAdapter
/// @notice Wraps the commit/reveal CuOracle so it can be plugged anywhere an `IOracle` is required.
/// @dev Performs basic sanity checks (asset support, non-zero price, optional staleness guard).
contract CuOracleAdapter is IOracle {
    error CuOracleAdapter_OracleZeroAddress();
    error CuOracleAdapter_AssetIdZero();
    error CuOracleAdapter_PriceZero();
    error CuOracleAdapter_PriceStale();

    /// @notice Underlying commit/reveal oracle.
    CuOracle public immutable cuOracle;

    /// @notice Asset identifier understood by the cuOracle instance.
    bytes32 public immutable assetId;

    /// @notice Maximum allowed age of price data in seconds. `0` disables the staleness check.
    uint256 public immutable maxAge;

    constructor(address _cuOracle, bytes32 _assetId, uint256 _maxAge) {
        if (_cuOracle == address(0)) revert CuOracleAdapter_OracleZeroAddress();
        if (_assetId == bytes32(0)) revert CuOracleAdapter_AssetIdZero();

        cuOracle = CuOracle(_cuOracle);
        assetId = _assetId;
        maxAge = _maxAge;
    }

    /// @inheritdoc IOracle
    function getPrice() external view override returns (uint256) {
        CuOracle.PriceData memory data = cuOracle.getLatestPrice(assetId);
        if (data.price == 0) revert CuOracleAdapter_PriceZero();
        if (maxAge != 0 && block.timestamp - data.lastUpdatedAt > maxAge) revert CuOracleAdapter_PriceStale();
        return data.price;
    }
}
