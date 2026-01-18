// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title MultiAssetOracle
 * @notice Simple oracle that stores index prices for multiple assets with owner update capability
 * @dev Each asset is identified by a bytes32 assetId. Prices are stored in 1e18 format.
 */
contract MultiAssetOracle {
    // --- Errors ---
    error OnlyOwner();
    error InvalidPrice();
    error InvalidAssetId();
    error AssetNotRegistered();
    error AssetAlreadyRegistered();

    // --- State Variables ---
    address public owner;

    /// @notice Mapping from assetId to price in 1e18 format
    mapping(bytes32 => uint256) public prices;

    /// @notice Mapping from assetId to last update timestamp
    mapping(bytes32 => uint256) public lastUpdated;

    /// @notice Mapping to track registered assets
    mapping(bytes32 => bool) public registeredAssets;

    // --- Events ---
    event PriceUpdated(bytes32 indexed assetId, uint256 indexed newPrice, uint256 timestamp);
    event AssetRegistered(bytes32 indexed assetId, uint256 initialPrice);
    event AssetRemoved(bytes32 indexed assetId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // --- Modifiers ---
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier assetExists(bytes32 assetId) {
        if (!registeredAssets[assetId]) revert AssetNotRegistered();
        _;
    }

    // --- Constructor ---
    constructor() {
        owner = msg.sender;
    }

    // --- Asset Management ---

    /// @notice Register a new asset with an initial price
    /// @param assetId The unique identifier for the asset (e.g., keccak256("H100_HOURLY"))
    /// @param initialPrice The initial price in 1e18 format
    function registerAsset(bytes32 assetId, uint256 initialPrice) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        if (registeredAssets[assetId]) revert AssetAlreadyRegistered();
        if (initialPrice == 0) revert InvalidPrice();

        registeredAssets[assetId] = true;
        prices[assetId] = initialPrice;
        lastUpdated[assetId] = block.timestamp;

        emit AssetRegistered(assetId, initialPrice);
        emit PriceUpdated(assetId, initialPrice, block.timestamp);
    }

    /// @notice Remove an asset from the oracle
    /// @param assetId The asset identifier to remove
    function removeAsset(bytes32 assetId) external onlyOwner assetExists(assetId) {
        delete registeredAssets[assetId];
        delete prices[assetId];
        delete lastUpdated[assetId];

        emit AssetRemoved(assetId);
    }

    // --- Price Updates ---

    /// @notice Update the price for a registered asset (owner only)
    /// @param assetId The asset identifier
    /// @param newPrice New price in 1e18 format (e.g., 3.79e18 for $3.79)
    function updatePrice(bytes32 assetId, uint256 newPrice) external onlyOwner assetExists(assetId) {
        if (newPrice == 0) revert InvalidPrice();

        prices[assetId] = newPrice;
        lastUpdated[assetId] = block.timestamp;

        emit PriceUpdated(assetId, newPrice, block.timestamp);
    }

    /// @notice Batch update prices for multiple assets
    /// @param assetIds Array of asset identifiers
    /// @param newPrices Array of new prices in 1e18 format
    function batchUpdatePrices(bytes32[] calldata assetIds, uint256[] calldata newPrices) external onlyOwner {
        require(assetIds.length == newPrices.length, "Length mismatch");

        for (uint256 i = 0; i < assetIds.length; i++) {
            bytes32 assetId = assetIds[i];
            uint256 newPrice = newPrices[i];

            if (!registeredAssets[assetId]) revert AssetNotRegistered();
            if (newPrice == 0) revert InvalidPrice();

            prices[assetId] = newPrice;
            lastUpdated[assetId] = block.timestamp;

            emit PriceUpdated(assetId, newPrice, block.timestamp);
        }
    }

    // --- View Functions ---

    /// @notice Get the price for a registered asset
    /// @param assetId The asset identifier
    /// @return The price in 1e18 format
    function getPrice(bytes32 assetId) external view assetExists(assetId) returns (uint256) {
        return prices[assetId];
    }

    /// @notice Get price data for a registered asset
    /// @param assetId The asset identifier
    /// @return price The price in 1e18 format
    /// @return updatedAt The timestamp of the last update
    function getPriceData(bytes32 assetId) external view assetExists(assetId) returns (uint256 price, uint256 updatedAt) {
        return (prices[assetId], lastUpdated[assetId]);
    }

    /// @notice Check if an asset is registered
    /// @param assetId The asset identifier
    /// @return True if the asset is registered
    function isAssetRegistered(bytes32 assetId) external view returns (bool) {
        return registeredAssets[assetId];
    }

    // --- Ownership ---

    /// @notice Transfer ownership to a new address
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidPrice();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}
