// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title CuOracle
 * @author Sheep
 * @dev A simple price oracle that uses a commit-reveal scheme to prevent front-running (sandwich attacks).
 * The owner first commits a hash of the price and a nonce, then reveals the price and nonce in a separate transaction.
 */
contract CuOracle {
    // --- Custom Errors ---
    error OnlyOwner();
    error OnlyAllowedRole();
    error InvalidAddress();
    error InvalidAssetId();
    error InvalidCommit();
    error InvalidNonce();
    error InvalidPrice();
    error InvalidInterval();
    error AssetNotSupported();
    error AssetAlreadyRegistered();
    error AssetNotRegistered();
    error MinTimeIntervalNotMet();
    error NoPriceCommitted();
    error CommitRevealDelayNotMet();
    error CommitExpired();
    error RoleAlreadyGranted();
    error RoleNotGranted();

    // --- State Variables ---
    address public owner;
    uint256 public minTimeInterval; // Minimum time between commits for same asset
    uint256 public minCommitRevealDelay; // Minimum time between commit and reveal
    uint256 public maxCommitAge; // Maximum time a commit is valid

    // --- Events ---
    event AssetRegistered(bytes32 indexed assetId);
    event AssetRemoved(bytes32 indexed assetId);
    event PriceUpdated(bytes32 indexed assetId, uint256 indexed price, uint256 timestamp);
    event PriceCommitted(bytes32 indexed assetId, uint256 commitTimestamp);
    event TimeIntervalUpdated(uint256 indexed newMinTimeInterval);
    event CommitRevealDelayUpdated(uint256 indexed newDelay);
    event MaxCommitAgeUpdated(uint256 indexed newMaxAge);
    event RoleGranted(address indexed role);
    event RoleRevoked(address indexed role);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    struct PriceData {
        uint256 price; // Price scaled by 1e18
        uint256 lastUpdatedAt;
    }

    // --- Mappings ---
    mapping(bytes32 => bool) public supportedAssets;
    mapping(bytes32 => bytes32) public priceCommits;
    mapping(bytes32 => uint256) public commitTimestamps; // Track when each commit was made
    mapping(bytes32 => uint256) public lastCommitTimestamp; // Per-asset last commit time
    mapping(bytes32 => PriceData) public latestPrices;
    mapping(address => bool) public allowedRoles;

    // --- Modifiers ---
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyAllowedRole() {
        if (msg.sender != owner && !allowedRoles[msg.sender]) revert OnlyAllowedRole();
        _;
    }

    /**
     * @dev Sets the owner of the contract upon deployment.
     * @param _owner The address of the owner.
     * @param _minTimeInterval Minimum time between commits for same asset.
     */
    constructor(address _owner, uint256 _minTimeInterval) {
        if (_owner == address(0)) revert InvalidAddress();
        if (_minTimeInterval == 0) revert InvalidInterval();

        owner = _owner;
        minTimeInterval = _minTimeInterval;
        minCommitRevealDelay = 1; // Default: at least 1 second between commit and reveal
        maxCommitAge = 1 hours; // Default: commits expire after 1 hour
    }

    /**
     * @dev Commits a hash for a future price update. This is the first step of the commit-reveal scheme.
     * @param _assetId The identifier of the asset for which the price is being committed.
     * @param _commit The keccak256 hash of the price and a secret nonce.
     */
    function commitPrice(bytes32 _assetId, bytes32 _commit) external onlyAllowedRole {
        if (_commit == 0) revert InvalidCommit();
        if (!supportedAssets[_assetId]) revert AssetNotSupported();
        if (lastCommitTimestamp[_assetId] + minTimeInterval > block.timestamp) {
            revert MinTimeIntervalNotMet();
        }

        priceCommits[_assetId] = _commit;
        commitTimestamps[_assetId] = block.timestamp;
        lastCommitTimestamp[_assetId] = block.timestamp;

        emit PriceCommitted(_assetId, block.timestamp);
    }

    /**
     * @dev Reveals the price and updates it. This is the second step of the commit-reveal scheme.
     * @param _assetId The identifier of the asset for which the price is being updated.
     * @param _price The actual price to be set, scaled by 1e18.
     * @param _nonce The secret nonce used to generate the commit hash.
     */
    function updatePrices(bytes32 _assetId, uint256 _price, bytes32 _nonce) external onlyOwner {
        if (!supportedAssets[_assetId]) revert AssetNotSupported();
        if (_nonce == 0) revert InvalidNonce();
        if (_price == 0) revert InvalidPrice();

        bytes32 commit = priceCommits[_assetId];
        if (commit == 0) revert NoPriceCommitted();

        uint256 commitTime = commitTimestamps[_assetId];

        // Ensure minimum delay between commit and reveal
        if (block.timestamp < commitTime + minCommitRevealDelay) {
            revert CommitRevealDelayNotMet();
        }

        // Ensure commit hasn't expired
        if (block.timestamp > commitTime + maxCommitAge) {
            revert CommitExpired();
        }

        // Verify the commitment
        if (keccak256(abi.encodePacked(_price, _nonce)) != commit) {
            revert InvalidPrice();
        }

        // Clear the commit
        delete priceCommits[_assetId];
        delete commitTimestamps[_assetId];

        // Update the price using commit time (when price was observed, not reveal time)
        latestPrices[_assetId] = PriceData({
            price: _price,
            lastUpdatedAt: commitTime
        });

        emit PriceUpdated(_assetId, _price, commitTime);
    }

    /**
     * @dev Allows owner to grant addresses permission to commit prices.
     * @param _role The address to be granted commit permissions.
     */
    function grantRole(address _role) external onlyOwner {
        if (_role == address(0)) revert InvalidAddress();
        if (allowedRoles[_role]) revert RoleAlreadyGranted();

        allowedRoles[_role] = true;
        emit RoleGranted(_role);
    }

    /**
     * @dev Allows owner to revoke commit permissions from an address.
     * @param _role The address to have permissions revoked.
     */
    function revokeRole(address _role) external onlyOwner {
        if (!allowedRoles[_role]) revert RoleNotGranted();

        allowedRoles[_role] = false;
        emit RoleRevoked(_role);
    }

    /**
     * @dev Allows owner to update the minimum time interval between commits.
     * @param _newMinTimeInterval The new minimum time interval in seconds.
     */
    function updateMinTimeInterval(uint256 _newMinTimeInterval) external onlyOwner {
        if (_newMinTimeInterval == 0) revert InvalidInterval();
        if (_newMinTimeInterval == minTimeInterval) revert InvalidInterval();

        minTimeInterval = _newMinTimeInterval;
        emit TimeIntervalUpdated(_newMinTimeInterval);
    }

    /**
     * @dev Allows owner to update the minimum delay between commit and reveal.
     * @param _newDelay The new minimum delay in seconds.
     */
    function updateCommitRevealDelay(uint256 _newDelay) external onlyOwner {
        minCommitRevealDelay = _newDelay;
        emit CommitRevealDelayUpdated(_newDelay);
    }

    /**
     * @dev Allows owner to update the maximum age of commits before expiration.
     * @param _newMaxAge The new maximum age in seconds.
     */
    function updateMaxCommitAge(uint256 _newMaxAge) external onlyOwner {
        if (_newMaxAge == 0) revert InvalidInterval();
        maxCommitAge = _newMaxAge;
        emit MaxCommitAgeUpdated(_newMaxAge);
    }

    /**
     * @dev Transfers ownership of the contract to a new address.
     * @param _newOwner The address of the new owner.
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidAddress();

        address previousOwner = owner;
        owner = _newOwner;
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    /**
     * @dev Reads the latest price data for a given asset.
     * @param _assetId The identifier of the asset to query.
     * @return The latest price data struct.
     */
    function getLatestPrice(bytes32 _assetId) external view returns (PriceData memory) {
        if (!supportedAssets[_assetId]) revert AssetNotSupported();
        return latestPrices[_assetId];
    }

    /**
     * @dev Registers a new asset id so that prices can be committed and updated.
     * @param _assetId The identifier used to represent the asset (e.g., keccak256 hash of a symbol).
     */
    function registerAsset(bytes32 _assetId) external onlyOwner {
        if (_assetId == 0) revert InvalidAssetId();
        if (supportedAssets[_assetId]) revert AssetAlreadyRegistered();

        supportedAssets[_assetId] = true;
        emit AssetRegistered(_assetId);
    }

    /**
     * @dev Removes an asset from the oracle and clears its pending data.
     * @param _assetId The identifier of the asset to remove.
     */
    function removeAsset(bytes32 _assetId) external onlyOwner {
        if (!supportedAssets[_assetId]) revert AssetNotRegistered();

        delete supportedAssets[_assetId];
        delete priceCommits[_assetId];
        delete commitTimestamps[_assetId];
        delete lastCommitTimestamp[_assetId];
        delete latestPrices[_assetId];

        emit AssetRemoved(_assetId);
    }
}
