// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SetupETHPerpV2
 * @notice Complete setup for ETH-PERP-V2 market
 * Steps:
 * 1. Add market to registry
 * 2. Set risk parameters in ClearingHouse
 * 3. Mint USDC to trader
 * 4. Approve and deposit USDC to CollateralVault
 */
contract SetupETHPerpV2 is Script {
    // Contract addresses
    address constant CLEARING_HOUSE = 0x0BE85ed0948779a01efFB6b017ae87A4E9EB7FD6;
    address constant MARKET_REGISTRY = 0x01D2bdbed2cc4eC55B0eA92edA1aAb47d57627fD; // Actual registry from ClearingHouse
    address constant COLLATERAL_VAULT = 0x46615074Bb2bAA2b33553d50A25D0e4f2ec4542e;
    address constant VAMM_V2 = 0x3f9b634b9f09e7F8e84348122c86d3C2324841b5; // New vAMM with $3.75 oracle
    address constant ORACLE = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c; // CuOracle with $3.75 price
    address constant FEE_ROUTER = 0xc6B7aE853742992297a7526F5De7fdbF8164e687;
    address constant INSURANCE_FUND = 0x7d8B6B91aAC78F65EBc1D39d0a5c3608115Afe42;
    address constant MOCK_USDC = 0x71075745A2A63dff3BD4819e9639D0E412c14AA9;
    address constant MOCK_WETH = 0x36EC0f183Bd4014097934dcD7e23d9A5F0a69b40;

    // Market ID will be computed from parameters
    bytes32 public marketId;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  SETUP ETH-PERP-V2 MARKET");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("");

        // Compute market ID
        marketId = keccak256(abi.encodePacked("ETH-PERP-V2", VAMM_V2));
        console.log("Market ID:", vm.toString(marketId));
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // STEP 1: Add market to registry
        console.log("STEP 1: Adding market to MarketRegistry...");
        IMarketRegistry registry = IMarketRegistry(MARKET_REGISTRY);

        // Check if already added
        IMarketRegistry.Market memory existing = registry.getMarket(marketId);
        if (existing.vamm == address(0)) {
            // Market doesn't exist, add it
            IMarketRegistry.AddMarketConfig memory config = IMarketRegistry.AddMarketConfig({
                marketId: marketId,
                vamm: VAMM_V2,
                oracle: ORACLE,
                baseAsset: MOCK_WETH,
                quoteToken: MOCK_USDC,
                baseUnit: 1e18,
                feeBps: 10, // 0.1% fee
                feeRouter: FEE_ROUTER,
                insuranceFund: INSURANCE_FUND
            });

            registry.addMarket(config);
            console.log("  Market added successfully!");
        } else {
            console.log("  Market already exists, skipping add");
        }
        console.log("");

        // STEP 2: Set risk parameters
        console.log("STEP 2: Setting risk parameters...");
        ClearingHouse ch = ClearingHouse(CLEARING_HOUSE);

        uint256 imrBps = 1000;       // 10% initial margin
        uint256 mmrBps = 500;        // 5% maintenance margin
        uint256 liqPenaltyBps = 250; // 2.5% liquidation penalty
        uint256 penaltyCap = 1000e18; // 1000 USDC cap
        uint256 maxPositionSize = 0; // unlimited
        uint256 minPositionSize = 0; // no minimum

        ch.setRiskParams(marketId, imrBps, mmrBps, liqPenaltyBps, penaltyCap, maxPositionSize, minPositionSize);
        console.log("  Risk parameters set:");
        console.log("    IMR: 10% (1000 bps)");
        console.log("    MMR: 5% (500 bps)");
        console.log("    Liquidation Penalty: 2.5% (250 bps)");
        console.log("    Penalty Cap: 1000 USDC");
        console.log("");

        // STEP 3: Mint USDC to trader
        console.log("STEP 3: Minting USDC to trader...");
        MockUSDC usdc = MockUSDC(MOCK_USDC);
        uint256 mintAmount = 10000e6; // 10,000 USDC

        try usdc.mint(deployer, mintAmount) {
            console.log("  Minted", mintAmount / 1e6, "USDC to", deployer);
        } catch {
            console.log("  Mint failed (may not have permission or already have balance)");
        }

        uint256 balance = usdc.balanceOf(deployer);
        console.log("  Current USDC balance:", balance / 1e6, "USDC");
        console.log("");

        // STEP 4: Approve and deposit USDC
        console.log("STEP 4: Depositing USDC to CollateralVault...");
        uint256 depositAmount = 5000e6; // Deposit 5,000 USDC

        if (balance >= depositAmount) {
            // Approve
            usdc.approve(COLLATERAL_VAULT, depositAmount);
            console.log("  Approved", depositAmount / 1e6, "USDC");

            // Deposit via ClearingHouse
            ch.deposit(MOCK_USDC, depositAmount);
            console.log("  Deposited", depositAmount / 1e6, "USDC to vault");
        } else {
            console.log("  Insufficient balance for deposit");
        }
        console.log("");

        vm.stopBroadcast();

        // VERIFICATION
        console.log("=========================================");
        console.log("  VERIFICATION");
        console.log("=========================================");
        console.log("");

        // Check market is active
        bool isActive = registry.isActive(marketId);
        console.log("Market Active:", isActive);

        // Check risk params
        (uint256 imr, uint256 mmr, uint256 liqPen, uint256 cap, uint256 maxSize, uint256 minSize) = ch.marketRiskParams(marketId);
        console.log("IMR BPS:", imr);
        console.log("MMR BPS:", mmr);
        console.log("Liq Penalty BPS:", liqPen);
        console.log("Penalty Cap:", cap);
        console.log("Max Position Size:", maxSize);
        console.log("Min Position Size:", minSize);

        // Check collateral
        ICollateralVault vault = ICollateralVault(COLLATERAL_VAULT);
        uint256 vaultBalance = vault.balanceOf(deployer, MOCK_USDC);
        console.log("Vault USDC Balance:", vaultBalance / 1e6, "USDC");

        uint256 collateralValue = vault.getAccountCollateralValueX18(deployer);
        console.log("Total Collateral Value (USD):", collateralValue / 1e18, "USD");
        console.log("");

        console.log("=========================================");
        console.log("  SETUP COMPLETE!");
        console.log("=========================================");
        console.log("");
        console.log("Market ID for frontend:", vm.toString(marketId));
        console.log("");
        console.log("You can now:");
        console.log("1. Update frontend with new market ID");
        console.log("2. Test opening positions on ETH-PERP-V2");
    }
}

interface MockUSDC {
    function mint(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICollateralVault {
    function balanceOf(address user, address token) external view returns (uint256);
    function getAccountCollateralValueX18(address user) external view returns (uint256);
}
