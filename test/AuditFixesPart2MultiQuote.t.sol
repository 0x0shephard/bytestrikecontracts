// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockERC20} from "../script/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IVAMM} from "../src/Interfaces/IVAMM.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression tests for markets with different quote tokens (Cyfrin bytestrike part 2).
contract AuditFixesPart2MultiQuoteTest is BaseTest {
    bytes32 internal constant USDT_PERP = keccak256("ETH-USDT-PERP");
    bytes32 internal constant ETH2_PERP = keccak256("ETH2-PERP");

    MockERC20 internal usdt;
    vAMM internal usdtVamm;
    vAMM internal ethVamm2;

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        usdt = new MockERC20("Tether USD", "USDT", 18);
        oracle.setSymbolPrice("USDT", 1e18);
        vault.registerCollateral(
            ICollateralVault.CollateralConfig({
                token: address(usdt),
                baseUnit: 1e18,
                haircutBps: 0,
                liqIncentiveBps: uint16(LIQUIDATION_PENALTY_BPS),
                cap: type(uint256).max,
                accountCap: type(uint256).max,
                enabled: true,
                depositPaused: false,
                withdrawPaused: false,
                oracleSymbol: "USDT"
            })
        );

        // Market on a different quote token (USDT) with its own fee router and insurance fund.
        InsuranceFund usdtFund = new InsuranceFund(address(usdt), address(clearingHouse));
        FeeRouter usdtRouter = new FeeRouter(
            address(usdt), address(usdtFund), treasury, address(clearingHouse), FEE_TO_INSURANCE_BPS, FEE_TO_INSURANCE_BPS
        );
        usdtFund.setFeeRouter(address(usdtRouter), true);
        usdtFund.setAuthorized(address(clearingHouse), true);
        usdtVamm = _deployMarket(USDT_PERP, address(usdt), address(usdtRouter), address(usdtFund));

        // Second market on the same quote token (USDC) as ETH_PERP.
        ethVamm2 = _deployMarket(ETH2_PERP, address(usdc), address(feeRouter), address(insuranceFund));
        vm.stopPrank();
    }

    function _deployMarket(bytes32 marketId, address quote, address router, address fund) internal returns (vAMM v) {
        vAMM impl = new vAMM();
        bytes memory initData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(oracle),
            INITIAL_ETH_PRICE,
            INITIAL_BASE_RESERVE,
            LIQUIDITY_INDEX,
            TRADE_FEE_BPS,
            FUNDING_MAX_BPS_PER_HOUR,
            FUNDING_K
        );
        v = vAMM(address(new ERC1967Proxy(address(impl), initData)));
        v.setRegistry(address(marketRegistry));
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: marketId,
                vamm: address(v),
                oracle: address(oracle),
                baseAsset: address(weth),
                quoteToken: quote,
                baseUnit: 1e18,
                feeBps: TRADE_FEE_BPS,
                feeRouter: router,
                insuranceFund: fund
            })
        );
        clearingHouse.setRiskParams(
            marketId, IMR_BPS, MMR_BPS, LIQUIDATION_PENALTY_BPS, PENALTY_CAP, MAX_POSITION_SIZE, MIN_POSITION_SIZE
        );
    }

    /// @dev Alice holds a USDC-quoted ETH_PERP long, a USDC-quoted ETH2_PERP long and a
    ///      USDT-quoted long. Bob takes the other side so funding indices are live.
    function _openPositions(uint128 ethSize) internal {
        fundAndDeposit(alice, 10_000e18);
        usdt.mint(alice, 10_000e18);
        vm.startPrank(alice);
        usdt.approve(address(vault), 10_000e18);
        clearingHouse.deposit(address(usdt), 10_000e18);
        clearingHouse.openPosition(ETH_PERP, true, ethSize, 0);
        clearingHouse.openPosition(ETH2_PERP, true, 1e18, 0);
        clearingHouse.openPosition(USDT_PERP, true, 1e18, 0);
        vm.stopPrank();

        fundAndDeposit(bob, 100_000e18);
        usdt.mint(bob, 10_000e18);
        vm.startPrank(bob);
        usdt.approve(address(vault), 10_000e18);
        clearingHouse.deposit(address(usdt), 10_000e18);
        clearingHouse.openPosition(ETH2_PERP, false, 1e18, 0);
        clearingHouse.openPosition(USDT_PERP, false, 1e18, 0);
        vm.stopPrank();
    }

    function _breakUsdtMarketFunding() internal {
        vm.mockCallRevert(address(usdtVamm), abi.encodeWithSelector(IVAMM.pokeFunding.selector), "down");
        vm.mockCallRevert(address(usdtVamm), abi.encodeWithSelector(IVAMM.skipFunding.selector), "down");
    }

    /// @notice Finding 47: closing a USDC-quoted position settles funding only in USDC-quoted
    /// markets, so a failing USDT-quoted market cannot block it.
    function test_Finding47_closeNotBlockedByOtherQuoteMarket() public {
        _openPositions(1e18);
        uint256 ts = block.timestamp + 1 hours;
        vm.warp(ts);
        uint64 usdtTsBefore = usdtVamm.lastFundingTimestamp();
        _breakUsdtMarketFunding();

        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, 1e18, 0);
        assertEq(getPosition(alice).size, 0, "ETH_PERP not closed");

        // Same-quote market was settled; other-quote market was not touched.
        assertEq(ethVamm2.lastFundingTimestamp(), ts, "same-quote market not settled");
        assertEq(usdtVamm.lastFundingTimestamp(), usdtTsBefore, "other-quote market touched");
    }

    /// @notice Finding 47: liquidating a USDC-quoted position is not blocked by a failing
    /// USDT-quoted market held by the same account.
    function test_Finding47_liquidateNotBlockedByOtherQuoteMarket() public {
        _openPositions(10e18);
        uint256 ts = block.timestamp + 1 hours;
        vm.warp(ts);
        setOraclePrice(1850e18);
        assertTrue(isLiquidatable(alice), "alice should be liquidatable");
        _breakUsdtMarketFunding();

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
        assertEq(getPosition(alice).size, 0, "ETH_PERP not liquidated");
        assertEq(ethVamm2.lastFundingTimestamp(), ts, "same-quote market not settled");
    }
}
