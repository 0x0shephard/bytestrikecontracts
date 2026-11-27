// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {vAMM} from "../src/vAMM.sol";
import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression tests for the checks on privileged setters and trader gates
/// (Cyfrin bytestrike part 2, finding 27).
contract AuditFixesPart2AdminChecksTest is BaseTest {
    // ---------------------------------------------------------------- 1. deposit gate

    /// @notice A holder removed from the allowlist, with no free balance, can still deposit and top up
    /// its position instead of being liquidated; a wallet without a position stays gated.
    function test_Finding27_removedHolderCanDepositToTopUp() public {
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.startPrank(admin);
        clearingHouse.setAllowedTraders(list, true);
        clearingHouse.setAllowlistEnforced(true);
        vm.stopPrank();

        fundAndDeposit(alice, 1_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 5 ether, 0);

        vm.prank(admin);
        clearingHouse.setAllowedTraders(list, false);

        fundAndDeposit(alice, 2_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.addMargin(ETH_PERP, 2_000 * USDC_UNIT);

        address stranger = makeAddr("stranger");
        fundUser(stranger, 100 * USDC_UNIT);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 100 * USDC_UNIT);
        vm.expectRevert(ClearingHouse.TraderNotAllowed.selector);
        clearingHouse.deposit(address(usdc), 100 * USDC_UNIT);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 2. redundant unpause

    /// @notice An unpause of a market that is not paused leaves the funding clock alone, so funding
    /// owed since the last accrual is not erased.
    function test_Finding27_redundantUnpauseKeepsFundingClock() public {
        fundAndDeposit(alice, 100_000 * USDC_UNIT);
        fundAndDeposit(bob, 100_000 * USDC_UNIT);
        vm.prank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        vm.prank(bob);
        clearingHouse.openPosition(ETH_PERP, false, 1 ether, 0);
        uint256 t = block.timestamp;
        settleFunding(bob);
        uint64 clock = vamm.lastFundingTimestamp();

        vm.warp(t + 30 minutes);
        vm.prank(admin);
        marketRegistry.pauseMarket(ETH_PERP, false);
        assertEq(vamm.lastFundingTimestamp(), clock, "redundant unpause reset the funding clock");

        uint256 payBefore = vamm.cumulativeLongPayPerUnitX18();
        settleFunding(bob);
        assertGt(vamm.cumulativeLongPayPerUnitX18(), payBefore, "funding owed was erased");
    }

    // ---------------------------------------------------------------- 3. reserve floors

    /// @notice A floor may take at most half of the live reserve, in setMinReserves and resetReserves.
    function test_Finding27_floorsKeepHeadroom() public {
        (uint256 base, uint256 quote) = getReserves();
        uint256 maxBps = vamm.MAX_FLOOR_BPS();

        vm.startPrank(admin);
        vm.expectRevert("minBase too close to reserve");
        vamm.setMinReserves(base * maxBps / 10_000 + 1, 0);
        vm.expectRevert("minQuote too close to reserve");
        vamm.setMinReserves(0, quote * maxBps / 10_000 + 1);
        vamm.setMinReserves(base * maxBps / 10_000, quote * maxBps / 10_000);

        // A reset that would bring the reserves to within the floor's headroom is refused.
        vm.warp(block.timestamp + vamm.RESET_COOLDOWN());
        uint256 mark = vamm.getMarkPrice();
        vm.expectRevert("base too close to min");
        vamm.resetReserves(mark, base * 3 / 4);
        vamm.resetReserves(mark, base);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 4. CuOracle windows

    /// @notice The commit-reveal delay must stay below the maximum commit age, from either setter.
    function test_Finding27_revealDelayBelowMaxCommitAge() public {
        address owner = makeAddr("cuOwner");
        CuOracle cu = new CuOracle(owner, 1);
        uint256 maxAge = cu.maxCommitAge();

        vm.startPrank(owner);
        vm.expectRevert(CuOracle.InvalidInterval.selector);
        cu.updateCommitRevealDelay(maxAge);
        cu.updateCommitRevealDelay(maxAge - 1);

        vm.expectRevert(CuOracle.InvalidInterval.selector);
        cu.updateMaxCommitAge(maxAge - 1);
        cu.updateMaxCommitAge(maxAge);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 5. funding clamp

    /// @notice frMaxBpsPerHour is capped at 100 bps per hour in initialize and setParams.
    function test_Finding27_fundingClampCapped() public {
        uint256 cap = vamm.MAX_FR_BPS_PER_HOUR();
        assertEq(cap, 100);

        vm.startPrank(admin);
        vm.expectRevert("frMax too high");
        vamm.setParams(0, cap + 1, FUNDING_K);
        vamm.setParams(0, cap, FUNDING_K);

        address impl = address(new vAMM());
        bytes memory init = abi.encodeCall(
            vAMM.initialize, (address(clearingHouse), address(oracle), 2000e18, 1000e18, 1e24, 0, cap + 1, 1e18)
        );
        vm.expectRevert("frMax too high");
        new ERC1967Proxy(impl, init);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 6. one market per vAMM

    /// @notice A vAMM that already backs a market cannot be listed for a second one.
    function test_Finding27_vammBacksOneMarket() public {
        assertTrue(marketRegistry.vammInUse(address(vamm)));
        vm.prank(admin);
        vm.expectRevert("vAMM in use");
        marketRegistry.addMarket(
            IMarketRegistry.AddMarketConfig({
                marketId: keccak256("ETH-PERP-2"),
                vamm: address(vamm),
                oracle: address(oracle),
                baseAsset: address(weth),
                quoteToken: address(usdc),
                baseUnit: 1e18,
                feeBps: TRADE_FEE_BPS,
                feeRouter: address(feeRouter),
                insuranceFund: address(insuranceFund)
            })
        );
    }
}
