// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/// @notice Finding 3: a receiving side smaller than the paying side earns at most the paying rate
/// per unit; the excess payment is booked once paid and swept to the insurance fund.
contract AuditFixesPart2FundingSurplusTest is BaseTest {
    address internal carol;
    address internal dave;
    uint256 internal _now;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
        dave = makeAddr("dave");
        _now = block.timestamp;
    }

    function _trackedInsurance() internal view returns (uint256) {
        return insuranceFund.totalReceived() - insuranceFund.totalPaid();
    }

    function _accrueHours(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _now += 1 hours;
            vm.warp(_now);
            setOraclePrice(1_960e18);
            vm.prank(address(clearingHouse));
            vamm.pokeFunding();
        }
    }

    /// @dev An honest 10 ETH long pays funding (mark above index); a 0.01 ETH short and a 0.01 ETH
    /// long from two wallets form a hedged pair on the small receiving side.
    function _openHonestLongAndDustPair() internal {
        fundAndDeposit(alice, 100_000e18);
        fundAndDeposit(carol, 1_000e18);
        fundAndDeposit(dave, 1_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.prank(carol);
        clearingHouse.openPosition(ETH_PERP, false, 0.01e18, 0);
        vm.prank(dave);
        clearingHouse.openPosition(ETH_PERP, true, 0.01e18, 0);
        setOraclePrice(1_960e18);
    }

    function test_Finding3_receiverCappedAtPayingRateAndSurplusSwept() public {
        _openHonestLongAndDustPair();
        IClearingHouse.PositionView memory a0 = getPosition(alice);
        uint256 carolBal0 = getCollateralBalance(carol);
        uint256 aliceBal0 = getCollateralBalance(alice);
        uint256 daveBal0 = getCollateralBalance(dave);

        _accrueHours(5);

        // The short earns per unit exactly what a long pays per unit, not the whole payment.
        uint256 payPerUnit = vamm.cumulativeLongPayPerUnitX18() - a0.lastFundingPayIndex;
        assertGt(payPerUnit, 0, "no funding accrued");
        assertEq(vamm.cumulativeShortReceivePerUnitX18(), payPerUnit, "receiver earns more than the paying rate");

        settleFunding(alice);
        settleFunding(carol);
        settleFunding(dave);
        uint256 alicePaid = aliceBal0 - getCollateralBalance(alice);
        uint256 davePaid = daveBal0 - getCollateralBalance(dave);
        uint256 carolGot = getCollateralBalance(carol) - carolBal0;
        assertLe(carolGot, (payPerUnit * 0.01e18) / 1e18, "short credited beyond the paying rate");
        // The pair no longer nets the honest long's payment.
        assertLt(carolGot, davePaid + 1e15, "hedged pair profits");

        uint256 surplus = clearingHouse.fundingSurplus(ETH_PERP);
        assertGt(surplus, 0, "no surplus booked");
        assertLe(carolGot + surplus, alicePaid + davePaid, "booked more than payers paid");
        assertApproxEqAbs(carolGot + surplus, alicePaid + davePaid, 1e6, "payments unaccounted");

        // Anyone can move it to the insurance fund.
        uint256 trackedBefore = _trackedInsurance();
        uint256 vaultTokensBefore = usdc.balanceOf(address(vault));
        vm.prank(makeAddr("anyone"));
        clearingHouse.sweepFundingSurplus(ETH_PERP);
        assertEq(_trackedInsurance() - trackedBefore, surplus, "fund not credited");
        assertEq(vaultTokensBefore - usdc.balanceOf(address(vault)), surplus, "vault tokens not moved");
        assertEq(clearingHouse.fundingSurplus(ETH_PERP), 0, "surplus not cleared");
        assertEq(getCollateralBalance(address(clearingHouse)), 0, "sweep left a vault balance");

        vm.expectRevert(bytes4(keccak256("AmountZero()")));
        clearingHouse.sweepFundingSurplus(ETH_PERP);
    }

    function test_Finding3_unpaidSurplusNotBooked() public {
        _openHonestLongAndDustPair();
        // Alice keeps only her margin in the vault, so her funding soon exceeds her balance.
        setOraclePrice(INITIAL_ETH_PRICE);
        vm.startPrank(alice);
        clearingHouse.withdraw(address(usdc), getCollateralBalance(alice) - getMargin(alice));
        vm.stopPrank();
        uint256 aliceBal0 = getCollateralBalance(alice);

        _accrueHours(40);
        settleFunding(carol);
        settleFunding(dave);
        settleFunding(alice);
        assertGt(getPosition(alice).fundingDebt, 0, "test setup: no debt carried");

        // Only surplus alice actually paid is booked, so the sweep cannot take tokens that back
        // other accounts' balances.
        assertLe(clearingHouse.fundingSurplus(ETH_PERP), aliceBal0 + 1e18, "unpaid surplus booked");
        clearingHouse.sweepFundingSurplus(ETH_PERP);
        uint256 owed = getCollateralBalance(alice) + getCollateralBalance(carol) + getCollateralBalance(dave)
            + getCollateralBalance(liquidator) + getCollateralBalance(address(feeRouter));
        assertGe(usdc.balanceOf(address(vault)), owed, "vault insolvent after sweep");
    }

    /// @dev Tokens the vault holds beyond what its accounts and the booked surplus claim.
    function _vaultExcess() internal view returns (int256) {
        uint256 owed = getCollateralBalance(alice) + getCollateralBalance(carol) + getCollateralBalance(dave)
            + getCollateralBalance(liquidator) + getCollateralBalance(address(feeRouter))
            + getCollateralBalance(address(clearingHouse)) + clearingHouse.fundingSurplus(ETH_PERP);
        return int256(usdc.balanceOf(address(vault))) - int256(owed);
    }

    /// @dev Alice keeps only her margin in the vault and accrues funding beyond it, so part of her
    /// funding (surplus share included) is carried as debt.
    function _aliceCarriesDebt() internal returns (uint256 surplusPerUnit0) {
        _openHonestLongAndDustPair();
        surplusPerUnit0 = getPosition(alice).lastFundingSurplusIndex;
        setOraclePrice(INITIAL_ETH_PRICE);
        vm.startPrank(alice);
        clearingHouse.withdraw(address(usdc), getCollateralBalance(alice) - getMargin(alice));
        vm.stopPrank();

        _accrueHours(40);
        settleFunding(carol);
        settleFunding(dave);
        settleFunding(alice);
        assertGt(getPosition(alice).fundingDebt, 0, "test setup: no debt carried");
        assertEq(getCollateralBalance(alice), 0, "test setup: balance left");
    }

    /// @dev Finding 3 (follow-up): a settlement that could not pay in full took the whole unpaid
    /// amount off its own surplus share and nothing booked that share when the debt was paid later,
    /// so it stayed in the vault unclaimed. The unpaid surplus is now carried with the debt and
    /// booked when the debt is paid.
    function test_Finding3_carriedSurplusBookedWhenDebtPaid() public {
        uint256 surplusIdx0 = _aliceCarriesDebt();
        IClearingHouse.PositionView memory p = getPosition(alice);
        assertGt(p.fundingDebtSurplus, 0, "surplus share not carried");
        assertLe(p.fundingDebtSurplus, p.fundingDebt, "carried share exceeds the debt");

        // alice tops up and pays her debt in full
        fundAndDeposit(alice, 10_000e18);
        settleFunding(alice);
        p = getPosition(alice);
        assertEq(p.fundingDebt, 0, "debt not paid");
        assertEq(p.fundingDebtSurplus, 0, "carried share not cleared");

        // the whole surplus of the paying side (alice and dave) is booked, nothing is left unclaimed
        uint256 expected = ((vamm.cumulativeLongSurplusPerUnitX18() - surplusIdx0) * 10.01e18) / 1e18;
        assertApproxEqAbs(clearingHouse.fundingSurplus(ETH_PERP), expected, 1e6, "surplus lost");
        assertApproxEqAbs(_vaultExcess(), 0, 1e6, "paid surplus left unclaimed in the vault");
    }

    /// @dev Finding 3 (follow-up): a liquidation that wrote the debt off drew the whole unpaid debt
    /// from the insurance fund into the vault, surplus share included, where nothing claimed it. The
    /// fund now pays only the unpaid debt beyond the carried surplus share, which is dropped.
    function test_Finding3_writeOffDoesNotDrawCarriedSurplus() public {
        _aliceCarriesDebt();
        uint256 carried = getPosition(alice).fundingDebtSurplus;
        assertGt(carried, 0, "surplus share not carried");
        uint256 surplusBefore = clearingHouse.fundingSurplus(ETH_PERP);
        int256 excessBefore = _vaultExcess();

        assertTrue(isLiquidatable(alice), "test setup: not liquidatable");
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
        assertEq(getPosition(alice).size, 0, "not fully liquidated");
        assertEq(getPosition(alice).fundingDebtSurplus, 0, "carried share not dropped");

        // the dropped share is neither booked nor drawn: the vault holds no more unclaimed tokens
        assertEq(clearingHouse.fundingSurplus(ETH_PERP), surplusBefore, "unpaid surplus booked");
        assertLe(_vaultExcess(), excessBefore + 1e6, "fund drew the surplus share into the vault");
    }
}
