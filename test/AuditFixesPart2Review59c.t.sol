// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression for finding 59 (third mitigation review): the guard over the account's other
/// positions on the same quote token skips a market whose index cannot be read (addMargin and
/// closePosition) and, for closePosition, a liquidatable position on a paused market, which no keeper
/// can liquidate either. While closePosition skips one, its fill must stay inside the liquidation price
/// band around the index, so a pushed mark cannot move collateral out through the close.
contract AuditFixesPart2Review59cTest is BaseTest {
    // what a CuOracleAdapter past its maxAge reverts with
    bytes4 internal constant PRICE_STALE = bytes4(keccak256("CuOracleAdapter_PriceStale()"));
    bytes32 internal constant MARKET_B = keccak256("B-PERP");
    vAMM internal vammB;
    MockOracle internal oracleB;

    function setUp() public override {
        super.setUp();
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

        // alice holds a healthy 10 ETH long and a 10 ETH long on B, with free collateral next to them
        fundAndDeposit(alice, 2_600e18);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        clearingHouse.openPosition(MARKET_B, true, 10e18, 0);
        vm.stopPrank();
        fundAndDeposit(bob, 100_000e18);
    }

    function _staleB() internal {
        vm.mockCallRevert(address(oracleB), abi.encodeWithSignature("getPrice()"), abi.encodeWithSelector(PRICE_STALE));
    }

    function test_StaleSiblingIndexDoesNotBlockAddMargin() public {
        _staleB();
        uint256 marginBefore = getMargin(alice);
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 100e18);
        assertEq(getMargin(alice), marginBefore + 100e18, "margin not added");
    }

    function test_StaleSiblingIndexDoesNotBlockFairClose() public {
        _staleB();
        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, 5e18, 0);
        assertEq(getPosition(alice).size, int256(5e18), "not closed");
    }

    function test_StaleSiblingIndexHoldsCloseInsideBand() public {
        _staleB();
        // bob pushes ETH's mark about 4% under the index, which a long's close would sell into
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 30e18, 0);
        assertLt(getMarkPrice(), INITIAL_ETH_PRICE * 99 / 100, "mark not pushed");

        vm.prank(alice);
        vm.expectPartialRevert(ClearingHouse.LiquidationPriceOutOfBand.selector);
        clearingHouse.closePosition(ETH_PERP, 5e18, 0);

        // with every index readable, nothing is skipped and the close is not banded
        vm.clearMockedCalls();
        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, 5e18, 0);
        assertEq(getPosition(alice).size, int256(5e18), "not closed");
    }

    function test_LiquidatableSiblingOnPausedMarketDoesNotBlockFairClose() public {
        // B's index falls 5%: B is liquidatable, then its market is paused, so no keeper can act on it
        oracleB.setPrice(INITIAL_ETH_PRICE * 95 / 100);
        assertTrue(clearingHouse.isLiquidatable(alice, MARKET_B), "B not liquidatable");
        vm.prank(admin);
        marketRegistry.pauseMarket(MARKET_B, true);

        // the healthy ETH long can still be closed at a fair price
        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, 5e18, 0);
        assertEq(getPosition(alice).size, int256(5e18), "not closed");

        // but not into a pushed mark
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 30e18, 0);
        vm.prank(alice);
        vm.expectPartialRevert(ClearingHouse.LiquidationPriceOutOfBand.selector);
        clearingHouse.closePosition(ETH_PERP, 5e18, 0);
    }

    function test_LiquidatableSiblingOnActiveMarketStillBlocksClose() public {
        oracleB.setPrice(INITIAL_ETH_PRICE * 95 / 100);
        assertTrue(clearingHouse.isLiquidatable(alice, MARKET_B), "B not liquidatable");
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.HasLiquidatablePosition.selector);
        clearingHouse.closePosition(ETH_PERP, 5e18, 0);
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.HasLiquidatablePosition.selector);
        clearingHouse.addMargin(ETH_PERP, 100e18);
    }
}
