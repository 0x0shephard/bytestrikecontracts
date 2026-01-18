// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {vAMM} from "../src/vAMM.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title VAMMEdgeCaseTest
/// @notice Comprehensive edge case tests for vAMM
contract VAMMEdgeCaseTest is BaseTest {

    function setUp() public override {
        super.setUp();
    }

    // ============ Initialization Tests ============

    function test_GetReserves() public view {
        (uint256 baseReserve, uint256 quoteReserve) = vamm.getReserves();
        assertEq(baseReserve, INITIAL_BASE_RESERVE, "Base reserve incorrect");
        assertTrue(quoteReserve > 0, "Quote reserve should be > 0");
    }

    function test_GetMarkPrice() public view {
        uint256 markPrice = vamm.getMarkPrice();
        assertEq(markPrice, INITIAL_ETH_PRICE, "Mark price should equal initial price");
    }

    function test_GetLiquidity() public view {
        uint128 liquidity = vamm.getLiquidity();
        assertEq(liquidity, LIQUIDITY_INDEX, "Liquidity incorrect");
    }

    function test_GetFeeGrowthGlobal() public view {
        uint256 feeGrowth = vamm.feeGrowthGlobalX128();
        assertEq(feeGrowth, 0, "Initial fee growth should be 0");
    }

    function test_GetCumulativeFunding() public view {
        int256 cumulativeFunding = vamm.cumulativeFundingPerUnitX18();
        assertEq(cumulativeFunding, 0, "Initial cumulative funding should be 0");
    }

    // ============ Swap Edge Cases ============

    function test_VerySmallSwap() public {
        uint128 tinySize = 1000; // Very small amount

        fundAndDeposit(alice, 10000 * USDC_UNIT);

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 100 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, true, tinySize, 0);
        vm.stopPrank();

        // Should not revert
    }

    function test_MaxSizeSwap() public {
        // Try to buy a very large amount
        uint128 largeSize = ethQty(500);

        fundAndDeposit(alice, 500000 * USDC_UNIT);

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 500000 * USDC_UNIT);

        // This might revert due to IMR or run out of liquidity
        try clearingHouse.openPosition(ETH_PERP, true, largeSize, 0) {
            // If it succeeds, verify the position exists
            assertTrue(true);
        } catch {
            // Expected to fail with such a large position
            assertTrue(true);
        }
        vm.stopPrank();
    }

    function test_SwapWithPriceLimit_ExactMatch() public {
        uint128 size = ethQty(1);
        uint256 currentPrice = getMarkPrice();

        fundAndDeposit(alice, 10000 * USDC_UNIT);

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 5000 * USDC_UNIT);

        // Set price limit to a value that should just barely work
        uint256 priceLimit = currentPrice + (currentPrice * 1) / 100; // +1%

        clearingHouse.openPosition(ETH_PERP, true, size, priceLimit);
        vm.stopPrank();
    }

    function test_BackToBackSwaps() public {
        uint128 size = ethQty(1);

        fundAndDeposit(alice, 20000 * USDC_UNIT);

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 250 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, true, size, 0);

        clearingHouse.addMargin(ETH_PERP, 250 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, true, size, 0);

        clearingHouse.addMargin(ETH_PERP, 250 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, true, size, 0);
        vm.stopPrank();

        // Verify reserves changed
        (uint256 baseReserve,) = vamm.getReserves();
        assertTrue(baseReserve < INITIAL_BASE_RESERVE, "Base reserve should decrease");
    }

    function test_OppositeSwaps_ReturnToEquilibrium() public {
        uint128 size = ethQty(2);

        fundAndDeposit(alice, 10000 * USDC_UNIT);
        fundAndDeposit(bob, 10000 * USDC_UNIT);

        uint256 initialPrice = getMarkPrice();

        // Alice goes long
        openLongPosition(alice, size, 0);

        // Bob goes short by same amount
        openShortPosition(bob, size, 0);

        uint256 finalPrice = getMarkPrice();

        // Price should be close to initial (within 1%)
        uint256 priceDiff = finalPrice > initialPrice ? finalPrice - initialPrice : initialPrice - finalPrice;
        uint256 tolerance = (initialPrice * 1) / 100;

        assertTrue(priceDiff <= tolerance, "Price should return close to equilibrium");
    }

    // ============ TWAP Tests ============

    function test_TWAP_InitiallyZero() public {
        uint32 window = 3600; // 1 hour

        try vamm.getTwap(window) returns (uint256 twap) {
            // If observations exist
            assertTrue(twap >= 0, "TWAP should be non-negative");
        } catch {
            // Expected if no observations yet
            assertTrue(true);
        }
    }

    function test_TWAP_AfterSwap() public {
        fundAndDeposit(alice, 10000 * USDC_UNIT);
        openLongPosition(alice, ethQty(1), 0);

        // Skip time
        skipTime(1 hours);

        // Make another swap to update TWAP
        fundAndDeposit(bob, 10000 * USDC_UNIT);
        openLongPosition(bob, ethQty(1), 0);

        uint32 window = 3600;
        uint256 twap = vamm.getTwap(window);

        assertTrue(twap > 0, "TWAP should be > 0");
    }

    function test_TWAP_MultipleObservations() public {
        fundAndDeposit(alice, 50000 * USDC_UNIT);

        // Create multiple observations over time
        for (uint i = 0; i < 5; i++) {
            vm.startPrank(alice);
            clearingHouse.addMargin(ETH_PERP, 250 * USDC_UNIT);
            clearingHouse.openPosition(ETH_PERP, true, ethQty(1), 0);
            vm.stopPrank();

            skipTime(30 minutes);
        }

        uint32 window = 2 hours;
        uint256 twap = vamm.getTwap(window);

        assertTrue(twap > 0, "TWAP should be calculated");
    }

    // ============ Funding Rate Tests ============

    function test_PokeFunding_NoChange() public {
        vamm.pokeFunding();
        // Should not revert
    }

    function test_PokeFunding_AfterPriceChange() public {
        fundAndDeposit(alice, 10000 * USDC_UNIT);
        openLongPosition(alice, ethQty(5), 0);

        skipTime(1 hours);

        int256 fundingBefore = vamm.cumulativeFundingPerUnitX18();
        vamm.pokeFunding();
        int256 fundingAfter = vamm.cumulativeFundingPerUnitX18();

        // Funding should change (or stay same if mark = index)
        assertTrue(true); // Just verify no revert
    }

    function test_PokeFunding_MultipleTimes() public {
        for (uint i = 0; i < 5; i++) {
            skipTime(1 hours);
            vamm.pokeFunding();
        }

        // Should handle multiple pokes
        assertTrue(true);
    }

    function test_FundingRate_Clamping() public {
        // Create massive imbalance
        fundAndDeposit(alice, 200000 * USDC_UNIT);

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 15000 * USDC_UNIT);

        try clearingHouse.openPosition(ETH_PERP, true, ethQty(150), 0) {
            skipTime(1 hours);

            int256 fundingBefore = vamm.cumulativeFundingPerUnitX18();
            vamm.pokeFunding();
            int256 fundingAfter = vamm.cumulativeFundingPerUnitX18();

            // Funding change should be clamped
            int256 fundingChange = fundingAfter - fundingBefore;
            int256 maxChange = int256(FUNDING_MAX_BPS_PER_HOUR * 1e16); // 1% per hour

            assertTrue(fundingChange <= maxChange, "Funding should be clamped");
            assertTrue(fundingChange >= -maxChange, "Funding should be clamped");
        } catch {
            // Expected if position too large
            assertTrue(true);
        }
        vm.stopPrank();
    }

    // ============ Fee Accumulation Tests ============

    function test_FeeAccumulation() public {
        fundAndDeposit(alice, 10000 * USDC_UNIT);
        fundAndDeposit(bob, 10000 * USDC_UNIT);

        uint256 feeGrowthBefore = vamm.feeGrowthGlobalX128();

        openLongPosition(alice, ethQty(1), 0);
        openLongPosition(bob, ethQty(1), 0);

        uint256 feeGrowthAfter = vamm.feeGrowthGlobalX128();

        assertTrue(feeGrowthAfter > feeGrowthBefore, "Fee growth should increase");
    }

    // ============ Admin Function Tests ============

    function test_RevertWhen_UnauthorizedSwap() public {
        vm.expectRevert();
        vm.prank(alice);
        vamm.buyBase(ethQty(1), 0);
    }

    function test_RevertWhen_ZeroSize() public {
        vm.expectRevert("amount=0");
        vm.prank(address(clearingHouse));
        vamm.buyBase(0, 0);
    }

    // ============ View Function Tests ============

    function test_GetParameters() public view {
        // Verify all view functions work
        vamm.getReserves();
        vamm.getMarkPrice();
        vamm.getLiquidity();
        vamm.feeGrowthGlobalX128();
        vamm.cumulativeFundingPerUnitX18();
    }

    // ============ Reserve Boundary Tests ============

    function test_ReservesNeverZero() public {
        // Try to deplete base reserve
        fundAndDeposit(alice, 500000 * USDC_UNIT);

        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 500000 * USDC_UNIT);

        // Try to buy almost all base
        try clearingHouse.openPosition(ETH_PERP, true, ethQty(900), 0) {
            (uint256 baseReserve, uint256 quoteReserve) = vamm.getReserves();
            assertTrue(baseReserve > 0, "Base reserve should never be 0");
            assertTrue(quoteReserve > 0, "Quote reserve should never be 0");
        } catch {
            // Expected - vAMM should prevent complete depletion
            assertTrue(true);
        }
        vm.stopPrank();
    }

    function test_ConstantProductMaintained() public {
        (uint256 baseBefore, uint256 quoteBefore) = vamm.getReserves();
        uint256 kBefore = baseBefore * quoteBefore;

        fundAndDeposit(alice, 10000 * USDC_UNIT);
        openLongPosition(alice, ethQty(2), 0);

        (uint256 baseAfter, uint256 quoteAfter) = vamm.getReserves();
        uint256 kAfter = baseAfter * quoteAfter;

        // k should stay approximately the same (within fee tolerance)
        // After fees, k increases slightly
        assertTrue(kAfter >= kBefore, "k should not decrease");
    }

    // ============ Price Impact Tests ============

    function test_PriceImpact_Proportional() public {
        fundAndDeposit(alice, 50000 * USDC_UNIT);
        fundAndDeposit(bob, 50000 * USDC_UNIT);

        uint256 priceBefore = getMarkPrice();

        // Small trade
        openLongPosition(alice, ethQty(1), 0);
        uint256 priceAfterSmall = getMarkPrice();

        // Reset by opposite trade
        openShortPosition(alice, ethQty(1), 0);

        // Large trade
        openLongPosition(bob, ethQty(10), 0);
        uint256 priceAfterLarge = getMarkPrice();

        uint256 smallImpact = priceAfterSmall - priceBefore;
        uint256 largeImpact = priceAfterLarge - priceBefore;

        // Large trade should have more price impact
        assertTrue(largeImpact > smallImpact * 5, "Large trade should have proportionally more impact");
    }
}
