// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface ICuOracle {
    function updatePrice(uint256 newPrice) external;
    function getPrice() external view returns (uint256);
}

/**
 * @title SetCuOracleETHPrice
 * @notice Sets ETH index price in CuOracle to $3.79
 */
contract SetCuOracleETHPrice is Script {
    address constant CU_ORACLE = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c;

    // ETH price: $3.79 in 1e18
    uint256 constant ETH_PRICE = 3_790_000_000_000_000_000; // 3.79e18

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=========================================");
        console.log("  SET ETH INDEX PRICE IN CUORACLE");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("CuOracle:", CU_ORACLE);
        console.log("Target Price (wei):", ETH_PRICE);
        console.log("Target Price (USD): 3.79");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        try ICuOracle(CU_ORACLE).updatePrice(ETH_PRICE) {
            console.log("Price updated successfully!");
        } catch Error(string memory reason) {
            console.log("Failed with reason:", reason);
            console.log("CuOracle might use commit-reveal...");
        } catch {
            console.log("Failed with low-level error");
            console.log("Trying alternative methods...");
        }

        vm.stopBroadcast();

        // Verify
        try ICuOracle(CU_ORACLE).getPrice() returns (uint256 price) {
            console.log("");
            console.log("Verification:");
            console.log("  Current price (wei):", price);
        } catch {
            console.log("Could not read price (might need symbol parameter)");
        }

        console.log("");
        console.log("=========================================");
        console.log("  COMPLETE");
        console.log("=========================================");
    }
}
