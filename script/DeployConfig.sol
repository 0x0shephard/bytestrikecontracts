// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";

/// @title DeployConfig
/// @notice Configuration helper for ByteStrike protocol deployment
/// @dev Stores network-specific addresses and parameters
contract DeployConfig is Script {

    // Sepolia Chainlink Price Feed addresses
    struct ChainlinkFeeds {
        address ethUsd;
        address usdcUsd;
        address btcUsd;
        address sequencerUptimeFeed;
    }

    // Deployment configuration
    struct Config {
        ChainlinkFeeds priceFeeds;
        address deployer;
        address treasuryAdmin;
        address pauseGuardian;
        address marketAdmin;
        address paramAdmin;
        uint256 initialEthPrice;  // 1e18 format
        uint256 initialBtcPrice;  // 1e18 format
    }

    // Sepolia configuration
    function getSepoliaConfig() public pure returns (Config memory) {
        return Config({
            priceFeeds: ChainlinkFeeds({
                // Sepolia Chainlink price feeds
                ethUsd: 0x694AA1769357215DE4FAC081bf1f309aDC325306,  // ETH/USD
                usdcUsd: 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E, // USDC/USD
                btcUsd: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,  // BTC/USD
                sequencerUptimeFeed: address(0) // No sequencer on Sepolia (L1)
            }),
            deployer: address(0), // Set by msg.sender in deployment
            treasuryAdmin: address(0), // Set by msg.sender initially
            pauseGuardian: address(0), // Set by msg.sender initially
            marketAdmin: address(0), // Set by msg.sender initially
            paramAdmin: address(0), // Set by msg.sender initially
            initialEthPrice: 3000e18,  // $3000 per ETH
            initialBtcPrice: 60000e18  // $60000 per BTC
        });
    }

    // Testnet mock token addresses (you may need to deploy these)
    struct TestTokens {
        address usdc;
        address weth;
        address wbtc;
    }

    function getSepoliaTestTokens() public pure returns (TestTokens memory) {
        return TestTokens({
            // These are placeholder addresses
            // You'll need to either:
            // 1. Deploy mock ERC20 tokens for testing
            // 2. Use existing Sepolia testnet tokens
            usdc: address(0), // Deploy MockUSDC or use existing
            weth: address(0), // Deploy MockWETH or use existing
            wbtc: address(0)  // Deploy MockWBTC or use existing
        });
    }

    // Trading parameters
    struct TradingParams {
        uint16 feeBps;              // Trade fee in basis points
        uint256 frMaxBpsPerHour;    // Funding rate clamp per hour
        uint256 kFundingX18;        // Funding scaling factor
        uint32 observationWindow;   // TWAP window in seconds
        uint16 tradeToFundBps;      // % of trade fees to insurance
        uint16 liqToFundBps;        // % of liq penalties to insurance
    }

    function getDefaultTradingParams() public pure returns (TradingParams memory) {
        return TradingParams({
            feeBps: 10,                    // 0.1% trade fee
            frMaxBpsPerHour: 100,          // 1% max funding rate per hour
            kFundingX18: 1e18,             // 1.0 funding scaling
            observationWindow: 3600,       // 1 hour TWAP
            tradeToFundBps: 5000,          // 50% of trade fees to insurance
            liqToFundBps: 3000             // 30% of liq penalties to insurance
        });
    }

    // vAMM initialization parameters
    struct VAMMParams {
        uint256 initialPriceX18;
        uint256 initialBaseReserve;
        uint128 liquidity;
    }

    function getDefaultVAMMParams() public pure returns (VAMMParams memory) {
        return VAMMParams({
            initialPriceX18: 3000e18,      // $3000 per ETH
            initialBaseReserve: 1000e18,   // 1000 ETH virtual reserve
            liquidity: 1e6                 // Initial liquidity denominator
        });
    }

    // Collateral configuration
    struct CollateralParams {
        uint256 baseUnit;
        uint16 haircutBps;
        uint16 liqIncentiveBps;
        uint256 cap;
        uint256 accountCap;
        bool enabled;
        bool depositPaused;
        bool withdrawPaused;
        string oracleSymbol;
    }

    function getUSDCCollateralParams() public pure returns (CollateralParams memory) {
        return CollateralParams({
            baseUnit: 1e6,           // 6 decimals
            haircutBps: 100,         // 1% haircut
            liqIncentiveBps: 500,    // 5% liquidation incentive
            cap: 10_000_000e6,       // 10M USDC cap
            accountCap: 1_000_000e6, // 1M USDC per account
            enabled: true,
            depositPaused: false,
            withdrawPaused: false,
            oracleSymbol: "USDC"
        });
    }

    function getWETHCollateralParams() public pure returns (CollateralParams memory) {
        return CollateralParams({
            baseUnit: 1e18,          // 18 decimals
            haircutBps: 500,         // 5% haircut (more risky than stablecoin)
            liqIncentiveBps: 1000,   // 10% liquidation incentive
            cap: 5_000e18,           // 5000 ETH cap
            accountCap: 500e18,      // 500 ETH per account
            enabled: true,
            depositPaused: false,
            withdrawPaused: false,
            oracleSymbol: "ETH"
        });
    }

    function getWBTCCollateralParams() public pure returns (CollateralParams memory) {
        return CollateralParams({
            baseUnit: 1e8,           // 8 decimals
            haircutBps: 500,         // 5% haircut
            liqIncentiveBps: 1000,   // 10% liquidation incentive
            cap: 100e8,              // 100 BTC cap
            accountCap: 10e8,        // 10 BTC per account
            enabled: true,
            depositPaused: false,
            withdrawPaused: false,
            oracleSymbol: "BTC"
        });
    }
}
