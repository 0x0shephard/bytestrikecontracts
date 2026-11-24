// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";

/// @notice Regression tests for vAMM admin access (Cyfrin bytestrike part 2).
contract AuditFixesPart2VammAccessTest is BaseTest {
    /// @notice Finding 60: the vAMM's clearinghouse cannot be replaced, so open positions can never be
    /// stranded in a clearinghouse that no longer reaches the vAMM.
    function test_Finding60_clearinghouseCannotBeReplaced() public {
        address newCH = makeAddr("newCH");
        vm.prank(admin);
        (bool ok,) = address(vamm).call(abi.encodeWithSignature("setClearinghouse(address)", newCH));
        assertFalse(ok, "setClearinghouse must not exist");
        assertEq(vamm.clearinghouse(), address(clearingHouse));
    }
}
