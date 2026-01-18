// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Simple ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 initialSupply
    ) ERC20(name, symbol) {
        _decimals = decimals_;
        _mint(msg.sender, initialSupply);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title DeployMockTokens
/// @notice Deploys mock ERC20 tokens for testing on Sepolia
contract DeployMockTokens is Script {

    MockERC20 public usdc;
    MockERC20 public weth;
    MockERC20 public wbtc;

    function run() external {
        console.log("Deploying mock test tokens on Sepolia...");
        console.log("Deployer:", msg.sender);

        vm.startBroadcast();

        // Deploy Mock USDC (6 decimals)
        usdc = new MockERC20(
            "Mock USD Coin",
            "USDC",
            6,
            100_000_000 * 1e6 // 100M USDC initial supply
        );
        console.log("Mock USDC deployed at:", address(usdc));

        // Deploy Mock WETH (18 decimals)
        weth = new MockERC20(
            "Mock Wrapped Ether",
            "WETH",
            18,
            100_000 * 1e18 // 100K WETH initial supply
        );
        console.log("Mock WETH deployed at:", address(weth));

        // Deploy Mock WBTC (8 decimals)
        wbtc = new MockERC20(
            "Mock Wrapped Bitcoin",
            "WBTC",
            8,
            10_000 * 1e8 // 10K WBTC initial supply
        );
        console.log("Mock WBTC deployed at:", address(wbtc));

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("Mock Token Deployment Complete!");
        console.log("========================================");
        console.log("USDC:", address(usdc));
        console.log("WETH:", address(weth));
        console.log("WBTC:", address(wbtc));
        console.log("\nInitial balances sent to:", msg.sender);
        console.log("========================================\n");

        // Save token addresses
        _saveTokenAddresses();
    }

    function _saveTokenAddresses() internal {
        string memory json = "tokens";

        vm.serializeAddress(json, "usdc", address(usdc));
        vm.serializeAddress(json, "weth", address(weth));
        string memory finalJson = vm.serializeAddress(json, "wbtc", address(wbtc));

        vm.writeJson(finalJson, "./deployments/sepolia-tokens.json");
        console.log("Token addresses saved to: deployments/sepolia-tokens.json");
    }
}
