// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression for finding 59 (mitigation review): addMargin's guard must not read the index of
/// the position being topped up when that index is down. The topped-up position then counts as not
/// liquidatable, while the other positions on the same quote token are still checked.
contract AuditFixesPart2Review59Test is BaseTest {
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
    }

    function test_AddMarginWorksDuringOwnIndexOutage() public {
        // alice holds a single 10 ETH long and free collateral to defend it
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        assertEq(clearingHouse._totalReservedMargin(alice), getMargin(alice));

        // the market's index feed goes stale; the quote-token price stays readable
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice()"), abi.encodeWithSelector(PRICE_STALE));

        // alice can still top up her only position
        uint256 marginBefore = getMargin(alice);
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 500 ether);
        assertEq(getMargin(alice), marginBefore + 500 ether);

        // the feed returns 5% lower and the topped-up long stays above maintenance
        vm.clearMockedCalls();
        setOraclePrice(INITIAL_ETH_PRICE * 95 / 100);
        assertFalse(isLiquidatable(alice));
    }

    function test_LiquidatablePositionCuredWhileOtherIndexDown() public {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        clearingHouse.openPosition(MARKET_B, true, 10 ether, 0);
        vm.stopPrank();

        // ETH's index falls 5% and B's index feed goes stale
        setOraclePrice(INITIAL_ETH_PRICE * 95 / 100);
        assertTrue(isLiquidatable(alice));
        vm.mockCallRevert(address(oracleB), abi.encodeWithSignature("getPrice()"), abi.encodeWithSelector(PRICE_STALE));

        // the liquidatable ETH position can still be cured
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 500 ether);
        vm.clearMockedCalls();
        assertFalse(isLiquidatable(alice));
    }

    function test_OwnIndexDownStillBlockedByLiquidatableSibling() public {
        fundAndDeposit(alice, 10_000 * USDC_UNIT);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        clearingHouse.openPosition(MARKET_B, true, 10 ether, 0);
        vm.stopPrank();

        // B's index falls 5% (B liquidatable) and ETH's index feed goes stale
        oracleB.setPrice(INITIAL_ETH_PRICE * 95 / 100);
        assertTrue(clearingHouse.isLiquidatable(alice, MARKET_B));
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice()"), abi.encodeWithSelector(PRICE_STALE));

        // free collateral cannot be moved onto ETH while B is liquidatable
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.HasLiquidatablePosition.selector);
        clearingHouse.addMargin(ETH_PERP, 500 ether);

        // B itself can still be cured
        vm.prank(alice);
        clearingHouse.addMargin(MARKET_B, 500 ether);
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B));
    }
}
