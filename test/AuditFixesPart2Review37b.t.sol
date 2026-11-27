// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression for finding 37 (second mitigation review): while an account's quote value is below
/// its reserved margin, a voluntary trade that realizes a loss may not lower value / reserved margin, so
/// a partial close cannot lose more than its slice's backed share and strip the other positions' backing.
contract AuditFixesPart2Review37bTest is BaseTest {
    bytes32 internal constant MARKET_Z = keccak256("Z-PERP");
    bytes32 internal constant MARKET_C = keccak256("C-PERP");
    bytes4 internal constant BACKING_RATIO_LOWERED = bytes4(keccak256("BackingRatioLowered()"));

    MockOracle internal oracleZ;
    MockOracle internal oracleC;

    function setUp() public override {
        super.setUp();
        oracleZ = _addMarket(MARKET_Z, 0);
        oracleC = _addMarket(MARKET_C, TRADE_FEE_BPS);

        fundAndDeposit(alice, 20_000e18);
        vm.startPrank(alice);
        clearingHouse.openPosition(MARKET_Z, true, 10e18, 0);
        clearingHouse.openPosition(ETH_PERP, true, 5e18, 0);
        clearingHouse.openPosition(MARKET_C, true, 10e18, 0);
        clearingHouse.addMargin(MARKET_Z, 8_800e18);
        clearingHouse.addMargin(ETH_PERP, 700e18);
        vm.stopPrank();

        // alice keeps only her reserved margin
        uint256 free = getCollateralBalance(alice) - _reserved();
        vm.prank(alice);
        clearingHouse.withdraw(address(usdc), free);

        fundAndDeposit(bob, 2_000_000e18);

        // the ETH index falls 5% and an arbitrageur sells the ETH mark down to it
        setOraclePrice(1_900e18);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 30e18, 0);

        // the C index gaps down 15% and C is liquidated past its margin: the account is underbacked
        oracleC.setPrice(1_700e18);
        vm.prank(bob);
        clearingHouse.openPosition(MARKET_C, false, 90e18, 0);
        vm.prank(liquidator);
        clearingHouse.liquidate(alice, MARKET_C, 10e18, 0);
        assertEq(clearingHouse.getPosition(alice, MARKET_C).size, 0, "C not closed");
        assertLt(getCollateralBalance(alice), _reserved(), "account not underbacked");
        assertFalse(clearingHouse.isLiquidatable(alice, ETH_PERP), "ETH liquidatable before");
    }

    function _addMarket(bytes32 marketId, uint16 feeBps) internal returns (MockOracle o) {
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
                feeBps: feeBps,
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

    function test_FairPartialCloseStillPasses() public {
        // a partial close at the unpushed mark realizes less than its slice's backed share
        vm.prank(alice);
        clearingHouse.closePosition(MARKET_Z, 5e18, 0);
        assertEq(clearingHouse.getPosition(alice, MARKET_Z).size, 5e18);
        assertFalse(clearingHouse.isLiquidatable(alice, ETH_PERP), "ETH liquidatable");
    }

    function test_PushedPartialCloseCannotLowerBackingRatio() public {
        uint256 passed;
        uint256 refused;
        // bob pushes the Z mark down by growing amounts; alice then closes half of Z
        for (uint256 push = 50e18; push <= 900e18; push += 50e18) {
            uint256 snap = vm.snapshotState();
            uint256 valueBefore = getCollateralBalance(alice);
            uint256 reservedBefore = _reserved();
            vm.prank(bob);
            clearingHouse.openPosition(MARKET_Z, false, uint128(push), 0);
            vm.prank(alice);
            try clearingHouse.closePosition(MARKET_Z, 5e18, 0) {
                passed++;
                // the close never lowers value / reserved margin, so the ETH long keeps its backing
                assertGe(
                    getCollateralBalance(alice) * reservedBefore,
                    valueBefore * _reserved(),
                    "backing ratio lowered"
                );
                assertFalse(clearingHouse.isLiquidatable(alice, ETH_PERP), "ETH long stripped of backing");
            } catch (bytes memory err) {
                if (bytes4(err) == BACKING_RATIO_LOWERED) refused++;
            }
            vm.revertToState(snap);
        }
        assertGt(passed, 0, "no close passed");
        assertGt(refused, 0, "no close refused for lowering the backing ratio");
    }
}
