// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {vAMM} from "../src/vAMM.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Regression tests for the vAMM swap fee (Cyfrin bytestrike part 2, finding 16).
contract AuditFixesPart2VammFeeTest is BaseTest {
    /// @notice Finding 16: a vAMM cannot be initialized with a swap fee.
    function test_Finding16_initializeRejectsNonZeroFee() public {
        vAMM impl = new vAMM();
        bytes memory init = abi.encodeCall(
            vAMM.initialize,
            (address(clearingHouse), address(oracle), INITIAL_ETH_PRICE, INITIAL_BASE_RESERVE, LIQUIDITY_INDEX, 10, FUNDING_MAX_BPS_PER_HOUR, FUNDING_K)
        );
        vm.expectRevert("vAMM fee must be 0");
        new ERC1967Proxy(address(impl), init);
    }

    /// @notice Finding 16: the owner cannot raise the swap fee later, but can still clear one.
    function test_Finding16_setParamsRejectsNonZeroFee() public {
        vm.startPrank(admin);
        vm.expectRevert("vAMM fee must be 0");
        vamm.setParams(10, FUNDING_MAX_BPS_PER_HOUR, FUNDING_K);

        vamm.setParams(0, FUNDING_MAX_BPS_PER_HOUR, 2e18);
        vm.stopPrank();
        assertEq(vamm.feeBps(), 0);
        assertEq(vamm.kFundingX18(), 2e18);
    }

    /// @notice Finding 16: with no fee kept in the reserves, a round trip that returns net open
    /// interest to zero returns the mark to where it started, and only the market fee is charged.
    function test_Finding16_roundTripLeavesMarkUnchanged() public {
        uint256 markBefore = getMarkPrice();
        fundAndDeposit(alice, 50_000 * USDC_UNIT);
        vm.startPrank(alice);
        clearingHouse.openPosition(ETH_PERP, true, 10 ether, 0);
        clearingHouse.closePosition(ETH_PERP, 10 ether, 0);
        vm.stopPrank();

        assertEq(vamm.totalLongOI(), 0);
        assertApproxEqAbs(getMarkPrice(), markBefore, 1e6, "mark back at its start");
    }
}
