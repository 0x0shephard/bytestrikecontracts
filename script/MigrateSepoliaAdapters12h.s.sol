// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

interface ICuOracleAdapterView {
    function assetId() external view returns (bytes32);
    function maxAge() external view returns (uint256);
}

/// @notice Replaces the per-market Sepolia CuOracleAdapters with 12h maxAge adapters.
/// @dev Broadcast with PRIVATE_KEY set to an account that can call MarketRegistry.setOracle
///      and vAMM.setOracle for the active frontend markets.
contract MigrateSepoliaAdapters12h is Script {
    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address constant REGISTRY = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;

    uint256 constant OLD_MAX_AGE = 1 hours;
    uint256 constant NEW_MAX_AGE = 12 hours;

    struct MarketSpec {
        string name;
        bytes32 marketId;
    }

    struct MigrationResult {
        string name;
        bytes32 marketId;
        bytes32 assetId;
        address vammAddress;
        address oldAdapter;
        address newAdapter;
        uint256 oldMaxAge;
        uint256 newMaxAge;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        MarketSpec[] memory specs = _activeFrontendMarkets();
        MigrationResult[] memory results = new MigrationResult[](specs.length);

        vm.startBroadcast(deployerPk);
        for (uint256 i = 0; i < specs.length; i++) {
            results[i] = _migrateOne(specs[i]);
        }
        vm.stopBroadcast();

        _writeArtifacts(results);
        console.log("Migrated active Sepolia frontend markets to 12h CuOracleAdapters:", specs.length);
    }

    function _migrateOne(MarketSpec memory spec) internal returns (MigrationResult memory result) {
        IMarketRegistry.Market memory market = MarketRegistry(REGISTRY).getMarket(spec.marketId);
        require(market.vamm != address(0), "market missing");
        require(market.oracle != address(0), "oracle missing");

        bytes32 assetId = ICuOracleAdapterView(market.oracle).assetId();
        uint256 oldMaxAge = ICuOracleAdapterView(market.oracle).maxAge();

        if (oldMaxAge == NEW_MAX_AGE) {
            console.log("Skipped already migrated:", spec.name);
            console.log("  vAMM:", market.vamm);
            console.log("  adapter:", market.oracle);
            console.log("  maxAge:", oldMaxAge);

            return MigrationResult({
                name: spec.name,
                marketId: spec.marketId,
                assetId: assetId,
                vammAddress: market.vamm,
                oldAdapter: market.oracle,
                newAdapter: market.oracle,
                oldMaxAge: oldMaxAge,
                newMaxAge: NEW_MAX_AGE
            });
        }

        address newAdapter = address(new CuOracleAdapter(CU_ORACLE, assetId, NEW_MAX_AGE));
        MarketRegistry(REGISTRY).setOracle(spec.marketId, newAdapter);
        vAMM(market.vamm).setOracle(newAdapter);

        IMarketRegistry.Market memory updated = MarketRegistry(REGISTRY).getMarket(spec.marketId);
        require(updated.oracle == newAdapter, "registry oracle mismatch");
        require(vAMM(market.vamm).oracle() == newAdapter, "vAMM oracle mismatch");
        require(ICuOracleAdapterView(newAdapter).maxAge() == NEW_MAX_AGE, "new maxAge mismatch");
        require(ICuOracleAdapterView(newAdapter).assetId() == assetId, "assetId mismatch");

        console.log("Migrated:", spec.name);
        console.log("  vAMM:", market.vamm);
        console.log("  old adapter:", market.oracle);
        console.log("  old maxAge:", oldMaxAge);
        console.log("  new adapter:", newAdapter);

        result = MigrationResult({
            name: spec.name,
            marketId: spec.marketId,
            assetId: assetId,
            vammAddress: market.vamm,
            oldAdapter: market.oracle,
            newAdapter: newAdapter,
            oldMaxAge: oldMaxAge,
            newMaxAge: NEW_MAX_AGE
        });
    }

    function _activeFrontendMarkets() internal pure returns (MarketSpec[] memory s) {
        s = new MarketSpec[](23);
        s[0] = MarketSpec("A100-PERP", keccak256("A100-PERP"));
        s[1] = MarketSpec("AWS-H100-PERP", keccak256("AWS-H100-PERP"));
        s[2] = MarketSpec("AWS-H200-PERP", keccak256("AWS-H200-PERP"));
        s[3] = MarketSpec("AZURE-H100-PERP", keccak256("AZURE-H100-PERP"));
        s[4] = MarketSpec("COREWEAVE-H200-PERP", keccak256("COREWEAVE-H200-PERP"));
        s[5] = MarketSpec("GCP-H100-PERP", keccak256("GCP-H100-PERP"));
        s[6] = MarketSpec("GCP-H200-PERP", keccak256("GCP-H200-PERP"));
        s[7] = MarketSpec("ORACLE-H200-PERP", keccak256("ORACLE-H200-PERP"));
        s[8] = MarketSpec("T4-PERP", keccak256("T4-PERP"));
        s[9] = MarketSpec("H100-GPU-PERP", keccak256("H100-GPU-PERP"));
        s[10] = MarketSpec("H100-HyperScalers-PERP", keccak256("H100-HyperScalers-PERP"));
        s[11] = MarketSpec("ORACLE-H200-PERPETUAL", keccak256("ORACLE-H200-PERPETUAL"));
        s[12] = MarketSpec("AWS-H200-PERPETUAL", keccak256("AWS-H200-PERPETUAL"));
        s[13] = MarketSpec("COREWEAVE-H200-PERPETUAL", keccak256("COREWEAVE-H200-PERPETUAL"));
        s[14] = MarketSpec("GCP-H200-PERPETUAL", keccak256("GCP-H200-PERPETUAL"));
        s[15] = MarketSpec("AZURE-H200-PERPETUAL", keccak256("AZURE-H200-PERPETUAL"));
        s[16] = MarketSpec("B200-PERP-V2", keccak256("B200-PERP-V2"));
        s[17] = MarketSpec("AWS-B200-PERP", keccak256("AWS-B200-PERP"));
        s[18] = MarketSpec("ORACLE-B200-PERP", keccak256("ORACLE-B200-PERP"));
        s[19] = MarketSpec("COREWEAVE-B200-PERP", keccak256("COREWEAVE-B200-PERP"));
        s[20] = MarketSpec("GCP-B200-PERP", keccak256("GCP-B200-PERP"));
        s[21] = MarketSpec("H200-PERP-V2", keccak256("H200-PERP-V2"));
        s[22] = MarketSpec("H100-non-HyperScalers-PERP-V2", keccak256("H100-non-HyperScalers-PERP-V2"));
    }

    function _writeArtifacts(MigrationResult[] memory results) internal {
        string memory root = "adapterMigration";
        string memory all;

        vm.serializeString(root, "network", "sepolia");
        vm.serializeUint(root, "chainId", 11155111);
        vm.serializeAddress(root, "cuOracle", CU_ORACLE);
        vm.serializeAddress(root, "marketRegistry", REGISTRY);
        vm.serializeUint(root, "newMaxAge", NEW_MAX_AGE);

        for (uint256 i = 0; i < results.length; i++) {
            string memory item = string(abi.encodePacked("m", vm.toString(i)));
            vm.serializeString(item, "name", results[i].name);
            vm.serializeBytes32(item, "marketId", results[i].marketId);
            vm.serializeBytes32(item, "assetId", results[i].assetId);
            vm.serializeAddress(item, "vamm", results[i].vammAddress);
            vm.serializeAddress(item, "oldAdapter", results[i].oldAdapter);
            vm.serializeUint(item, "oldMaxAge", results[i].oldMaxAge);
            vm.serializeAddress(item, "newAdapter", results[i].newAdapter);
            string memory itemJson = vm.serializeUint(item, "newMaxAge", results[i].newMaxAge);
            all = vm.serializeString(root, vm.toString(i), itemJson);
        }

        vm.writeJson(all, "./deployments/sepolia-adapters-12h.json");
        console.log("Wrote deployments/sepolia-adapters-12h.json");
    }
}
