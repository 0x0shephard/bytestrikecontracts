// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression tests for InsuranceFund usage audit fixes (Cyfrin bytestrike part 2).
contract AuditFixesPart2InsuranceTest is BaseTest {
    bytes32 internal constant ETH2_PERP = keccak256("ETH2-PERP");
    bytes32 internal constant FUNDING_SETTLED = keccak256("FundingSettled(bytes32,address,int256)");

    address internal carol;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
    }

    function _trackedInsurance() internal view returns (uint256) {
        return insuranceFund.totalReceived() - insuranceFund.totalPaid();
    }

    /// @dev Pays the fund's tracked balance down to `remaining`.
    function _drainInsuranceTo(uint256 remaining) internal {
        uint256 tracked = _trackedInsurance();
        vm.prank(address(clearingHouse));
        insuranceFund.payout(treasury, tracked - remaining);
    }

    /// @dev Second USDC market with its own index oracle (stays at 2,000).
    function _deploySecondMarket() internal {
        vm.startPrank(admin);
        MockOracle index2 = new MockOracle(INITIAL_ETH_PRICE, 18);
        bytes memory init = abi.encodeCall(
            vAMM.initialize,
            (
                address(clearingHouse),
                address(index2),
                INITIAL_ETH_PRICE,
                INITIAL_BASE_RESERVE,
                LIQUIDITY_INDEX,
                TRADE_FEE_BPS,
                FUNDING_MAX_BPS_PER_HOUR,
                FUNDING_K
            )
        );
        vAMM v = vAMM(address(new ERC1967Proxy(address(new vAMM()), init)));
        v.setRegistry(address(marketRegistry));
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: ETH2_PERP,
                vamm: address(v),
                oracle: address(index2),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: TRADE_FEE_BPS,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
        clearingHouse.setRiskParams(
            ETH2_PERP, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, PENALTY_CAP, MAX_POSITION_SIZE, MIN_POSITION_SIZE
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Finding 19
    // ------------------------------------------------------------------

    /// @notice Finding 19: a direct transfer to the fund must not void the insurance payout
    /// for a liquidator-incentive shortfall larger than the tracked reserve.
    /// @dev Alice's realized loss is covered by her vault balance, but the margin of her second
    /// position keeps that balance reserved, so the liquidator incentive falls to the fund.
    function test_Finding19_directTransferDoesNotVoidLiquidationPayout() public {
        _deploySecondMarket();
        fundAndDeposit(alice, 2_000 * USDC_UNIT);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 9e18, 0);
        clearingHouse.openPosition(ETH2_PERP, true, 10e18, 0);
        // Reserve all remaining free collateral on the second position.
        clearingHouse.addMargin(ETH2_PERP, getCollateralBalance(alice) - clearingHouse._totalReservedMargin(alice));
        vm.stopPrank();

        fundAndDeposit(bob, 100_000 * USDC_UNIT);
        setOraclePrice(1_800e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 22e18, 0);
        setOraclePrice(getMarkPrice());
        assertTrue(isLiquidatable(alice), "alice should be liquidatable");
        // The second market's index falls too, so its position holds no margin above maintenance
        // that the liquidation could draw (finding 12) and the incentive still falls to the fund.
        MockOracle(marketRegistry.getMarket(ETH2_PERP).oracle).setPrice(1_900e18);

        uint256 tracked = 10 * USDC_UNIT;
        _drainInsuranceTo(tracked);
        usdc.mint(address(insuranceFund), 1); // untracked dust via plain transfer
        uint256 keeperWalletBefore = usdc.balanceOf(liquidator);
        uint256 vaultTokensBefore = usdc.balanceOf(address(vault));

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 9e18, 0);

        assertGt(getCollateralBalance(alice), 0, "realized loss covered by alice's balance");
        assertEq(_trackedInsurance(), 0, "fund paid its whole tracked balance");
        // Collected incentive is credited in the vault; the insurance part goes to the keeper's wallet.
        assertEq(usdc.balanceOf(liquidator) - keeperWalletBefore, tracked, "keeper received the tracked reserve");
        assertLe(usdc.balanceOf(address(vault)), vaultTokensBefore, "no insurance draw into the vault");
    }

    /// @notice Finding 19: owner can book quote tokens sent by plain transfer into the tracked balance.
    function test_Finding19_syncBooksUntrackedBalance() public {
        uint256 trackedBefore = _trackedInsurance();
        usdc.mint(address(insuranceFund), 500 * USDC_UNIT);
        assertEq(_trackedInsurance(), trackedBefore, "plain transfer is untracked");

        vm.prank(admin);
        uint256 booked = insuranceFund.sync();

        assertEq(booked, 500 * USDC_UNIT, "booked surplus");
        assertEq(_trackedInsurance(), trackedBefore + 500 * USDC_UNIT, "tracked balance includes surplus");
        assertEq(_trackedInsurance(), insuranceFund.balance(), "tracked equals token balance");

        // Payout of the full balance now succeeds.
        uint256 fullBalance = insuranceFund.balance();
        vm.prank(address(clearingHouse));
        insuranceFund.payout(treasury, fullBalance);
    }

    function test_Finding19_syncOnlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        insuranceFund.sync();
    }

    // ------------------------------------------------------------------
    // Finding 1
    // ------------------------------------------------------------------

    uint128 internal constant ALICE_SIZE = 30e18;
    uint128 internal constant BOB_SIZE = 84e18;
    uint256 internal constant CAROL_DEPOSIT = 10_000e18;

    /// @dev Alice's 30 ETH long, liquidated after a 10% index gap, realizes a loss above her balance.
    function _setUpUnderwaterLong() internal {
        fundAndDeposit(carol, CAROL_DEPOSIT); // never trades

        fundAndDeposit(alice, 4_300e18);
        openWithMargin(alice, ETH_PERP, true, ALICE_SIZE, 0, 1_000e18);

        setOraclePrice(1_800e18);
        fundAndDeposit(bob, 100_000e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, BOB_SIZE, 0);
        assertTrue(isLiquidatable(alice), "alice should be liquidatable");
    }

    function _sumBalances() internal view returns (uint256) {
        return getCollateralBalance(alice) + getCollateralBalance(bob) + getCollateralBalance(carol)
            + getCollateralBalance(liquidator);
    }

    /// @notice Finding 1: a liquidation loss beyond the trader's balance is paid by the insurance
    /// fund into the vault, so the winners' credits stay backed and the last depositor can withdraw.
    function test_Finding1_liquidationShortfallPaidIntoVault() public {
        _setUpUnderwaterLong();
        assertEq(usdc.balanceOf(address(vault)), _sumBalances(), "vault starts fully backed");
        uint256 trackedBefore = _trackedInsurance();
        uint256 vaultTokensBefore = usdc.balanceOf(address(vault));

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, ALICE_SIZE, 0);
        assertEq(getCollateralBalance(alice), 0, "alice's balance is used up");

        uint256 drawn = usdc.balanceOf(address(vault)) - vaultTokensBefore;
        assertGt(drawn, 0, "fund paid the shortfall into the vault");
        assertLe(drawn, trackedBefore - _trackedInsurance(), "draw is booked as a fund payout");
        // The fund paid the loss and the keeper incentive; only the uncollected protocol share of
        // the penalty (half of 2% of 30 * 1,800) is recorded, with no fake insurance netting.
        assertEq(clearingHouse.totalBadDebt(), 540e18, "only the protocol penalty share is recorded");

        vm.prank(bob);
        clearingHouse.closePosition(ETH_PERP, BOB_SIZE, 0);
        assertGe(usdc.balanceOf(address(vault)), _sumBalances(), "balances backed by vault tokens");

        uint256 bobBalance = getCollateralBalance(bob);
        vm.prank(bob);
        clearingHouse.withdraw(address(usdc), bobBalance);
        vm.prank(carol);
        clearingHouse.withdraw(address(usdc), CAROL_DEPOSIT);
        assertEq(usdc.balanceOf(carol), CAROL_DEPOSIT, "last depositor withdraws in full");
    }

    /// @notice Finding 1: the draw is capped at the fund's tracked balance and only the rest is
    /// recorded as bad debt.
    function test_Finding1_drawCappedAtTrackedBalance() public {
        _setUpUnderwaterLong();
        uint256 tracked = 5 * USDC_UNIT;
        _drainInsuranceTo(tracked);
        usdc.mint(address(insuranceFund), 1); // untracked dust must not void the draw
        uint256 vaultTokensBefore = usdc.balanceOf(address(vault));

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, ALICE_SIZE, 0);

        assertEq(usdc.balanceOf(address(vault)) - vaultTokensBefore, tracked, "whole tracked balance drawn");
        assertEq(_trackedInsurance(), 0, "fund emptied");
        assertGt(clearingHouse.totalBadDebt(), 0, "rest recorded as bad debt");
    }

    /// @notice Finding 1: a funding debit beyond the payer's vault balance is covered by the fund.
    /// @dev Since finding 10 the shortfall is first carried as funding debt on the position, and the
    /// fund pays it into the vault when the position is liquidated.
    function test_Finding1_fundingDebitBeyondBalancePaidIntoVault() public {
        fundAndDeposit(alice, 1_100e18);
        fundAndDeposit(carol, 100_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, false, 1e18, 0);

        uint256 t = block.timestamp;
        for (uint256 i; i < 40; i++) {
            t += 3600;
            vm.warp(t);
            setOraclePrice(1_900e18); // index below mark: longs pay
            settleFunding(carol);
        }

        uint256 aliceBalance = getCollateralBalance(alice);
        uint256 vaultTokensBefore = usdc.balanceOf(address(vault));
        uint256 badDebtBefore = clearingHouse.totalBadDebt();
        vm.recordLogs();
        settleFunding(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        int256 payment;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(clearingHouse) && logs[i].topics[0] == FUNDING_SETTLED) {
                payment = abi.decode(logs[i].data, (int256));
            }
        }
        uint256 debit = uint256(-payment);
        assertGt(debit, aliceBalance, "debit exceeds alice's balance");

        assertEq(getCollateralBalance(alice), 0, "balance used up");
        uint256 debt = clearingHouse.getPosition(alice, ETH_PERP).fundingDebt;
        assertEq(debt, debit - aliceBalance, "rest carried as funding debt");
        assertEq(usdc.balanceOf(address(vault)), vaultTokensBefore, "fund drawn before the position closes");

        // Liquidation settles the debt; the fund pays what the account cannot into the vault.
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
        assertEq(clearingHouse.getPosition(alice, ETH_PERP).fundingDebt, 0, "debt not settled");
        assertGe(usdc.balanceOf(address(vault)) - vaultTokensBefore, debt, "fund covers the debt");
        // Only the protocol's uncollected penalty share (1% of 10 ETH at the 1,900 index) is recorded.
        assertEq(clearingHouse.totalBadDebt() - badDebtBefore, 190e18, "funding written off while the fund can pay");
    }
}
