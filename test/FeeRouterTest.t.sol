// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";

/// @title FeeRouterTest
/// @notice Comprehensive tests for FeeRouter
contract FeeRouterTest is BaseTest {

    function setUp() public override {
        super.setUp();
    }

    // ============ Fee Routing Tests ============

    function test_OnTradeFee_RouteToInsuranceAndTreasury() public {
        uint256 tradeFee = 1000 * USDC_UNIT;

        uint256 feeRouterBefore = usdc.balanceOf(address(feeRouter));
        uint256 insuranceBefore = usdc.balanceOf(address(insuranceFund));

        // Fund the fee router
        usdc.mint(address(feeRouter), tradeFee);

        vm.prank(address(clearingHouse));
        feeRouter.onTradeFee(tradeFee);

        uint256 feeRouterAfter = usdc.balanceOf(address(feeRouter));
        uint256 insuranceAfter = usdc.balanceOf(address(insuranceFund));

        // With 50% to insurance (FEE_TO_INSURANCE_BPS = 5000)
        uint256 expectedToInsurance = (tradeFee * FEE_TO_INSURANCE_BPS) / 10000;
        uint256 expectedRemaining = tradeFee - expectedToInsurance;

        assertEq(insuranceAfter - insuranceBefore, expectedToInsurance, "Insurance amount incorrect");
        assertEq(feeRouterAfter - feeRouterBefore, expectedRemaining, "Fee router remainder incorrect");
    }

    function test_OnTradeFee_ZeroAmount() public {
        vm.expectRevert("FR: amount=0");
        vm.prank(address(clearingHouse));
        feeRouter.onTradeFee(0);
    }

    function test_RevertWhen_OnTradeFee_NotClearinghouse() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.onTradeFee(1000 * USDC_UNIT);
    }

    function test_OnLiquidationPenalty_RouteToInsuranceAndTreasury() public {
        uint256 penalty = 500 * USDC_UNIT;

        uint256 feeRouterBefore = usdc.balanceOf(address(feeRouter));
        uint256 insuranceBefore = usdc.balanceOf(address(insuranceFund));

        // Fund the fee router
        usdc.mint(address(feeRouter), penalty);

        vm.prank(address(clearingHouse));
        feeRouter.onLiquidationPenalty(penalty);

        uint256 feeRouterAfter = usdc.balanceOf(address(feeRouter));
        uint256 insuranceAfter = usdc.balanceOf(address(insuranceFund));

        // With 50% to insurance
        uint256 expectedToInsurance = (penalty * FEE_TO_INSURANCE_BPS) / 10000;
        uint256 expectedRemaining = penalty - expectedToInsurance;

        assertEq(insuranceAfter - insuranceBefore, expectedToInsurance, "Insurance amount incorrect");
        assertEq(feeRouterAfter - feeRouterBefore, expectedRemaining, "Fee router remainder incorrect");
    }

    function test_OnLiquidationPenalty_ZeroAmount() public {
        vm.expectRevert("FR: amount=0");
        vm.prank(address(clearingHouse));
        feeRouter.onLiquidationPenalty(0);
    }

    function test_RevertWhen_OnLiquidationPenalty_NotClearinghouse() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.onLiquidationPenalty(500 * USDC_UNIT);
    }

    // ============ Admin Functions Tests ============

    function test_SetSplits() public {
        uint16 newTradeSplit = 3000; // 30%
        uint16 newLiqSplit = 7000; // 70%

        vm.prank(admin);
        feeRouter.setSplits(newTradeSplit, newLiqSplit);

        assertEq(feeRouter.tradeToFundBps(), newTradeSplit, "Trade split not updated");
        assertEq(feeRouter.liqToFundBps(), newLiqSplit, "Liq split not updated");
    }

    function test_RevertWhen_SetSplits_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.setSplits(3000, 7000);
    }

    function test_RevertWhen_SetSplits_ExceedsMax() public {
        vm.expectRevert();
        vm.prank(admin);
        feeRouter.setSplits(10001, 5000); // > 100%
    }

    function test_SetTreasuryAdmin() public {
        address newTreasuryAdmin = makeAddr("newTreasuryAdmin");

        vm.prank(admin);
        feeRouter.setTreasuryAdmin(newTreasuryAdmin);

        assertEq(feeRouter.treasuryAdmin(), newTreasuryAdmin, "Treasury admin not updated");
    }

    function test_RevertWhen_SetTreasuryAdmin_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.setTreasuryAdmin(makeAddr("newTreasuryAdmin"));
    }

    function test_RevertWhen_SetTreasuryAdmin_ZeroAddress() public {
        vm.expectRevert();
        vm.prank(admin);
        feeRouter.setTreasuryAdmin(address(0));
    }

    function test_SetInsuranceFund() public {
        address newInsuranceFund = makeAddr("newInsuranceFund");

        vm.prank(admin);
        feeRouter.setInsuranceFund(newInsuranceFund);

        assertEq(feeRouter.insuranceFund(), newInsuranceFund, "Insurance fund not updated");
    }

    function test_RevertWhen_SetInsuranceFund_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.setInsuranceFund(makeAddr("newInsuranceFund"));
    }

    function test_RevertWhen_SetInsuranceFund_ZeroAddress() public {
        vm.expectRevert();
        vm.prank(admin);
        feeRouter.setInsuranceFund(address(0));
    }

    function test_SetClearinghouse() public {
        address newClearinghouse = makeAddr("newClearinghouse");

        vm.prank(admin);
        feeRouter.setClearinghouse(newClearinghouse);

        assertEq(feeRouter.clearinghouse(), newClearinghouse, "Clearinghouse not updated");
    }

    function test_RevertWhen_SetClearinghouse_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.setClearinghouse(makeAddr("newClearinghouse"));
    }

    // ============ View Functions Tests ============

    function test_GetQuoteToken() public view {
        assertEq(feeRouter.quoteToken(), address(usdc), "Quote token incorrect");
    }

    function test_GetSplitBps() public view {
        assertEq(feeRouter.tradeToFundBps(), FEE_TO_INSURANCE_BPS, "Trade split incorrect");
        assertEq(feeRouter.liqToFundBps(), FEE_TO_INSURANCE_BPS, "Liq split incorrect");
    }

    function test_GetTreasuryAdmin() public view {
        assertEq(feeRouter.treasuryAdmin(), treasury, "Treasury admin incorrect");
    }

    function test_GetInsuranceFund() public view {
        assertEq(feeRouter.insuranceFund(), address(insuranceFund), "Insurance fund incorrect");
    }

    function test_GetClearinghouse() public view {
        assertEq(feeRouter.clearinghouse(), address(clearingHouse), "Clearinghouse incorrect");
    }

    // ============ Integration Tests ============

    function test_MultipleFees_AccumulateCorrectly() public {
        uint256 fee1 = 1000 * USDC_UNIT;
        uint256 fee2 = 500 * USDC_UNIT;
        uint256 fee3 = 750 * USDC_UNIT;

        uint256 feeRouterBefore = usdc.balanceOf(address(feeRouter));
        uint256 insuranceBefore = usdc.balanceOf(address(insuranceFund));

        usdc.mint(address(feeRouter), fee1 + fee2 + fee3);

        vm.startPrank(address(clearingHouse));
        feeRouter.onTradeFee(fee1);
        feeRouter.onTradeFee(fee2);
        feeRouter.onLiquidationPenalty(fee3);
        vm.stopPrank();

        uint256 feeRouterAfter = usdc.balanceOf(address(feeRouter));
        uint256 insuranceAfter = usdc.balanceOf(address(insuranceFund));

        uint256 totalFees = fee1 + fee2 + fee3;
        uint256 expectedToInsurance = (totalFees * FEE_TO_INSURANCE_BPS) / 10000;
        uint256 expectedRemaining = totalFees - expectedToInsurance;

        assertEq(insuranceAfter - insuranceBefore, expectedToInsurance, "Total insurance incorrect");
        assertEq(feeRouterAfter - feeRouterBefore, expectedRemaining, "Fee router remainder incorrect");
    }

    function test_DifferentSplitRatios() public {
        // Set 80% to insurance, 20% to treasury
        vm.prank(admin);
        feeRouter.setSplits(8000, 8000);

        uint256 fee = 1000 * USDC_UNIT;
        usdc.mint(address(feeRouter), fee);

        uint256 insuranceBefore = usdc.balanceOf(address(insuranceFund));

        vm.prank(address(clearingHouse));
        feeRouter.onTradeFee(fee);

        uint256 insuranceAfter = usdc.balanceOf(address(insuranceFund));

        uint256 expectedToInsurance = (fee * 8000) / 10000;

        assertEq(insuranceAfter - insuranceBefore, expectedToInsurance, "Insurance with new split incorrect");
    }

    function test_WithdrawTreasury() public {
        uint256 fee = 1000 * USDC_UNIT;
        usdc.mint(address(feeRouter), fee);

        vm.prank(address(clearingHouse));
        feeRouter.onTradeFee(fee);

        // Check treasury balance in fee router (remainder after insurance split)
        uint256 treasuryShare = fee - ((fee * FEE_TO_INSURANCE_BPS) / 10000);

        address withdrawTo = makeAddr("withdrawTo");
        uint256 withdrawAmount = treasuryShare / 2;

        vm.prank(treasury);  // treasuryAdmin can withdraw
        feeRouter.withdrawTreasury(withdrawTo, withdrawAmount);

        assertEq(usdc.balanceOf(withdrawTo), withdrawAmount, "Withdrawal failed");
    }

    function test_RevertWhen_WithdrawTreasury_NotAuthorized() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.withdrawTreasury(alice, 1000 * USDC_UNIT);
    }

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(admin);
        feeRouter.transferOwnership(newOwner);

        assertEq(feeRouter.owner(), newOwner, "Ownership not transferred");
    }

    function test_RevertWhen_TransferOwnership_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.transferOwnership(alice);
    }
}
