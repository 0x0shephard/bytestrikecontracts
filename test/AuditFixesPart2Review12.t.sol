// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression for finding 12 (mitigation review): the surplus a liquidation's penalty draws
/// from a sibling position is measured net of the sibling's pending funding debit, so a paused sibling
/// with flushed, unsettled funding is not pushed below maintenance.
contract AuditFixesPart2Review12Test is BaseTest {
    bytes32 internal constant MARKET_B = keccak256("B-PERP");
    vAMM internal vammB;
    MockOracle internal oracleB;
    address internal carol;

    uint128 internal constant SIZE_B = 10e18;
    uint256 internal constant SPARE_B = 1_000e18;
    uint256 internal constant FUNDING_HOURS = 96;
    uint256 internal constant CUSHION = 1e18;
    uint256 internal constant INDEX_A = 1_900e18;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
        vm.startPrank(admin);
        oracleB = new MockOracle(INITIAL_ETH_PRICE, 18);
        vAMM impl = new vAMM();
        bytes memory initData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(oracleB),
            INITIAL_ETH_PRICE,
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
                oracle: address(oracleB),
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

    function _freeCollateral(address user) internal view returns (uint256) {
        return getCollateralBalance(user) - clearingHouse._totalReservedMargin(user);
    }

    function test_PausedSiblingPendingFundingNotDrawnForPenalty() public {
        fundAndDeposit(alice, 10_000e18);
        vm.startPrank(alice);
        clearingHouse.openPosition(MARKET_B, false, SIZE_B, 0);
        clearingHouse.addMargin(MARKET_B, SPARE_B);
        vm.stopPrank();
        fundAndDeposit(carol, 10_000e18);
        vm.prank(carol);
        clearingHouse.openPosition(MARKET_B, true, 5e18, 0);
        assertLt(vammB.getMarkPrice(), oracleB.getPrice());

        for (uint256 i = 0; i < FUNDING_HOURS; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            clearingHouse.settleFunding(MARKET_B, carol);
        }

        // B is paused with alice's short owing more than 500 of flushed, unsettled funding
        vm.prank(admin);
        marketRegistry.pauseMarket(MARKET_B, true);
        IClearingHouse.PositionView memory pb = clearingHouse.getPosition(alice, MARKET_B);
        uint256 payDelta = vammB.currentCumulativeShortPayPerUnitX18() - pb.lastFundingPayIndex;
        uint256 receiveDelta = vammB.currentCumulativeShortReceivePerUnitX18() - pb.lastFundingReceiveIndex;
        uint256 pending = (payDelta - receiveDelta) * uint256(SIZE_B) / 1e18;
        assertGt(pending, 500e18);

        // B's index moves to where the short holds maintenance plus CUSHION once the funding is counted
        uint256 indexB =
            (pb.margin + pb.entryPriceX18 * uint256(SIZE_B) / 1e18 - pending - CUSHION) * 100 / 1_025;
        oracleB.setPrice(indexB);
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B liquidatable before");

        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        clearingHouse.withdraw(address(usdc), _freeCollateral(alice));
        vm.stopPrank();

        fundAndDeposit(bob, 100_000e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 30e18, 0);
        setOraclePrice(INDEX_A);
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP), "A not liquidatable");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B liquidatable");

        uint256 marginB = clearingHouse.getPosition(alice, MARKET_B).margin;
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);

        // B gave up at most its real surplus (CUSHION, up to the rounding of indexB above) and stays
        // above maintenance with its index unchanged
        uint256 marginBAfter = clearingHouse.getPosition(alice, MARKET_B).margin;
        assertLe(marginB - marginBAfter, CUSHION + 100, "B gave up more than its real surplus");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B pushed below maintenance");

        // once B resumes and its funding is charged, it is still not liquidatable
        vm.prank(admin);
        marketRegistry.pauseMarket(MARKET_B, false);
        clearingHouse.settleFunding(MARKET_B, alice);
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B liquidatable after settlement");
    }
}
