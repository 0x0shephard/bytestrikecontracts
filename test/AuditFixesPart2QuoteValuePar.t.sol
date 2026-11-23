// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";

/// @notice Finding 7 follow-up (Cyfrin bytestrike part 2): losses are debited at par (one token per
///         1e18), so the clearing house never values a quote token above par.
contract AuditFixesPart2QuoteValueParTest is BaseTest {
    uint256 internal constant HAIRCUT_BPS = 100; // planned USDC haircut
    uint256 internal constant USDC_PRICE = 1.06e18; // above 1 / 0.99 = 1.0101
    uint128 internal constant SIZE = 5e18;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        // planned H100 risk parameters: IMR 10%, MMR 5%, penalty 2%
        clearingHouse.setRiskParams(ETH_PERP, 1_000, 500, 200, PENALTY_CAP, 0, 0);
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.haircutBps = uint16(HAIRCUT_BPS);
        vault.setCollateralParams(address(usdc), cfg);
        oracle.setSymbolPrice("USDC", USDC_PRICE);
        vm.stopPrank();
    }

    function _trackedInsurance() internal view returns (uint256) {
        return insuranceFund.totalReceived() - insuranceFund.totalPaid();
    }

    /// @dev Adds as much margin as addMargin accepts.
    function _addAllMargin(address user) internal {
        uint256 bal = getCollateralBalance(user);
        uint256 reserved = clearingHouse._totalReservedMargin(user);
        uint256 atOracle = vault.getTokenValueX18(address(usdc), bal) - reserved;
        vm.prank(user);
        try clearingHouse.addMargin(ETH_PERP, atOracle) {}
        catch {
            vm.prank(user);
            clearingHouse.addMargin(ETH_PERP, (bal * (10_000 - HAIRCUT_BPS)) / 10_000 - reserved);
        }
    }

    /// @dev A long holding all its collateral as margin, with its entry far above the index, is
    ///      liquidated at the maintenance threshold with a fill close to the liquidation fill bound. Valued above par, the tokens backed
    ///      more margin than they could pay at the par rate losses are debited at, so the realized
    ///      loss went beyond the balance and the insurance fund paid it. Valued at most at par, the
    ///      balance covers the loss and the penalty.
    function test_QuoteTokenAboveParDoesNotBackExtraMargin() public {
        fundAndDeposit(alice, 3_600e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, SIZE, 0);
        _addAllMargin(alice);
        IClearingHouse.PositionView memory p = getPosition(alice);

        // index just under the maintenance edge: margin + (idx - entry) * size = 5% * idx * size
        uint256 s = uint256(p.size);
        uint256 edge = ((p.entryPriceX18 * s / 1e18 - p.margin) * 1e18 / s) * 10_000 / 9_500;
        uint256 index = edge - edge / 100_000;
        setOraclePrice(index);
        assertTrue(isLiquidatable(alice));

        // bob moves the mark to 2.5% under the index (inside the 3% band)
        fundAndDeposit(bob, 200_000e18);
        (uint256 x, uint256 y) = getReserves();
        uint256 xTarget = _sqrtBase((x * y / (index * 9_750 / 10_000)) * 1e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, uint128(xTarget - x), 0);

        uint256 trackedBefore = _trackedInsurance();
        uint256 badDebtBefore = clearingHouse.totalBadDebt();
        uint256 vaultTokensBefore = usdc.balanceOf(address(vault));
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, SIZE, 0);
        assertEq(getPosition(alice).size, 0, "closed in one call");

        // No insurance tokens were drawn into the vault and nothing was written off.
        emit log_named_int("fund change", int256(_trackedInsurance()) - int256(trackedBefore));
        emit log_named_uint("alice balance left", getCollateralBalance(alice));
        assertGe(_trackedInsurance(), trackedBefore, "insurance fund paid the loss");
        assertLe(usdc.balanceOf(address(vault)), vaultTokensBefore, "insurance draw into the vault");
        assertEq(clearingHouse.totalBadDebt(), badDebtBefore, "bad debt recorded");
    }

    /// @dev The quote token is valued at most at par after the haircut, and at the oracle price
    ///      below par.
    function test_QuoteValueCappedAtParBeforeHaircut() public {
        fundAndDeposit(alice, 1_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 1e18, 0);

        // above par: each token left after the fee backs at most 0.99 of margin
        uint256 parValue = (getCollateralBalance(alice) * (10_000 - HAIRCUT_BPS)) / 10_000;
        uint256 free = parValue - clearingHouse._totalReservedMargin(alice);
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, free);
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.InsufficientQuoteBalance.selector);
        clearingHouse.addMargin(ETH_PERP, 1e18);

        // below par the oracle price still applies
        oracle.setSymbolPrice("USDC", 0.98e18);
        vm.prank(alice);
        vm.expectRevert();
        clearingHouse.addMargin(ETH_PERP, 1e18);
    }
}
