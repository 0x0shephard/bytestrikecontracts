// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Mock Price Feed that implements AggregatorV3Interface
contract MockPriceFeed {
    uint8 public decimals = 8; // Chainlink USD feeds typically use 8 decimals
    int256 public price;
    uint256 public timestamp;

    constructor(int256 _initialPrice) {
        price = _initialPrice;
        timestamp = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            1,
            price,
            timestamp,
            timestamp,
            1
        );
    }

    function setPrice(int256 _newPrice) external {
        price = _newPrice;
        timestamp = block.timestamp;
    }
}

contract DeployMockUSDCOracle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Mock USDC Price Feed...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock price feed with $1.00 price (8 decimals: 100000000 = $1.00)
        MockPriceFeed mockUSDCFeed = new MockPriceFeed(100000000);
        console.log("Mock USDC Price Feed deployed:", address(mockUSDCFeed));

        // Configure Oracle to use this feed
        address oracle = 0x7d1cc77Cb9C0a30a9aBB3d052A5542aB5E254c9c;

        // Set price feed for USDC
        (bool success1,) = oracle.call(
            abi.encodeWithSignature("setPriceFeed(string,address)", "USDC", address(mockUSDCFeed))
        );
        require(success1, "Failed to set price feed");
        console.log("Set USDC price feed in Oracle");

        // Set base unit for USDC (1e6 for 6 decimals)
        (bool success2,) = oracle.call(
            abi.encodeWithSignature("setBaseUnit(string,uint256)", "USDC", 1e6)
        );
        require(success2, "Failed to set base unit");
        console.log("Set USDC base unit in Oracle");

        vm.stopBroadcast();

        console.log("");
        console.log("Setup complete!");
        console.log("Mock USDC Price Feed:", address(mockUSDCFeed));
        console.log("Price: $1.00 (100000000 with 8 decimals)");
    }
}
