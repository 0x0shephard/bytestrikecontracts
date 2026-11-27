// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression for finding 49 (mitigation review): a funding credit the vault values at zero
/// after the haircut backs no margin instead of reverting, so it cannot block liquidations.
contract AuditFixesPart2Review49Test is BaseTest {
    bytes32 internal constant MARKET_B = keccak256("B-PERP");
    uint128 internal constant LONG_SIZE = 10e18;
    uint128 internal constant DAVE_SHORT = 10e18;

    address internal dave;
    vAMM internal vammB;

    function setUp() public override {
        super.setUp();
        dave = makeAddr("dave");

        vm.startPrank(admin);
        MockOracle oracleB = new MockOracle(2_000e18, 18);
        bytes memory init = abi.encodeCall(
            vAMM.initialize,
            (address(clearingHouse), address(oracleB), 1_900e18, INITIAL_BASE_RESERVE, LIQUIDITY_INDEX, 0, 100, 1e18)
        );
        vammB = vAMM(address(new ERC1967Proxy(address(new vAMM()), init)));
        vammB.setRegistry(address(marketRegistry));
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: MARKET_B,
                vamm: address(vammB),
                oracle: address(oracleB),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: TRADE_FEE_BPS,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
        clearingHouse.setRiskParams(MARKET_B, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, PENALTY_CAP, 0, 0);
        vm.stopPrank();
    }

    function _setQuoteHaircut(uint16 haircutBps) internal {
        vm.startPrank(admin);
        ICollateralVault.CollateralConfig memory cfg = vault.getConfig(address(usdc));
        cfg.haircutBps = haircutBps;
        vault.setCollateralParams(address(usdc), cfg);
        vm.stopPrank();
    }

    function test_DustFundingCreditDoesNotBlockLiquidation() public {
        fundAndDeposit(alice, 5_000e18);
        fundAndDeposit(dave, 50_000e18);

        openLongPosition(alice, LONG_SIZE, 0);

        vm.prank(alice);
        clearingHouse.openPosition(MARKET_B, true, 1, 0);
        openWithMargin(dave, MARKET_B, false, DAVE_SHORT, 0, 2_000e18);

        uint256 lastIdx = clearingHouse.getPosition(alice, MARKET_B).lastFundingReceiveIndex;
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 100);
        uint256 per100s = vammB.currentCumulativeLongReceivePerUnitX18() - lastIdx;
        vm.warp(t0 + (15e17 * 100) / per100s);
        vm.prank(dave);
        clearingHouse.closePosition(MARKET_B, DAVE_SHORT, 0);

        assertEq(vammB.totalShortOI(), 0, "B still has shorts");
        uint256 perUnit = vammB.cumulativeLongReceivePerUnitX18() - lastIdx;
        assertGe(perUnit, 1e18, "credit below 1 wei");
        assertLt(perUnit, 2e18, "credit above 1 wei");

        _setQuoteHaircut(100);
        setOraclePrice(1_700e18);
        assertTrue(isLiquidatable(alice), "long not liquidatable");

        // the 1-unit credit settles: its token is credited but it backs no margin
        uint256 marginB = clearingHouse.getPosition(alice, MARKET_B).margin;
        uint256 balBefore = getCollateralBalance(alice);
        clearingHouse.settleFunding(MARKET_B, alice);
        assertEq(
            clearingHouse.getPosition(alice, MARKET_B).lastFundingReceiveIndex,
            vammB.cumulativeLongReceivePerUnitX18(),
            "credit not settled"
        );
        assertEq(getCollateralBalance(alice), balBefore + 1, "credit not paid");
        assertEq(clearingHouse.getPosition(alice, MARKET_B).margin, marginB, "dust credit backed margin");

        // and the underwater ETH long can be liquidated
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, LONG_SIZE, 0);
        assertLt(getPosition(alice).size, int256(uint256(LONG_SIZE)), "long not liquidated");
    }

    function test_DustCreditPendingDoesNotBlockLiquidation() public {
        fundAndDeposit(alice, 5_000e18);
        fundAndDeposit(dave, 50_000e18);
        openLongPosition(alice, LONG_SIZE, 0);
        vm.prank(alice);
        clearingHouse.openPosition(MARKET_B, true, 1, 0);
        openWithMargin(dave, MARKET_B, false, DAVE_SHORT, 0, 2_000e18);

        uint256 lastIdx = clearingHouse.getPosition(alice, MARKET_B).lastFundingReceiveIndex;
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 100);
        uint256 per100s = vammB.currentCumulativeLongReceivePerUnitX18() - lastIdx;
        vm.warp(t0 + (15e17 * 100) / per100s);
        vm.prank(dave);
        clearingHouse.closePosition(MARKET_B, DAVE_SHORT, 0);

        _setQuoteHaircut(100);
        setOraclePrice(1_700e18);
        // the ETH long now owes funding, so the liquidation check replays the account's pending
        // funding, including the dust credit, which must not revert
        vm.warp(vm.getBlockTimestamp() + 600);
        setOraclePrice(1_700e18);
        assertTrue(isLiquidatable(alice), "long not liquidatable");
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, LONG_SIZE, 0);
        assertLt(getPosition(alice).size, int256(uint256(LONG_SIZE)), "long not liquidated");
    }
}
