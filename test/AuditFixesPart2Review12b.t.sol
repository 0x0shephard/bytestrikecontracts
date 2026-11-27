// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression for finding 12 (second mitigation review): settlement books the funding a pause
/// flushed on an inactive market, credit as well as debit, so a liquidation's own settlement counts a
/// paused sibling's flushed credit before drawing surplus for the penalty. Paused time stays uncharged.
contract AuditFixesPart2Review12bTest is BaseTest {
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

    /// @dev Funding the vAMM's current indices owe alice's B short (positive: a credit).
    function _pendingCreditB() internal view returns (int256) {
        IClearingHouse.PositionView memory p = clearingHouse.getPosition(alice, MARKET_B);
        uint256 receiveDelta = vammB.currentCumulativeShortReceivePerUnitX18() - p.lastFundingReceiveIndex;
        uint256 payDelta = vammB.currentCumulativeShortPayPerUnitX18() - p.lastFundingPayIndex;
        return (int256(receiveDelta) - int256(payDelta)) * int256(uint256(SIZE_B)) / 1e18;
    }

    function test_PausedSiblingFlushedCreditBookedByLiquidation() public {
        // alice shorts 10 ETH on B; carol's larger long lifts B's mark above its index, so shorts receive
        fundAndDeposit(alice, 10_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(MARKET_B, false, SIZE_B, 0);
        fundAndDeposit(carol, 100_000e18);
        vm.prank(carol);
        clearingHouse.openPosition(MARKET_B, true, 20e18, 0);
        assertGt(vammB.getMarkPrice(), oracleB.getPrice());

        // alice opens an ETH long at the initial margin and withdraws her free collateral
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        clearingHouse.withdraw(address(usdc), _freeCollateral(alice));
        vm.stopPrank();

        // funding is poked hourly through carol, alice is never settled
        uint256 t = vm.getBlockTimestamp();
        for (uint256 i = 0; i < FUNDING_HOURS; i++) {
            t += 1 hours;
            vm.warp(t);
            clearingHouse.settleFunding(MARKET_B, carol);
        }

        // B is paused, which flushes its funding indices; alice's short holds an unsettled credit
        vm.prank(admin);
        marketRegistry.pauseMarket(MARKET_B, true);

        // the ETH index falls
        fundAndDeposit(bob, 100_000e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 30e18, 0);
        setOraclePrice(INDEX_A);
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP), "A not liquidatable");

        int256 credit = _pendingCreditB();
        assertGt(credit, 1e18, "no flushed credit");

        // the liquidation's own settlement books B's flushed credit, paused or not
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
        assertEq(_pendingCreditB(), 0, "flushed credit left unsettled");

        // paused time stays uncharged: B's funding clock does not move while paused
        uint256 payIndex = vammB.cumulativeShortReceivePerUnitX18();
        vm.warp(t + 10 hours);
        clearingHouse.settleFunding(MARKET_B, alice);
        assertEq(vammB.cumulativeShortReceivePerUnitX18(), payIndex, "paused time accrued");
    }
}
