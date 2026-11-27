// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

/// @notice Finding 44 follow-up: a vAMM can only name its ClearingHouse's registry, so the vAMM owner cannot
/// rebind a live market's pause flag and funding oracle to another registry.
contract AuditFixesPart2Review44Test is BaseTest {
    uint128 internal constant LONG_SIZE = 10 * 1e18;

    function test_VammCannotBeReboundToAnotherRegistry() public {
        fundAndDeposit(alice, 50_000 * 1e18);
        openLongPosition(alice, LONG_SIZE, 0);

        vm.startPrank(admin);
        MarketRegistry secondRegistry = new MarketRegistry();
        vm.expectRevert(bytes("Registry mismatch"));
        vamm.setRegistry(address(secondRegistry));

        // Nor to an arbitrary address the owner controls
        vm.expectRevert(bytes("Registry mismatch"));
        vamm.setRegistry(admin);

        // The second registry cannot list the market, since the vAMM still names the ClearingHouse's registry
        MockOracle otherOracle = new MockOracle(2_100 * 1e18, 18);
        vm.expectRevert(bytes("vAMM registry mismatch"));
        secondRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: ETH_PERP,
                vamm: address(vamm),
                oracle: address(otherOracle),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: TRADE_FEE_BPS,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
        vm.stopPrank();

        // The vAMM stays bound to the ClearingHouse's registry, which still controls its oracle and pause flag
        assertEq(vamm.registry(), address(marketRegistry), "vAMM registry moved");
        assertEq(vamm.oracle(), address(oracle), "funding oracle moved");

        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, true);
        assertTrue(vamm.swapsPaused(), "registry pause did not reach the vAMM");
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, false);
        assertFalse(vamm.swapsPaused(), "registry unpause did not reach the vAMM");

        vm.prank(alice);
        clearingHouse.closePosition(ETH_PERP, LONG_SIZE, 0);
        assertEq(clearingHouse.getPosition(alice, ETH_PERP).size, 0, "close failed");
    }

    function test_SetRegistryAcceptsClearingHouseRegistry() public {
        // Re-naming the ClearingHouse's own registry stays allowed
        vm.prank(admin);
        vamm.setRegistry(address(marketRegistry));
        assertEq(vamm.registry(), address(marketRegistry));
    }
}
