// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Finding 10: funding the vault balance cannot pay is carried as position debt instead of
/// being written off, counts against equity, and makes the position liquidatable.
contract AuditFixesPart2FundingDebtTest is BaseTest {
    uint256 internal constant INDEX_PRICE = 2_350e18;
    uint128 internal constant LONG_SIZE = 100e18;
    bytes32 internal constant MARKET_B = keccak256("B-PERP");

    vAMM internal vammB;
    address internal carol;
    uint256 internal _now;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
        setOraclePrice(INDEX_PRICE);
        _now = block.timestamp;
    }

    function _trackedInsurance() internal view returns (uint256) {
        return insuranceFund.totalReceived() - insuranceFund.totalPaid();
    }

    function _poke(vAMM v) internal {
        vm.prank(address(clearingHouse));
        v.pokeFunding();
    }

    /// @dev Alice holds a long that is in profit at the index but pays funding (mark above index),
    /// with only its margin left in the vault.
    function _openProfitablePayingLong() internal {
        _poke(vamm);
        fundAndDeposit(alice, 30_000e18);
        openLongPosition(alice, LONG_SIZE, 0);
        fundAndDeposit(bob, 10_000e18);
        openShortPosition(bob, ethQty(1), 0);

        uint256 free = getCollateralBalance(alice) - getMargin(alice);
        vm.prank(alice);
        clearingHouse.withdraw(address(usdc), free);
        assertEq(getCollateralBalance(alice), getMargin(alice), "only margin left");
    }

    /// @dev Margin + pending funding + unrealized PnL at the index, before this fix's debt check.
    function _effectiveAndMaintenance() internal view returns (int256 effectiveMargin, uint256 maintenance) {
        IClearingHouse.PositionView memory p = getPosition(alice);
        uint256 notional = (uint256(p.size) * INDEX_PRICE) / 1e18;
        maintenance = (notional * MMR_BPS) / 10_000;
        int256 upnl = (int256(INDEX_PRICE) - int256(p.entryPriceX18)) * p.size / 1e18;
        uint256 pending = ((vamm.currentCumulativeLongPayPerUnitX18() - p.lastFundingPayIndex) * uint256(p.size)) / 1e18;
        effectiveMargin = int256(p.margin) + upnl - int256(pending) - int256(p.fundingDebt);
    }

    function _accrueHours(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _now += 1 hours;
            vm.warp(_now);
            _poke(vamm);
            if (address(vammB) != address(0)) _poke(vammB);
        }
    }

    function test_Finding10_unpaidFundingCarriedAsDebtAndLiquidatable() public {
        _openProfitablePayingLong();
        _accrueHours(55);

        // The pending debit exceeds the balance, but the position still covers maintenance margin
        // on its unrealized profit alone.
        (int256 effectiveMargin, uint256 maintenance) = _effectiveAndMaintenance();
        assertGt(effectiveMargin, int256(maintenance), "test setup: position below maintenance");
        // The view already sees the debt settlement would carry.
        assertTrue(isLiquidatable(alice), "view misses unsettled funding debt");

        uint256 insuranceBefore = _trackedInsurance();
        settleFunding(alice);

        IClearingHouse.PositionView memory p = getPosition(alice);
        assertGt(p.fundingDebt, 0, "unpaid funding not carried");
        assertEq(getCollateralBalance(alice), 0, "balance not used first");
        assertEq(clearingHouse.totalBadDebt(), 0, "funding written off as bad debt");
        assertEq(_trackedInsurance(), insuranceBefore, "insurance paid funding at settlement");
        assertTrue(isLiquidatable(alice), "position with funding debt not liquidatable");

        // The owner cannot strip what is left, and a keeper can liquidate. The fill is capped by the
        // liquidation fill bound (findings 1 + 4); the profit it realizes pays the debt, after which
        // the remainder is healthy and stays open.
        uint256 calls = liquidateFully(alice, ETH_PERP, bob);
        assertGt(calls, 0);
        p = getPosition(alice);
        assertEq(p.fundingDebt, 0, "debt not settled on close");
        assertTrue(p.size == 0 || !isLiquidatable(alice), "remainder left liquidatable");
    }

    function test_Finding10_depositPaysCarriedDebt() public {
        _openProfitablePayingLong();
        _accrueHours(55);
        settleFunding(alice);
        uint256 debt = getPosition(alice).fundingDebt;
        assertGt(debt, 0, "no debt");

        // Anyone settling after a deposit collects the debt from the new balance.
        fundAndDeposit(alice, 10_000e18);
        uint256 margin = getMargin(alice);
        settleFunding(alice);
        assertEq(getPosition(alice).fundingDebt, 0, "debt not paid from deposit");
        assertEq(getCollateralBalance(alice), 10_000e18 - debt, "debt not debited");
        assertEq(getMargin(alice), margin, "paid debt moved margin twice");
        assertEq(clearingHouse.totalBadDebt(), 0, "bad debt booked");
    }

    function test_Finding10_voluntaryCloseBlockedWhileDebtUnpaid() public {
        _openProfitablePayingLong();
        _accrueHours(55);
        settleFunding(alice);
        assertGt(getPosition(alice).fundingDebt, 0, "no debt");

        // A voluntary close is blocked while the debt cannot be paid.
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.PositionLiquidatable.selector);
        clearingHouse.closePosition(ETH_PERP, LONG_SIZE, 0);
    }

    // ---------------------------------------------------------------------
    // Debt in one market, credit in another: settlement order must not matter
    // ---------------------------------------------------------------------

    function _addMarketB() internal {
        vm.startPrank(admin);
        vAMM impl = new vAMM();
        bytes memory initData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(oracle),
            1_900e18,
            INITIAL_BASE_RESERVE,
            LIQUIDITY_INDEX,
            VAMM_FEE_BPS,
            FUNDING_MAX_BPS_PER_HOUR,
            FUNDING_K
        );
        vammB = vAMM(address(new ERC1967Proxy(address(impl), initData)));
        vammB.setRegistry(address(marketRegistry));
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: MARKET_B,
                vamm: address(vammB),
                oracle: address(oracle),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: TRADE_FEE_BPS,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
        clearingHouse.setRiskParams(
            MARKET_B, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, PENALTY_CAP, MAX_POSITION_SIZE, MIN_POSITION_SIZE
        );
        vm.stopPrank();
    }

    function _open(address user, bytes32 marketId, bool isLong, uint128 size, uint256 margin) internal {
        openWithMargin(user, marketId, isLong, size, 0, margin);
    }

    function _owedInA() internal view returns (uint256) {
        IClearingHouse.PositionView memory pos = clearingHouse.getPosition(alice, ETH_PERP);
        return ((vamm.cumulativeLongPayPerUnitX18() - pos.lastFundingPayIndex) * uint256(pos.size)) / 1e18;
    }

    function _creditInB() internal view returns (uint256) {
        IClearingHouse.PositionView memory pos = clearingHouse.getPosition(alice, MARKET_B);
        return ((vammB.cumulativeLongReceivePerUnitX18() - pos.lastFundingReceiveIndex) * uint256(pos.size)) / 1e18;
    }

    function test_Finding10_creditInOtherMarketPaysDebitWhateverTheOrder() public {
        _addMarketB();
        _poke(vamm);
        _poke(vammB);
        fundAndDeposit(alice, 28_000e18);
        _open(alice, ETH_PERP, true, LONG_SIZE, 1_000e18);
        _open(alice, MARKET_B, true, LONG_SIZE, 1_000e18);
        fundAndDeposit(bob, 3_000e18);
        fundAndDeposit(carol, 100_000e18);
        _open(bob, ETH_PERP, false, 1e18, 1_000e18);
        _open(carol, MARKET_B, false, LONG_SIZE, 60_000e18);

        _accrueHours(72);
        uint256 owed = _owedInA();
        uint256 credit = _creditInB();
        uint256 bal = getCollateralBalance(alice);
        assertGt(owed, bal, "debit does not exceed the balance");
        assertGt(bal + credit, owed, "credit does not cover the gap");

        uint256 insuranceBefore = _trackedInsurance();
        // Settling the paying market first must not write off what the credit covers.
        clearingHouse.settleFunding(ETH_PERP, alice);
        clearingHouse.settleFunding(MARKET_B, alice);

        assertEq(clearingHouse.totalBadDebt(), 0, "bad debt booked");
        assertEq(_trackedInsurance(), insuranceBefore, "insurance drawn");
        assertEq(clearingHouse.getPosition(alice, ETH_PERP).fundingDebt, 0, "debt left after credit");
        assertEq(getCollateralBalance(alice), bal + credit - owed, "final balance");
    }
}
