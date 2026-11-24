// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Finding 38: a market's risk oracle and its vAMM's funding oracle move together.
contract AuditFixesPart2OracleSyncTest is BaseTest {
    bytes32 internal constant NEW_MARKET = keccak256("NEW-PERP");

    event FundingSkipped(uint64 timestamp);

    function _newVamm(address oracle_, bool setRegistry) internal returns (vAMM v) {
        bytes memory init = abi.encodeCall(
            vAMM.initialize, (address(clearingHouse), oracle_, 2_000e18, 1_000e18, 1e24, 0, 100, 1e18)
        );
        vm.startPrank(admin);
        v = vAMM(address(new ERC1967Proxy(address(new vAMM()), init)));
        if (setRegistry) v.setRegistry(address(marketRegistry));
        vm.stopPrank();
    }

    function _config(address vamm_, address oracle_) internal view returns (IMarketRegistry.AddMarketConfig memory) {
        return IMarketRegistry.AddMarketConfig({
            marketId: NEW_MARKET,
            vamm: vamm_,
            oracle: oracle_,
            baseAsset: address(weth),
            quoteToken: address(usdc),
            baseUnit: 1e18,
            feeBps: 10,
            feeRouter: address(feeRouter),
            insuranceFund: address(insuranceFund)
        });
    }

    /// @notice MarketRegistry.setOracle also moves the vAMM's funding oracle and refreshes its cache.
    function test_Finding38_registrySetOracleMovesFundingOracle() public {
        MockOracle newOracle = new MockOracle(2_100e18, 18);
        vm.prank(admin);
        marketRegistry.setOracle(ETH_PERP, address(newOracle));

        assertEq(marketRegistry.getMarket(ETH_PERP).oracle, address(newOracle), "risk oracle");
        assertEq(vamm.oracle(), address(newOracle), "funding oracle left on the old index");
        assertEq(vamm.cachedIndexPrice(), 2_100e18, "cache not refreshed");
    }

    /// @notice The vAMM's funding oracle can no longer be moved on its own.
    function test_Finding38_vammSetOracleIsRegistryOnly() public {
        MockOracle newOracle = new MockOracle(2_100e18, 18);
        vm.prank(admin); // vAMM owner
        vm.expectRevert(bytes("Not registry"));
        vamm.setOracle(address(newOracle));
    }

    /// @notice A migration to an oracle without a valid price reverts as a whole.
    function test_Finding38_setOracleRequiresLivePrice() public {
        MockOracle zeroOracle = new MockOracle(0, 18);
        vm.prank(admin);
        vm.expectRevert(bytes("oracle price=0"));
        marketRegistry.setOracle(ETH_PERP, address(zeroOracle));

        MockOracle revertingOracle = new MockOracle(2_000e18, 18);
        vm.mockCallRevert(address(revertingOracle), abi.encodeWithSignature("getPrice()"), "stale");
        vm.prank(admin);
        vm.expectRevert(bytes("stale"));
        marketRegistry.setOracle(ETH_PERP, address(revertingOracle));

        assertEq(marketRegistry.getMarket(ETH_PERP).oracle, address(oracle), "risk oracle moved");
        assertEq(vamm.oracle(), address(oracle), "funding oracle moved");
    }

    /// @notice addMarket requires the vAMM to name the registry and aligns its funding oracle.
    function test_Finding38_addMarketAlignsFundingOracle() public {
        MockOracle marketOracle = new MockOracle(2_000e18, 18);

        vAMM unlinked = _newVamm(address(oracle), false);
        vm.prank(admin);
        vm.expectRevert(bytes("vAMM registry mismatch"));
        marketRegistry.addMarket(_config(address(unlinked), address(marketOracle)));

        vAMM linked = _newVamm(address(oracle), true);
        vm.prank(admin);
        marketRegistry.addMarket(_config(address(linked), address(marketOracle)));
        assertEq(linked.oracle(), address(marketOracle), "market starts split");
    }

    /// @notice An index outage is visible on the vAMM, and settlement skips funding while the
    /// market's risk oracle is down.
    function test_Finding38_indexOutageEmitsFundingSkipped() public {
        fundAndDeposit(alice, 100_000e18);
        fundAndDeposit(bob, 100_000e18);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10e18, 0);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 1e18, 0);

        uint256 t = block.timestamp + 1 hours;
        vm.warp(t);
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPrice()"), "stale");
        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();

        vm.expectEmit(address(vamm));
        emit FundingSkipped(uint64(t));
        clearingHouse.settleFunding(ETH_PERP, alice);

        assertEq(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding accrued during the outage");
        assertEq(vamm.lastFundingTimestamp(), t, "clock not advanced");
    }
}
