// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Finding 12: a liquidation collects the penalty from margin parked on the account's other
/// healthy positions above their maintenance and penalty floor before the insurance fund pays.
contract AuditFixesPart2SurplusMarginTest is BaseTest {
    bytes32 internal constant MARKET_B = keccak256("B-PERP");
    vAMM internal vammB;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        vAMM impl = new vAMM();
        bytes memory initData = abi.encodeWithSelector(
            vAMM.initialize.selector,
            address(clearingHouse),
            address(oracle),
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

    function _trackedInsurance() internal view returns (uint256) {
        return insuranceFund.totalReceived() - insuranceFund.totalPaid();
    }

    function _freeCollateral(address user) internal view returns (uint256) {
        return getCollateralBalance(user) - clearingHouse._totalReservedMargin(user);
    }

    /// @dev Alice: a long in ETH_PERP at the initial margin and a healthy short in B. With
    /// `parkSpare` her spare collateral is moved into B's margin, otherwise it is withdrawn. Bob then
    /// pushes ETH_PERP's mark down and the index follows, so the long is liquidated at a loss.
    function _setUp(uint128 sizeB, bool parkSpare) internal {
        fundAndDeposit(alice, 10_000e18);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        clearingHouse.openPosition(MARKET_B, false, sizeB, 0);
        if (parkSpare) clearingHouse.addMargin(MARKET_B, _freeCollateral(alice));
        else clearingHouse.withdraw(address(usdc), _freeCollateral(alice));
        vm.stopPrank();
        assertEq(_freeCollateral(alice), 0, "free collateral left");

        fundAndDeposit(bob, 100_000e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 25e18, 0);
        setOraclePrice(1_950e18);
        assertTrue(clearingHouse.isLiquidatable(alice, ETH_PERP), "A not liquidatable");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B liquidatable");
    }

    // 2% of 10 ETH at the 1,950 index, half to the liquidator and half to the fee router
    uint256 internal constant PENALTY = 390e18;

    function test_Finding12_penaltyDrawnFromSurplusMarginOnOtherPosition() public {
        _setUp(10e18, true);
        uint256 marginB = clearingHouse.getPosition(alice, MARKET_B).margin;
        uint256 badDebtBefore = clearingHouse.totalBadDebt();

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);

        // The account pays the whole penalty: the liquidator is paid in the vault, not by the fund.
        assertEq(vault.balanceOf(liquidator, address(usdc)), PENALTY / 2, "incentive not collected");
        assertEq(usdc.balanceOf(liquidator), 0, "insurance paid the liquidator");
        assertEq(clearingHouse.totalBadDebt(), badDebtBefore, "protocol share written off");

        // B gave up surplus margin and stays healthy.
        uint256 marginBAfter = clearingHouse.getPosition(alice, MARKET_B).margin;
        assertLt(marginBAfter, marginB, "B margin untouched");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B left liquidatable");
        assertGe(getCollateralBalance(alice), clearingHouse._totalReservedMargin(alice), "reserved margin unbacked");
    }

    function test_Finding12_drawStopsAtPenaltyFloor() public {
        _setUp(2e18, false);
        uint256 marginB = clearingHouse.getPosition(alice, MARKET_B).margin;
        // B's own penalty floor: 2% of 2 ETH at the index.
        uint256 floorB = 78e18;
        assertLt(marginB - floorB, PENALTY, "test setup: B surplus covers the whole penalty");

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);

        assertEq(clearingHouse.getPosition(alice, MARKET_B).margin, floorB, "B drawn below its penalty floor");
        assertFalse(clearingHouse.isLiquidatable(alice, MARKET_B), "B left liquidatable");
    }

    function test_Finding12_unreadableOracleSkipsMarket() public {
        _setUp(10e18, true);
        uint256 marginB = clearingHouse.getPosition(alice, MARKET_B).margin;
        // B's index reverts only inside the surplus draw (A and B share the mock oracle, so mock B's
        // registry entry to point at a reverting oracle).
        address badOracle = makeAddr("badOracle");
        vm.etch(badOracle, hex"60006000fd"); // revert(0, 0)
        IMarketRegistry.Market memory mb = marketRegistry.getMarket(MARKET_B);
        mb.oracle = badOracle;
        vm.mockCall(
            address(marketRegistry), abi.encodeCall(IMarketRegistry.getMarket, (MARKET_B)), abi.encode(mb)
        );

        vm.prank(liquidator);
        clearingHouse.liquidate(alice, ETH_PERP, 10e18, 0);
        assertEq(clearingHouse.getPosition(alice, MARKET_B).margin, marginB, "unreadable market drawn");
    }
}
