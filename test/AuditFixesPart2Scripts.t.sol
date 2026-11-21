// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Regression checks on deployment and operations scripts (Cyfrin bytestrike part 2).
contract AuditFixesPart2ScriptsTest is Test {
    /// @notice Finding 32: no script loads the privileged key from the PRIVATE_KEY environment
    /// variable; scripts sign with --account / --ledger and a bare vm.startBroadcast().
    function test_Finding32_scriptsDoNotReadPrivateKeyFromEnv() public view {
        Vm.DirEntry[] memory entries = vm.readDir("./script");
        uint256 checked;
        for (uint256 i; i < entries.length; i++) {
            Vm.DirEntry memory e = entries[i];
            if (e.isDir || !_endsWith(e.path, ".s.sol")) continue;
            string memory src = vm.readFile(e.path);
            assertEq(vm.indexOf(src, "PRIVATE_KEY"), type(uint256).max, e.path);
            checked++;
        }
        assertGt(checked, 50, "scripts not scanned");
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory x = bytes(suffix);
        if (b.length < x.length) return false;
        for (uint256 i; i < x.length; i++) {
            if (b[b.length - x.length + i] != x[i]) return false;
        }
        return true;
    }
}
