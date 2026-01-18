//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMarketRegistry} from "./Interfaces/IMarketRegistry.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";


/// @title MarketRegistry
/// @notice Registers, updates, and pauses perpetual markets (vAMM + Oracle + params) keyed by marketId.
/// @dev Uses AccessControl for role-separated permissions. Events are inherited from the interface.
contract MarketRegistry is IMarketRegistry, AccessControl {
    // marketId => Market data
    mapping(bytes32 MarketId => Market) public markets;

    /// @notice Max trade fee in basis points that governance allows (3.00%).
    uint16 public constant MAX_FEE_BPS = 300; // 3.00% cap

    /// @notice Role allowed to add/unpause markets.
    bytes32 public constant MARKET_ADMIN_ROLE = keccak256("MARKET_ADMIN_ROLE");
    /// @notice Role allowed to update fee params.
    bytes32 public constant PARAM_ADMIN_ROLE = keccak256("PARAM_ADMIN_ROLE");
    /// @notice Role allowed to pause markets quickly.
    bytes32 public constant PAUSE_GUARDIAN_ROLE = keccak256("PAUSE_GUARDIAN_ROLE");


    /// @dev Helper modifier: either MARKET_ADMIN or DEFAULT_ADMIN.
    modifier onlyAllowed() {
        require(
            hasRole(MARKET_ADMIN_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Not market admin"
        );
        _;
    }


    /// @notice Constructor grants DEFAULT_ADMIN to the deployer to bootstrap role assignments.
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }


    /// @notice Register a new perpetual market with its vAMM, oracle, fee router, insurance fund and metadata.
    /// @param config Packed market configuration including routing and metadata.
    function addMarket(AddMarketConfig calldata config) external override onlyAllowed {
        // Uniqueness and basic sanity checks
        Market storage market = markets[config.marketId];
        _validateConfig(config, market);
        _storeMarket(config, market);
        emit MarketAdded(config.marketId, config.vamm);
    }

    function _validateConfig(AddMarketConfig calldata config, Market storage market)
        private
        view
    {
        require(config.marketId != bytes32(0), "Zero marketId");
        require(market.vamm == address(0), "Market Exists");
        require(config.vamm != address(0), "vAMM addr(0)");
        require(config.oracle != address(0), "Oracle addr(0)");
        require(config.baseAsset != address(0), "Base addr(0)");
        require(config.quoteToken != address(0), "Quote addr(0)");
        require(config.baseAsset != config.quoteToken, "Base=Quote");
        require(config.baseUnit > 0, "Base unit 0");
        require(config.feeRouter != address(0), "FeeRouter addr(0)");
        require(config.insuranceFund != address(0), "IF addr(0)");
        require(config.feeBps <= MAX_FEE_BPS, "Fee too high");
    }

    function _storeMarket(
        AddMarketConfig calldata config,
        Market storage market
    ) private {
        market.vamm = config.vamm;
        market.feeBps = config.feeBps;
        market.paused = false;          // markets start unpaused
        market.oracle = config.oracle;
        market.feeRouter = config.feeRouter;
        market.insuranceFund = config.insuranceFund;
        market.baseAsset = config.baseAsset;
        market.quoteToken = config.quoteToken;
        market.baseUnit = config.baseUnit;
    }

    /// @notice Update fee params and routing for an existing market.
    function setMarketParams(
        bytes32 marketId,
        uint16 feeBps,
        address feeRouter,
        address insuranceFund
    ) external override onlyRole(PARAM_ADMIN_ROLE) {
        Market storage market = markets[marketId];
        require(market.vamm != address(0), "No such market");
        require(feeBps <= MAX_FEE_BPS, "Fee too high");
        require(feeRouter != address(0), "FeeRouter addr(0)");
        require(insuranceFund != address(0), "IF addr(0)");

        market.feeBps = feeBps;
        market.feeRouter = feeRouter;
        market.insuranceFund = insuranceFund;
        emit MarketParamsUpdated(marketId, feeBps, feeRouter, insuranceFund);
    }

    /// @notice Update the vAMM address for an existing market.
    /// @dev Only callable by MARKET_ADMIN or DEFAULT_ADMIN. Use when migrating to upgraded vAMM.
    /// @param marketId The ID of the market to update.
    /// @param newVamm The new vAMM contract address.
    function setVamm(bytes32 marketId, address newVamm) external onlyAllowed {
        Market storage market = markets[marketId];
        require(market.vamm != address(0), "No such market");
        require(newVamm != address(0), "vAMM addr(0)");
        
        address oldVamm = market.vamm;
        market.vamm = newVamm;
        emit VammUpdated(marketId, oldVamm, newVamm);
    }

    /// @notice Update the oracle address for an existing market.
    /// @dev Only callable by MARKET_ADMIN or DEFAULT_ADMIN. Use when migrating to upgraded oracle.
    /// @param marketId The ID of the market to update.
    /// @param newOracle The new oracle contract address.
    function setOracle(bytes32 marketId, address newOracle) external onlyAllowed {
        Market storage market = markets[marketId];
        require(market.vamm != address(0), "No such market");
        require(newOracle != address(0), "Oracle addr(0)");
        
        address oldOracle = market.oracle;
        market.oracle = newOracle;
        emit OracleUpdated(marketId, oldOracle, newOracle);
    }

    /// @notice Pause or unpause a market.
    /// @dev Pausing requires PAUSE_GUARDIAN or DEFAULT_ADMIN. Unpausing requires MARKET_ADMIN or DEFAULT_ADMIN.
    function pauseMarket(bytes32 marketId, bool paused) external override {
        Market storage market = markets[marketId];
        require(market.vamm != address(0), "No such market");
        if (paused) {
            require(
                hasRole(PAUSE_GUARDIAN_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
                "No pause role"
            );
        } else {
            require(
                hasRole(MARKET_ADMIN_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
                "No unpause role"
            );
        }
        market.paused = paused;
        emit MarketPaused(marketId, paused);
    }


    /// @notice Return the stored Market struct for a given marketId.
    function getMarket(bytes32 marketId) external view override returns (Market memory) {
        return markets[marketId];
    }

    /// @notice Convenience getter for paused status
    function isPaused(bytes32 marketId) external view returns (bool) {
        return markets[marketId].paused;
    }

    /// @notice Whether a market is generally active for trading (excludes paused).
    function isActive(bytes32 marketId) external view override returns (bool) {
        Market memory market = markets[marketId];
        if (market.vamm == address(0) || market.oracle == address(0)) {
            return false;
        }
        return !market.paused;
    }

    // ===== Helpers (not in interface) =====
    /// @notice Returns true if a marketId has been registered.
    function exists(bytes32 marketId) external view returns (bool) {
        return markets[marketId].vamm != address(0);
    }
}
