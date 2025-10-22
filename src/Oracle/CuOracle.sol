// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title Oracle
 * @author Sheep
 * @dev A simple price oracle that uses a commit-reveal scheme to prevent front-running (sandwich attacks).
 * The owner first commits a hash of the price and a nonce, then reveals the price and nonce in a separate transaction.
 */
contract CuOracle {
    // The address of the contract owner, who is authorized to update prices.
    address public owner;
    // Minimum time should elapse before the price update
    uint256 minTimeInterval;

    // The last time the price was updated.
    uint256 lastUpdateTimestamp;

    // Event emitted when an asset is registered or removed.
    event assetRegistered(bytes32 indexed assetId);
    event assetRemoved(bytes32 indexed assetId);
    // Event emitted when a price is successfully updated.
    event priceUpdated(bytes32 indexed assetId, uint256 indexed price, uint256 timestamp);
    // Event emitted when a new price commit is made.
    event priceCommited(bytes32 indexed assetId);
    // Event emiited when a new TimeInterval is updated
    event timeIntervalUpdated (uint256 indexed _newMinTimeInterval);

    struct PriceData {
        uint256 price; // Price scaled by 1e18
        uint256 lastUpdatedAt;
    }

    // Mapping to track which asset ids are supported by the oracle.
    mapping(bytes32 => bool) public supportedAssets;
    // Mapping from an asset to the committed hash. The hash is a keccak256 of the price and a secret nonce.
    mapping(bytes32 => bytes32) public priceCommits;
    // Mapping from an asset to its latest price data.
    mapping(bytes32 => PriceData) public latestPrices;
    // Mapping from an address to its allowed role status.
    mapping(address => bool) public allowedRoles;
    // Modifier to restrict access to allowed roles.
    modifier onlyAllowedRole() {
        require(msg.sender == owner || allowedRoles[msg.sender], "Not allowed");
        _;
    }

    /**
     * @dev Sets the owner of the contract upon deployment.
     * @param _owner The address of the owner.
     */
    constructor (address _owner, uint256 _minTimeInterval) {
        owner = _owner;
        minTimeInterval = _minTimeInterval;
    }

    /**
     * @dev Commits a hash for a future price update. This is the first step of the commit-reveal scheme.
    * @param _assetId The identifier of the asset for which the price is being committed.
     * @param _commit The keccak256 hash of the price and a secret nonce.
     */
    function commitPrice(bytes32 _assetId, bytes32 _commit) external onlyAllowedRole {
        require (_commit != 0, "Invalid commit");
        require (lastUpdateTimestamp + minTimeInterval <= block.timestamp, "Minimum time interval not met");
        require(supportedAssets[_assetId], "Asset not supported");
        priceCommits[_assetId] = _commit;
        lastUpdateTimestamp = block.timestamp;
        emit priceCommited(_assetId);
    }

    /**
     * @dev Reveals the price and updates it. This is the second step of the commit-reveal scheme.
    * @param _assetId The identifier of the asset for which the price is being updated.
     * @param _price The actual price to be set, scaled by 1e18.
     * @param _nonce The secret nonce used to generate the commit hash.
     */
    function updatePrices(bytes32 _assetId, uint256 _price, bytes32 _nonce) external {
        require(msg.sender == owner, "Only owner can update prices");
        require(_nonce != 0 || _price != 0, "Invalid nonce or price");
        require(supportedAssets[_assetId], "Asset not supported");
        bytes32 commit = priceCommits[_assetId];
        require(commit != 0, "No price Commited");
        require(keccak256(abi.encodePacked(_price, _nonce)) == commit, "Invalid Price");
        delete priceCommits[_assetId];
        
        latestPrices[_assetId] = PriceData({
            price: _price,
            lastUpdatedAt: block.timestamp
        });

        emit priceUpdated(_assetId, _price, block.timestamp);
    }

    /**
     * @dev Allows onwer to add addresses allowed to commit prices
     * @param _role The address to be allowed to commit prices.
     */
    function allowRole(address _role) external {
        require(msg.sender == owner, "Only owner can allow roles");
        require(_role != address(0), "Invalid Address");
        allowedRoles[_role] = true;
    }

    /**
     * @dev Allows onwer to update the minTimeInterval
     * @param _newMinTimeInterval The value by which the Interval is replaced
     */
    function updateMinTimeInterval(uint256 _newMinTimeInterval) external {
        require (msg.sender == owner, "Only owner allowed");
        require(_newMinTimeInterval != 0 && _newMinTimeInterval != minTimeInterval, "Invalid Interval");
        minTimeInterval = _newMinTimeInterval;
        emit timeIntervalUpdated(_newMinTimeInterval);  
    }

    /**
     * @dev Reads the latest price data for a given asset.
    * @param _assetId The identifier of the asset to query.
     * @return The latest price data struct.
     */
    function getLatestPrice(bytes32 _assetId) external view returns (PriceData memory) {
        require(supportedAssets[_assetId], "Asset not supported");
        return latestPrices[_assetId];
    }

    /**
     * @dev Registers a new asset id so that prices can be committed and updated.
     * @param _assetId The identifier used to represent the asset (e.g., keccak256 hash of a symbol).
     */
    function registerAsset(bytes32 _assetId) external {
        require(msg.sender == owner, "Only owner can register assets");
        require(_assetId != 0, "Invalid asset id");
        require(!supportedAssets[_assetId], "Asset already registered");
        supportedAssets[_assetId] = true;
        emit assetRegistered(_assetId);
    }

    /**
     * @dev Removes an asset from the oracle and clears its pending data.
     * @param _assetId The identifier of the asset to remove.
     */
    function removeAsset(bytes32 _assetId) external {
        require(msg.sender == owner, "Only owner can remove assets");
        require(supportedAssets[_assetId], "Asset not registered");
        delete supportedAssets[_assetId];
        delete priceCommits[_assetId];
        delete latestPrices[_assetId];
        emit assetRemoved(_assetId);
    }
}
