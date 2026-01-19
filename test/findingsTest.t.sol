// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BaseTest} from "./BaseTest.sol";
import {MockERC20} from "../script/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {vAMM} from "../src/vAMM.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Mock oracle that returns zero price
contract ZeroOracle {
    function getPrice() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Mock oracle that always reverts
contract RevertingOracle {
    function getPrice() external pure returns (uint256) {
        revert("Oracle failed");
    }
}

/// @title AuditFindingsTest
/// @notice Tests to verify the audit findings are valid vulnerabilities
/// @dev Each test demonstrates a specific vulnerability identified in the audit
contract AuditFindingsTest is BaseTest {
    address public attacker;

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("attacker");
    }

    // ============================================================
    // CRITICAL: IMR Collateral Check Bypass
    // Location: ClearingHouse.sol:741-802
    // ============================================================

    /// @notice Test if users can open positions with ZERO collateral
    /// @dev If bug exists: position opens. If fixed: reverts with "CH: insufficient collateral"
    function test_CRITICAL_OpenPositionWithZeroCollateral() public {
        // Attacker has NO collateral deposited
        uint256 attackerCollateral = vault.getAccountCollateralValueX18(attacker);
        assertEq(attackerCollateral, 0, "Attacker should have zero collateral");

        // Attacker attempts to open a position
        // With 5% IMR and $2000 ETH price, 1 ETH position needs $100 margin
        uint128 positionSize = 1 ether; // 1 ETH

        vm.startPrank(attacker);

        // Try to open position - capture if it reverts or succeeds
        bool success;
        try clearingHouse.openPosition(ETH_PERP, true, positionSize, 0) {
            success = true;
        } catch {
            success = false;
        }

        vm.stopPrank();

        IClearingHouse.PositionView memory pos = clearingHouse.getPosition(attacker, ETH_PERP);

        console.log("=== CRITICAL BUG TEST: Zero Collateral Position ===");
        console.log("Attacker collateral in vault:", attackerCollateral);
        console.log("Position opened successfully:", success);
        console.log("Position size:", uint256(pos.size > 0 ? pos.size : -pos.size));
        console.log("Position margin:", pos.margin);

        if (success && pos.size != 0) {
            console.log("");
            console.log("!!! BUG CONFIRMED: Position opened with ZERO collateral !!!");
            console.log("This is a CRITICAL vulnerability!");
            // Fail the test to highlight the bug
            assertTrue(false, "BUG: Position opened with zero collateral - CRITICAL VULNERABILITY");
        } else {
            console.log("");
            console.log("GOOD: Position was rejected (collateral check works)");
            assertTrue(true, "Collateral check is working correctly");
        }
    }

    /// @notice Test if reserved margin can exceed actual collateral
    /// @dev If bug exists: reserved margin > collateral. If fixed: reverts
    function test_CRITICAL_ReservedMarginExceedsCollateral() public {
        // Give attacker a tiny amount of collateral
        uint256 tinyCollateral = 1 * USDC_UNIT; // Only $1
        fundAndDeposit(attacker, tinyCollateral);

        // Try to open a large position worth $2000 (1 ETH at $2000)
        // Should need $100 margin (5% IMR) but attacker only has $1
        uint128 positionSize = 1 ether;

        vm.startPrank(attacker);

        bool success;
        try clearingHouse.openPosition(ETH_PERP, true, positionSize, 0) {
            success = true;
        } catch {
            success = false;
        }

        vm.stopPrank();

        uint256 collateralValue = vault.getAccountCollateralValueX18(attacker);
        uint256 reservedMargin = clearingHouse._totalReservedMargin(attacker);
        IClearingHouse.PositionView memory pos = clearingHouse.getPosition(attacker, ETH_PERP);

        console.log("=== CRITICAL BUG TEST: Phantom Margin ===");
        console.log("Actual collateral:", collateralValue);
        console.log("Reserved margin:", reservedMargin);
        console.log("Position opened:", success);
        console.log("Position size:", uint256(pos.size > 0 ? pos.size : -pos.size));

        if (success && reservedMargin > collateralValue) {
            console.log("");
            console.log("!!! BUG CONFIRMED: Reserved margin exceeds actual collateral !!!");
            console.log("Phantom margin created:", reservedMargin - collateralValue);
            assertTrue(false, "BUG: Reserved margin exceeds collateral - CRITICAL VULNERABILITY");
        } else if (success) {
            console.log("");
            console.log("Position opened but margin <= collateral (unexpected)");
        } else {
            console.log("");
            console.log("GOOD: Position was rejected (collateral check works)");
            assertTrue(reservedMargin <= collateralValue, "Reserved margin should not exceed collateral");
        }
    }

    /// @notice Direct test of _applyTrade logic - check if collateral is verified
    /// @dev This test checks if the IMR check at line 796-802 actually enforces collateral
    function test_CRITICAL_IMRCheckBypassAnalysis() public {
        // Setup: User with exactly enough collateral for 1 ETH position
        // 1 ETH at $2000 = $2000 notional, 5% IMR = $100 needed
        // Plus trading fee ~0.1% = $2, so ~$102 total

        uint256 exactCollateral = 105 * USDC_UNIT; // $105 - just enough
        fundAndDeposit(alice, exactCollateral);

        vm.startPrank(alice);

        // This should work - alice has enough
        clearingHouse.openPosition(ETH_PERP, true, 1 ether, 0);

        vm.stopPrank();

        IClearingHouse.PositionView memory pos1 = clearingHouse.getPosition(alice, ETH_PERP);
        uint256 reserved1 = clearingHouse._totalReservedMargin(alice);
        uint256 collateral1 = vault.getAccountCollateralValueX18(alice);

        console.log("=== Alice's Position (has collateral) ===");
        console.log("Collateral:", collateral1);
        console.log("Reserved margin:", reserved1);
        console.log("Position margin:", pos1.margin);
        console.log("Position size:", uint256(pos1.size));

        // Now test with zero collateral user
        vm.startPrank(attacker);

        bool attackerSuccess;
        try clearingHouse.openPosition(ETH_PERP, true, 1 ether, 0) {
            attackerSuccess = true;
        } catch {
            attackerSuccess = false;
        }

        vm.stopPrank();

        console.log("");
        console.log("=== Attacker's Attempt (zero collateral) ===");
        console.log("Attacker collateral:", vault.getAccountCollateralValueX18(attacker));
        console.log("Position opened:", attackerSuccess);

        if (attackerSuccess) {
            IClearingHouse.PositionView memory pos2 = clearingHouse.getPosition(attacker, ETH_PERP);
            console.log("Attacker position size:", uint256(pos2.size));
            console.log("Attacker position margin:", pos2.margin);
            console.log("");
            console.log("!!! CRITICAL BUG: Zero-collateral position opened !!!");
        } else {
            console.log("GOOD: Zero-collateral position rejected");
        }
    }

    // ============================================================
    // HIGH #1: Realized Losses Forgiven
    // Location: ClearingHouse.sol:757-767
    // ============================================================

    /// @notice Demonstrates that realized losses beyond margin are forgiven
    /// @dev Losses should be collected from free collateral but are simply zeroed
    function test_HIGH_RealizedLossesForgiven() public {
        // Setup: Alice deposits 10,000 USDC
        uint256 depositAmount = 10000 * USDC_UNIT;
        fundAndDeposit(alice, depositAmount);

        // Alice opens a small position with minimal margin
        uint128 positionSize = 1 ether; // 1 ETH

        vm.startPrank(alice);
        uint256 minMargin = 100 * USDC_UNIT;
        clearingHouse.addMargin(ETH_PERP, minMargin);
        clearingHouse.openPosition(ETH_PERP, true, positionSize, 0);
        vm.stopPrank();

        IClearingHouse.PositionView memory posBefore = clearingHouse.getPosition(alice, ETH_PERP);
        uint256 marginBefore = posBefore.margin;
        uint256 totalCollateralBefore = vault.getAccountCollateralValueX18(alice);
        uint256 reservedBefore = clearingHouse._totalReservedMargin(alice);
        uint256 freeCollateralBefore = totalCollateralBefore - reservedBefore;

        console.log("=== Before Price Drop ===");
        console.log("Total collateral:", totalCollateralBefore);
        console.log("Position margin:", marginBefore);
        console.log("Free collateral:", freeCollateralBefore);

        // Price drops 50% - Alice has massive unrealized loss
        setOraclePrice(1000 * 1e18); // $2000 -> $1000

        // Bob trades to move mark price down
        fundAndDeposit(bob, 100000 * USDC_UNIT);
        vm.startPrank(bob);
        clearingHouse.addMargin(ETH_PERP, 50000 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, false, 100 ether, 0);
        vm.stopPrank();

        // Alice closes her position at a massive loss
        // Loss = 1 ETH * ($2000 - $1000) = ~$1000 loss
        // But her margin is only ~$100-200
        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, positionSize, 0);

        IClearingHouse.PositionView memory posAfter = clearingHouse.getPosition(alice, ETH_PERP);
        uint256 totalCollateralAfter = vault.getAccountCollateralValueX18(alice);
        uint256 reservedAfter = clearingHouse._totalReservedMargin(alice);

        console.log("");
        console.log("=== After Closing at Loss ===");
        console.log("Total collateral after:", totalCollateralAfter);
        console.log("Reserved margin after:", reservedAfter);
        console.log("Realized PnL:");
        console.logInt(posAfter.realizedPnL);

        // The bug: if loss > margin, the excess is forgiven
        // Alice should have lost more from her collateral
        int256 realizedLoss = posAfter.realizedPnL;
        uint256 actualCollateralLost = totalCollateralBefore - totalCollateralAfter;

        console.log("");
        console.log("=== Analysis ===");
        console.log("Collateral lost:", actualCollateralLost);

        if (realizedLoss < 0) {
            uint256 absLoss = uint256(-realizedLoss);
            console.log("Absolute realized loss:", absLoss);

            if (absLoss > actualCollateralLost + marginBefore) {
                uint256 forgiven = absLoss - actualCollateralLost - marginBefore;
                console.log("!!! BUG: Loss forgiven amount:", forgiven);
                console.log("Free collateral was NOT used to cover the loss!");
            }
        }
    }

    // ============================================================
    // HIGH #2: IMR Uses Manipulable Mark Price
    // Location: ClearingHouse.sol:791-795
    // ============================================================

    /// @notice Demonstrates mark price manipulation to open under-collateralized positions
    function test_HIGH_IMRUsesManipulableMarkPrice() public {
        uint256 attackerDeposit = 500 * USDC_UNIT; // Only $500
        fundAndDeposit(attacker, attackerDeposit);

        // Bob manipulates mark price down
        fundAndDeposit(bob, 1000000 * USDC_UNIT);
        vm.startPrank(bob);
        clearingHouse.addMargin(ETH_PERP, 500000 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, false, 200 ether, 0);
        vm.stopPrank();

        uint256 markPriceAfterManipulation = vamm.getMarkPrice();
        uint256 oraclePrice = oracle.getPrice();

        console.log("=== Price Manipulation ===");
        console.log("Oracle price:", oraclePrice);
        console.log("Mark price after manipulation:", markPriceAfterManipulation);
        console.log("Mark is", (oraclePrice - markPriceAfterManipulation) * 100 / oraclePrice, "% below oracle");

        // Attacker tries to open position at manipulated price
        uint128 positionSize = 5 ether;

        vm.startPrank(attacker);
        clearingHouse.addMargin(ETH_PERP, attackerDeposit);

        bool success;
        try clearingHouse.openPosition(ETH_PERP, true, positionSize, 0) {
            success = true;
        } catch {
            success = false;
        }
        vm.stopPrank();

        console.log("");
        console.log("=== Result ===");
        console.log("Position opened:", success);

        if (success) {
            IClearingHouse.PositionView memory pos = clearingHouse.getPosition(attacker, ETH_PERP);
            uint256 notionalAtOracle = uint256(pos.size > 0 ? pos.size : -pos.size) * oraclePrice / 1e18;
            uint256 shouldNeedMargin = notionalAtOracle * IMR_BPS / 10000;

            console.log("Position size:", uint256(pos.size));
            console.log("Notional at ORACLE price:", notionalAtOracle);
            console.log("Should need margin (at oracle):", shouldNeedMargin);
            console.log("Actual margin:", pos.margin);

            if (pos.margin < shouldNeedMargin) {
                console.log("");
                console.log("!!! BUG: Under-collateralized by:", shouldNeedMargin - pos.margin);
                console.log("IMR was calculated using manipulated MARK price, not ORACLE price!");
            }
        }
    }

    // ============================================================
    // MEDIUM #1: Liquidation Penalty Uses Mark Price
    // Location: ClearingHouse.sol:477-481
    // ============================================================

    /// @notice Demonstrates liquidation penalty reduction via mark manipulation
    function test_MEDIUM_LiquidationPenaltyManipulation() public {
        // Setup: Alice opens a leveraged position
        fundAndDeposit(alice, 1000 * USDC_UNIT);

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 500 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, true, 5 ether, 0);
        vm.stopPrank();

        // Price drops, making Alice liquidatable
        setOraclePrice(1500 * 1e18);

        bool canLiquidate = clearingHouse.isLiquidatable(alice, ETH_PERP);
        console.log("Alice liquidatable:", canLiquidate);

        if (!canLiquidate) {
            console.log("Need to adjust test - Alice not liquidatable");
            return;
        }

        // Liquidator manipulates mark price DOWN before liquidating
        fundAndDeposit(liquidator, 1000000 * USDC_UNIT);

        vm.startPrank(liquidator);
        clearingHouse.addMargin(ETH_PERP, 500000 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, false, 200 ether, 0);
        vm.stopPrank();

        uint256 markPriceManipulated = vamm.getMarkPrice();
        uint256 oraclePriceCurrent = oracle.getPrice();

        console.log("");
        console.log("=== Liquidation Penalty Manipulation ===");
        console.log("Oracle price:", oraclePriceCurrent);
        console.log("Mark price (manipulated):", markPriceManipulated);

        uint256 penaltyAtOracle = 5 ether * oraclePriceCurrent / 1e18 * LIQUIDATION_PENALTY_BPS / 10000;
        uint256 penaltyAtMark = 5 ether * markPriceManipulated / 1e18 * LIQUIDATION_PENALTY_BPS / 10000;

        console.log("Penalty at oracle price:", penaltyAtOracle);
        console.log("Penalty at manipulated mark:", penaltyAtMark);

        if (penaltyAtOracle > penaltyAtMark) {
            console.log("!!! BUG: Liquidator saves:", penaltyAtOracle - penaltyAtMark);
        }

        // Execute liquidation
        IClearingHouse.PositionView memory posBefore = clearingHouse.getPosition(alice, ETH_PERP);
        uint128 sizeToLiquidate = uint128(uint256(posBefore.size > 0 ? posBefore.size : -posBefore.size));

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, sizeToLiquidate);

        console.log("Liquidation executed using manipulated mark price for penalty calculation");
    }

    // ============================================================
    // MEDIUM #2: Funding Bad Debt Not Collected
    // Location: ClearingHouse.sol:659-668
    // ============================================================

    /// @notice Demonstrates funding debits being forgiven instead of collected
    function test_MEDIUM_FundingBadDebtNotCollected() public {
        fundAndDeposit(alice, 10000 * USDC_UNIT);

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 100 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, true, 1 ether, 0);
        vm.stopPrank();

        uint256 freeCollateralBefore = vault.getAccountCollateralValueX18(alice) - clearingHouse._totalReservedMargin(alice);
        uint256 marginBefore = clearingHouse.getPosition(alice, ETH_PERP).margin;

        console.log("=== Before Funding ===");
        console.log("Free collateral:", freeCollateralBefore);
        console.log("Position margin:", marginBefore);

        // Create funding imbalance
        fundAndDeposit(bob, 100000 * USDC_UNIT);
        vm.startPrank(bob);
        clearingHouse.addMargin(ETH_PERP, 50000 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, false, 50 ether, 0);
        vm.stopPrank();

        fundAndDeposit(attacker, 100000 * USDC_UNIT);
        vm.startPrank(attacker);
        clearingHouse.addMargin(ETH_PERP, 50000 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, true, 30 ether, 0);
        vm.stopPrank();

        skipTime(24 * 3600);

        clearingHouse.settleFunding(ETH_PERP, alice);

        IClearingHouse.PositionView memory posAfter = clearingHouse.getPosition(alice, ETH_PERP);
        uint256 freeCollateralAfter = vault.getAccountCollateralValueX18(alice) - clearingHouse._totalReservedMargin(alice);

        console.log("");
        console.log("=== After Funding Settlement ===");
        console.log("Position margin:", posAfter.margin);
        console.log("Free collateral:", freeCollateralAfter);

        console.log("");
        console.log("=== Analysis ===");
        if (freeCollateralAfter >= freeCollateralBefore * 99 / 100) {
            console.log("Free collateral barely changed despite potential funding debt");
            console.log("If margin went to zero, excess debt was forgiven!");
        }
    }

    // ============================================================
    // MEDIUM #3: vAMM Fee Underflow in Initialize
    // Location: vAMM.sol:98-126
    // ============================================================

    /// @notice Demonstrates that vAMM can be initialized with invalid fee
    function test_MEDIUM_vAMMFeeUnderflow() public {
        vAMM vammImpl = new vAMM();

        uint16 invalidFeeBps = 20000; // 200% fee

        bytes memory vammInitData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(oracle),
            INITIAL_ETH_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY_INDEX,
            invalidFeeBps,
            FUNDING_MAX_BPS_PER_HOUR,
            FUNDING_K,
            OBSERVATION_WINDOW
        );

        bool initSuccess;
        vAMM badVamm;

        vm.prank(admin);
        try new ERC1967Proxy(address(vammImpl), vammInitData) returns (ERC1967Proxy proxy) {
            badVamm = vAMM(address(proxy));
            initSuccess = true;
        } catch {
            initSuccess = false;
        }

        console.log("=== vAMM Fee Validation Test ===");
        console.log("Attempted fee BPS:", invalidFeeBps);
        console.log("Initialize succeeded:", initSuccess);

        if (initSuccess) {
            console.log("Actual fee BPS set:", badVamm.feeBps());
            console.log("");
            console.log("!!! BUG: initialize() accepted invalid fee !!!");

            // Verify setParams would reject it
            vm.prank(admin);
            vm.expectRevert("Fee too high");
            badVamm.setParams(invalidFeeBps, FUNDING_MAX_BPS_PER_HOUR, FUNDING_K, OBSERVATION_WINDOW);
            console.log("setParams() correctly rejects the same fee value");
        } else {
            console.log("GOOD: initialize() rejected invalid fee");
        }
    }

    // ============================================================
    // MEDIUM #4: Oracle Sanity Checks Missing
    // Location: vAMM.sol:403-436
    // ============================================================

    /// @notice Demonstrates funding breaks with zero oracle price
    function test_MEDIUM_FundingWithZeroOraclePrice() public {
        ZeroOracle zeroOracle = new ZeroOracle();

        vAMM vammImpl = new vAMM();
        bytes memory vammInitData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(zeroOracle),
            INITIAL_ETH_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY_INDEX,
            TRADE_FEE_BPS,
            FUNDING_MAX_BPS_PER_HOUR,
            FUNDING_K,
            OBSERVATION_WINDOW
        );

        vm.prank(admin);
        ERC1967Proxy zeroOracleVammProxy = new ERC1967Proxy(address(vammImpl), vammInitData);
        vAMM zeroOracleVamm = vAMM(address(zeroOracleVammProxy));

        skipTime(3600);

        uint256 twap = zeroOracleVamm.getTwap(0);
        console.log("=== Zero Oracle Price Bug ===");
        console.log("TWAP:", twap);
        console.log("Index price from oracle:", zeroOracle.getPrice());

        int256 fundingBefore = zeroOracleVamm.cumulativeFundingPerUnitX18();

        // This should handle zero gracefully but doesn't
        zeroOracleVamm.pokeFunding();

        int256 fundingAfter = zeroOracleVamm.cumulativeFundingPerUnitX18();

        console.log("Cumulative funding before:");
        console.logInt(fundingBefore);
        console.log("Cumulative funding after:");
        console.logInt(fundingAfter);

        if (fundingAfter != fundingBefore) {
            console.log("");
            console.log("!!! BUG: Funding changed with zero oracle price !!!");
            console.log("Premium = TWAP - 0 = TWAP, causing massive funding rate");
        }
    }

    /// @notice Demonstrates that reverting oracle blocks operations
    function test_MEDIUM_RevertingOracleBlocksOperations() public {
        RevertingOracle badOracle = new RevertingOracle();

        vAMM vammImpl = new vAMM();
        bytes memory vammInitData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(badOracle),
            INITIAL_ETH_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY_INDEX,
            TRADE_FEE_BPS,
            FUNDING_MAX_BPS_PER_HOUR,
            FUNDING_K,
            OBSERVATION_WINDOW
        );

        vm.prank(admin);
        ERC1967Proxy badOracleVammProxy = new ERC1967Proxy(address(vammImpl), vammInitData);
        vAMM badOracleVamm = vAMM(address(badOracleVammProxy));

        skipTime(3600);

        console.log("=== Reverting Oracle Bug ===");

        bool reverted;
        try badOracleVamm.pokeFunding() {
            reverted = false;
        } catch {
            reverted = true;
        }

        console.log("pokeFunding() reverted:", reverted);

        if (reverted) {
            console.log("");
            console.log("!!! BUG: pokeFunding() reverts when oracle fails !!!");
            console.log("This blocks all trades/liquidations that call settleFunding!");
        }
    }

    // ============================================================
    // LOW: O(n) Active Market Scans
    // ============================================================

    function test_LOW_ActiveMarketLoopGas() public {
        console.log("=== O(n) Loop Gas Analysis ===");
        console.log("Current implementation loops through ALL active markets on:");
        console.log("1. withdraw() - line 188-191");
        console.log("2. openPosition() - line 358-361");
        console.log("");
        console.log("Each iteration calls isLiquidatable() which:");
        console.log("- Reads position storage");
        console.log("- Fetches oracle price");
        console.log("- Performs margin calculations");
        console.log("");
        console.log("With 50+ markets, gas cost becomes prohibitive.");
    }
}
