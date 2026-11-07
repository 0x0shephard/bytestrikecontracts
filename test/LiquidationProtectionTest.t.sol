// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @notice Liquidation price band (internal review C-1), insurance payout griefing (M-6)
///         and the Logic code check (internal review Low).
contract LiquidationProtectionTest is BaseTest {
    uint128 internal constant VICTIM_SIZE = 50 ether; // 5% of the 1,000 ETH virtual reserve
    uint128 internal constant PUSH_SIZE = 400 ether;
    uint256 internal constant VICTIM_DEPOSIT = 8_400 * 1e18;
    uint256 internal constant ATTACKER_DEPOSIT = 250_000 * 1e18;

    /// @dev Thin long that passes IMR and the post-trade MMR check.
    function _openThinLong() internal {
        fundAndDeposit(alice, VICTIM_DEPOSIT);
        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 2_600 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, true, VICTIM_SIZE, 0);
        vm.stopPrank();
    }

    /// @dev Thin short mirroring _openThinLong.
    function _openThinShort() internal {
        fundAndDeposit(alice, VICTIM_DEPOSIT);
        vm.startPrank(alice);
        clearingHouse.addMargin(ETH_PERP, 2_600 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, false, VICTIM_SIZE, 0);
        vm.stopPrank();
    }

    function _attackerPushes(bool isLong) internal {
        fundAndDeposit(bob, ATTACKER_DEPOSIT);
        vm.startPrank(bob);
        clearingHouse.addMargin(ETH_PERP, 200_000 * USDC_UNIT);
        // Buying base gets expensive fast, so the upward push is smaller.
        clearingHouse.openPosition(ETH_PERP, isLong, isLong ? 150 ether : PUSH_SIZE, 0);
        vm.stopPrank();
    }

    function _setBand(uint256 bandBps) internal {
        vm.prank(admin);
        clearingHouse.setLiquidationPriceBand(ETH_PERP, bandBps);
    }

    // --- C-1: front-run liquidation ---

    function test_FrontRunLiquidationOfLongReverts() public {
        _openThinLong();
        setOraclePrice(1_990 * PRICE_PRECISION);
        assertTrue(isLiquidatable(alice));

        _attackerPushes(false); // mark pushed far below index

        vm.prank(liquidator);
        vm.expectPartialRevert(ClearingHouse.LiquidationPriceOutOfBand.selector);
        clearingHouse.liquidate(alice, ETH_PERP, VICTIM_SIZE, 0);

        // The attacker is left holding a manipulated position and unwinds at a loss.
        vm.prank(bob);
        clearingHouse.closePosition(ETH_PERP, PUSH_SIZE, 0);
        assertLt(getCollateralBalance(bob), ATTACKER_DEPOSIT);
        assertEq(clearingHouse.totalBadDebt(), 0);

        // With the mark restored, the honest liquidation goes through.
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, VICTIM_SIZE, 0);
        assertEq(getPosition(alice).size, 0);
    }

    function test_FrontRunLiquidationOfShortReverts() public {
        _openThinShort();
        setOraclePrice(2_010 * PRICE_PRECISION);
        assertTrue(isLiquidatable(alice));

        _attackerPushes(true); // mark pushed far above index

        vm.prank(liquidator);
        vm.expectPartialRevert(ClearingHouse.LiquidationPriceOutOfBand.selector);
        clearingHouse.liquidate(alice, ETH_PERP, VICTIM_SIZE, 0);
    }

    /// @dev A fill better than the index (mark lagging a falling index) is never blocked.
    function test_FillBetterThanIndexIsAllowed() public {
        _openThinLong();
        setOraclePrice(1_600 * PRICE_PRECISION); // index -20%, mark untouched near 2,000
        assertTrue(isLiquidatable(alice));

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, VICTIM_SIZE, 0);
        assertEq(getPosition(alice).size, 0);
    }

    function test_OwnerCanWidenTheBand() public {
        _openThinLong();
        setOraclePrice(1_990 * PRICE_PRECISION);
        _attackerPushes(false);

        _setBand(10_000);
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, VICTIM_SIZE, 0);
        assertEq(getPosition(alice).size, 0);
    }

    function test_BandIsMeasuredOnTheWholeFill() public {
        _openThinLong();
        setOraclePrice(1_990 * PRICE_PRECISION);
        _attackerPushes(false);

        // Even a tiny band violation by the fill's average price is caught.
        _setBand(1);
        vm.prank(liquidator);
        vm.expectPartialRevert(ClearingHouse.LiquidationPriceOutOfBand.selector);
        clearingHouse.liquidate(alice, ETH_PERP, VICTIM_SIZE, 0);
    }

    // --- Band configuration ---

    function test_DefaultBandIsFivePercent() public view {
        assertEq(clearingHouse.DEFAULT_LIQUIDATION_PRICE_BAND_BPS(), 500);
        assertEq(clearingHouse.liquidationPriceBandBps(ETH_PERP), 500);
    }

    function test_OwnerSetsBandAndZeroRestoresDefault() public {
        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit IClearingHouse.LiquidationPriceBandSet(ETH_PERP, 300);
        _setBand(300);
        assertEq(clearingHouse.liquidationPriceBandBps(ETH_PERP), 300);

        _setBand(0);
        assertEq(clearingHouse.liquidationPriceBandBps(ETH_PERP), 500);
    }

    function test_BandSetterValidation() public {
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.NotAdmin.selector);
        clearingHouse.setLiquidationPriceBand(ETH_PERP, 300);

        vm.startPrank(admin);
        vm.expectRevert(ClearingHouse.InvalidLiquidationPriceBand.selector);
        clearingHouse.setLiquidationPriceBand(ETH_PERP, 10_001);

        vm.expectRevert();
        clearingHouse.setLiquidationPriceBand(keccak256("NO-SUCH-PERP"), 300);
        vm.stopPrank();
    }

    function test_BandStorageIsAppendedAtSlot14() public {
        _setBand(300);
        bytes32 entry = keccak256(abi.encode(ETH_PERP, uint256(14)));
        assertEq(uint256(vm.load(address(clearingHouse), entry)), 300);
    }

    // --- M-6: a reverting insurance payout does not block liquidation ---

    function test_OneWeiToInsuranceFundDoesNotBlockLiquidation() public {
        // Empty the fund's tracked balance.
        vm.startPrank(admin);
        insuranceFund.setAuthorized(admin, true);
        insuranceFund.payout(admin, insuranceFund.balance());
        vm.stopPrank();

        // Underwater long with mark following the index down.
        _openThinLong();
        setOraclePrice(1_800 * PRICE_PRECISION);
        fundAndDeposit(bob, 100_000 * USDC_UNIT);
        vm.startPrank(bob);
        clearingHouse.addMargin(ETH_PERP, 60_000 * USDC_UNIT);
        clearingHouse.openPosition(ETH_PERP, false, 104 ether, 0);
        vm.stopPrank();
        assertTrue(isLiquidatable(alice));

        // Untracked 1 wei: balance() says 1, payout() only allows the tracked 0.
        usdc.mint(address(this), 1);
        usdc.transfer(address(insuranceFund), 1);

        uint256 badDebtBefore = clearingHouse.totalBadDebt();
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, VICTIM_SIZE, 0);

        assertEq(getPosition(alice).size, 0);
        assertGt(clearingHouse.totalBadDebt(), badDebtBefore);
    }

    // --- Logic address must have code ---

    function test_ConstructorRejectsLogicWithoutCode() public {
        vm.expectRevert(ClearingHouse.InvalidLogic.selector);
        new ClearingHouse(address(0xBEEF));

        vm.expectRevert(ClearingHouse.InvalidLogic.selector);
        new ClearingHouse(address(0));
    }
}
