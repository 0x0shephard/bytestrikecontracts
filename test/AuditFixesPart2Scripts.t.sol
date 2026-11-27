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

    /// @notice Finding 36: imports name the tracked folder `Interfaces` with its exact case, so the
    /// sources build on case-sensitive filesystems. Every relative import of an `interfaces` folder
    /// under src must use the capitalised name the repository tracks.
    function test_Finding36_importsMatchTrackedFolderCase() public view {
        // The tracked folder is `src/Oracle/Interfaces` (listed with its on-disk case).
        Vm.DirEntry[] memory oracleDir = vm.readDir("./src/Oracle");
        bool found;
        for (uint256 i; i < oracleDir.length; i++) {
            if (oracleDir[i].isDir && _endsWith(oracleDir[i].path, "/Interfaces")) found = true;
        }
        assertTrue(found, "src/Oracle/Interfaces not found");

        Vm.DirEntry[] memory entries = vm.readDir("./src", 3);
        uint256 checked;
        for (uint256 i; i < entries.length; i++) {
            Vm.DirEntry memory e = entries[i];
            if (e.isDir || !_endsWith(e.path, ".sol")) continue;
            string memory src = vm.readFile(e.path);
            assertEq(vm.indexOf(src, "/interfaces/"), type(uint256).max, e.path);
            checked++;
        }
        assertGt(checked, 10, "sources not scanned");
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
