// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression for finding 61 (mitigation review): when the account's balance is below its
/// reserved margin, a funding debit pays only the paying margin's backed share (margin * V / R plus
/// free collateral) and cuts paid * R / V of nominal margin, so the other positions keep their backing.
contract AuditFixesPart2Review61Test is BaseTest {
    bytes32 internal constant MARKET_B = keccak256("B-PERP");
    bytes32 internal constant MARKET_C = keccak256("C-PERP");
    uint256 internal constant INDEX_A = 2_300e18;

    MockOracle internal oracleB;
    MockOracle internal oracleC;
    address internal keeper;

    function setUp() public override {
        super.setUp();
        keeper = makeAddr("keeper");
        oracleB = _addMarket(MARKET_B);
        oracleC = _addMarket(MARKET_C);

        setOraclePrice(INDEX_A);
        clearingHouse.settleFunding(ETH_PERP, keeper);

        fundAndDeposit(alice, 20_000e18);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 100e18, 0);
        clearingHouse.openPosition(MARKET_B, true, 10e18, 0);
        clearingHouse.openPosition(MARKET_C, true, 10e18, 0);
        vm.stopPrank();

        fundAndDeposit(bob, 50_000e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 1e18, 0);

        uint256 free = getCollateralBalance(alice) - clearingHouse._totalReservedMargin(alice);
        vm.prank(alice);
        clearingHouse.withdraw(address(usdc), free);
    }

    function _addMarket(bytes32 marketId) internal returns (MockOracle o) {
        vm.startPrank(admin);
        o = new MockOracle(2_000e18, 18);
        bytes memory init = abi.encodeCall(
            vAMM.initialize,
            (address(clearingHouse), address(o), 2_000e18, INITIAL_BASE_RESERVE, LIQUIDITY_INDEX, 0, 100, 1e18)
        );
        vAMM v = vAMM(address(new ERC1967Proxy(address(new vAMM()), init)));
        v.setRegistry(address(marketRegistry));
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: marketId,
                vamm: address(v),
                oracle: address(o),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: TRADE_FEE_BPS,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
        clearingHouse.setRiskParams(marketId, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, PENALTY_CAP, 0, 0);
        vm.stopPrank();
    }

    function _reserved() internal view returns (uint256) {
        return clearingHouse._totalReservedMargin(alice);
    }

    function test_FundingCapRespectsAccountShortfall() public {
        // C is liquidated past its margin, leaving the balance below the reserved margin
        oracleC.setPrice(1_800e18);
        vm.prank(bob);
        clearingHouse.openPosition(MARKET_C, false, 61e18, 0);
        assertTrue(clearingHouse.isLiquidatable(alice, MARKET_C), "C not liquidatable");
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, MARKET_C, 10e18, 0);
        assertEq(clearingHouse.getPosition(alice, MARKET_C).size, 0, "C not closed");

        uint256 balance = getCollateralBalance(alice);
        uint256 reserved = _reserved();
        assertLt(balance, reserved, "balance still covers reserved margin");
        uint256 marginA = clearingHouse.getPosition(alice, ETH_PERP).margin;
        uint256 marginB = clearingHouse.getPosition(alice, MARKET_B).margin;
        uint256 backedB = (marginB * balance) / reserved;
        uint256 backedA = (marginA * balance) / reserved;
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B liquidatable before A's funding");

        // 20 hours of funding accrue on the A long, more than its margin
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 i = 1; i <= 20; i++) {
            vm.warp(t0 + i * 1 hours);
            clearingHouse.settleFunding(ETH_PERP, keeper);
        }
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B liquidatable before the settlement");
        // the liquidation view's replay already sees the A long's debt
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP), "A not liquidatable");

        // A's settlement pays only A's backed share and carries the rest as debt
        clearingHouse.settleFunding(ETH_PERP, alice);
        uint256 paid = balance - getCollateralBalance(alice);
        assertEq(clearingHouse.getPosition(alice, ETH_PERP).margin, 0, "A margin left");
        assertGt(clearingHouse.getPosition(alice, ETH_PERP).fundingDebt, 0, "A carries no debt");
        assertLe(paid, backedA + 1, "A paid more than its backed share");
        assertApproxEqAbs(paid, backedA, 1e6, "A did not pay its backed share");

        // B keeps its nominal margin and its backing, and stays healthy
        assertEq(clearingHouse.getPosition(alice, MARKET_B).margin, marginB, "B margin changed");
        uint256 backedBAfter = (marginB * getCollateralBalance(alice)) / _reserved();
        assertGe(backedBAfter + 1, backedB, "B backing reduced");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B liquidatable");
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP), "A not liquidatable");
    }
}
