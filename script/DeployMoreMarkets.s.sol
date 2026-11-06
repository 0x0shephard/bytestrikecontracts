// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {vAMM} from "../src/vAMM.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

/// @title DeployMoreMarkets
/// @notice Batch-deploys the additional GPU-compute perpetual markets on top of the
///         existing Sepolia ByteStrike protocol. For each market it:
///           1. Registers a fresh asset in the shared CuOracle.
///           2. Deploys a per-market CuOracleAdapter.
///           3. Deploys a per-market vAMM ERC1967 proxy (reusing the shared impl).
///           4. Calls MarketRegistry.addMarket — which leaves the market UNPAUSED.
///           5. Calls registry.pauseMarket(id, true) to close the front-running
///              window until the seed long+short land in Phase B (audit M-12).
///           6. Calls ClearingHouse.setRiskParams (audit L-05 — mmrBps > 0).
///           7. Commits the index price via CuOracle (audit I-12 — derived nonce
///              from a single unpredictable NONCE_BASE env var).
///         Writes per-market addresses + nonces to `deployments/sepolia-batch.json`
///         for the seed/unpause script to consume.
contract DeployMoreMarkets is Script {

    // ========= Existing Sepolia deployment (sepolia.json) =========
    address constant CU_ORACLE        = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address constant REGISTRY         = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address constant CH               = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address constant USDC             = 0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE;
    address constant FEE_ROUTER       = 0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e;
    address constant INSURANCE_FUND   = 0x132Ba3d3073FDa7440fb0594210C47eC19087eaD;
    address constant VAMM_IMPL        = 0xC943C963DAFc8043E349a9191D4c567f2CB693AA;
    address constant H100_DUMMY_BASE  = 0x0000000000000000000000000000000000000001;

    // ========= Common vAMM init params =========
    uint256 constant INITIAL_BASE_RESERVE = 10_000e18;
    uint128 constant LIQUIDITY            = 1e24;
    uint16  constant FEE_BPS              = 10;
    uint256 constant FR_MAX_BPS_PER_HOUR  = 100;   // L-18: non-zero
    uint256 constant K_FUNDING_X18        = 1e18;  // L-18: non-zero
    uint256 constant CU_ORACLE_MAX_AGE    = 12 hours;

    struct Spec {
        string  name;          // market name; marketId = keccak256(name)
        string  assetSymbol;   // CuOracle asset symbol; assetId = keccak256(symbol)
        uint256 priceX18;
        uint256 imrBps;
        uint256 mmrBps;
        uint256 liqPenaltyBps;
        uint256 penaltyCap;    // 1e18 USD
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase  = vm.envBytes32("NONCE_BASE");

        Spec[] memory s = _buildSpecs();

        bytes32[] memory marketIds = new bytes32[](s.length);
        bytes32[] memory assetIds  = new bytes32[](s.length);
        bytes32[] memory nonces    = new bytes32[](s.length);
        address[] memory adapters  = new address[](s.length);
        address[] memory vammProxies = new address[](s.length);

        console.log("============================================");
        console.log(" Batch deploy: ", s.length, "markets");
        console.log("============================================");

        vm.startBroadcast(deployerPk);

        for (uint256 i = 0; i < s.length; i++) {
            (marketIds[i], assetIds[i], nonces[i], adapters[i], vammProxies[i]) =
                _deployOne(s[i], nonceBase);
        }

        vm.stopBroadcast();

        _writeArtifacts(s, marketIds, assetIds, nonces, adapters, vammProxies);
    }

    function _deployOne(Spec memory s, bytes32 nonceBase)
        internal
        returns (
            bytes32 marketId,
            bytes32 assetId,
            bytes32 nonce,
            address adapter,
            address vammProxy
        )
    {
        marketId = keccak256(bytes(s.name));
        assetId  = keccak256(bytes(s.assetSymbol));
        nonce    = keccak256(abi.encode(nonceBase, assetId));

        // 1. CuOracle: register the asset.
        CuOracle(CU_ORACLE).registerAsset(assetId);

        // 2. Per-market CuOracleAdapter.
        adapter = address(new CuOracleAdapter(CU_ORACLE, assetId, CU_ORACLE_MAX_AGE));

        // 3. Per-market vAMM (UUPS proxy reusing shared impl).
        bytes memory init = abi.encodeCall(
            vAMM.initialize,
            (
                CH,
                adapter,
                s.priceX18,
                INITIAL_BASE_RESERVE,
                LIQUIDITY,
                FEE_BPS,
                FR_MAX_BPS_PER_HOUR,
                K_FUNDING_X18
            )
        );
        vammProxy = address(new ERC1967Proxy(VAMM_IMPL, init));

        // 4. Wire vAMM to registry so pauseMarket can flip vAMM.swapsPaused.
        vAMM(vammProxy).setRegistry(REGISTRY);

        // 5. Register market — addMarket leaves the market UNPAUSED.
        MarketRegistry(REGISTRY).addMarket(IMarketRegistry.AddMarketConfig({
            marketId:      marketId,
            vamm:          vammProxy,
            oracle:        adapter,
            baseAsset:     H100_DUMMY_BASE,
            quoteToken:    USDC,
            baseUnit:      1e18,
            feeBps:        FEE_BPS,
            feeRouter:     FEE_ROUTER,
            insuranceFund: INSURANCE_FUND
        }));

        // 6. Pause until seed trades land (race-window protection — audit M-12).
        MarketRegistry(REGISTRY).pauseMarket(marketId, true);

        // 7. Risk params (audit L-05 — openPosition requires mmrBps > 0).
        ClearingHouse(payable(CH)).setRiskParams(
            marketId,
            s.imrBps,
            s.mmrBps,
            s.liqPenaltyBps,
            s.penaltyCap,
            0,
            0
        );

        // 8. Commit oracle price with derived per-market nonce.
        bytes32 commitment = keccak256(abi.encodePacked(s.priceX18, nonce));
        CuOracle(CU_ORACLE).commitPrice(assetId, commitment);

        console.log(s.name);
        console.log("  vAMM:    ", vammProxy);
        console.log("  Adapter: ", adapter);
    }

    function _writeArtifacts(
        Spec[] memory s,
        bytes32[] memory marketIds,
        bytes32[] memory assetIds,
        bytes32[] memory nonces,
        address[] memory adapters,
        address[] memory vamms
    ) internal {
        string memory key = "batch";
        string memory all;

        for (uint256 i = 0; i < s.length; i++) {
            string memory inner = string(abi.encodePacked("m", vm.toString(i)));
            vm.serializeString(inner, "name", s[i].name);
            vm.serializeString(inner, "assetSymbol", s[i].assetSymbol);
            vm.serializeBytes32(inner, "marketId", marketIds[i]);
            vm.serializeBytes32(inner, "assetId", assetIds[i]);
            vm.serializeBytes32(inner, "nonce", nonces[i]);
            vm.serializeUint(inner, "priceX18", s[i].priceX18);
            vm.serializeUint(inner, "imrBps", s[i].imrBps);
            vm.serializeUint(inner, "mmrBps", s[i].mmrBps);
            vm.serializeUint(inner, "liqPenaltyBps", s[i].liqPenaltyBps);
            vm.serializeUint(inner, "penaltyCap", s[i].penaltyCap);
            vm.serializeAddress(inner, "adapter", adapters[i]);
            string memory innerJson = vm.serializeAddress(inner, "vamm", vamms[i]);
            all = vm.serializeString(key, vm.toString(i), innerJson);
        }
        vm.writeJson(all, "./deployments/sepolia-batch.json");
        console.log("Wrote deployments/sepolia-batch.json");
    }

    /// @dev Hardcoded market specs. Prices in 1e18.
    function _buildSpecs() internal pure returns (Spec[] memory s) {
        s = new Spec[](19);

        // ─── First table: standard 10/5/2.5/$1k ──────────────────────────────────
        s[0]  = Spec("A100-PERP",                      "A100",                  176e16,  1000, 500, 250, 1000e18);
        s[1]  = Spec("AWS-H100-PERP",                  "AWS-H100",              385e16,  1000, 500, 250, 1000e18);
        s[2]  = Spec("AWS-H200-PERP",                  "AWS-H200",              404e16,  1000, 500, 250, 1000e18);
        s[3]  = Spec("AZURE-H100-PERP",                "AZURE-H100",            212e16,  1000, 500, 250, 1000e18);
        s[4]  = Spec("B200-PERP",                      "B200",                  715e16,  1000, 500, 250, 1000e18);
        s[5]  = Spec("COREWEAVE-H200-PERP",            "COREWEAVE-H200",        1453e16, 1000, 500, 250, 1000e18);
        s[6]  = Spec("GCP-H100-PERP",                  "GCP-H100",              388e16,  1000, 500, 250, 1000e18);
        s[7]  = Spec("GCP-H200-PERP",                  "GCP-H200",              660e16,  1000, 500, 250, 1000e18);
        s[8]  = Spec("H200-PERP",                      "H200",                  353e16,  1000, 500, 250, 1000e18);
        s[9]  = Spec("H100-HyperScalers-PERP",         "H100-HyperScalers",     420e16,  1000, 500, 250, 1000e18);
        s[10] = Spec("H100-non-HyperScalers-PERP",     "H100-non-HyperScalers", 295e16,  1000, 500, 250, 1000e18);
        s[11] = Spec("ORACLE-H200-PERP",               "ORACLE-H200",           647e16,  1000, 500, 250, 1000e18);
        s[12] = Spec("T4-PERP",                        "T4",                     45e16,  1000, 500, 250, 1000e18);

        // H100-GPU-PERP: distinct risk params (10/2.5/2.0/$10k)
        s[13] = Spec("H100-GPU-PERP",                  "H100-GPU",              375e16,  1000, 250, 200, 10000e18);

        // ─── Second table: provider-specific H200 markets ────────────────────────
        s[14] = Spec("ORACLE-H200-PERPETUAL",          "ORACLE_H200_HOUR",      292e16,  1000, 500, 250, 1000e18);
        s[15] = Spec("AWS-H200-PERPETUAL",             "AWS_H200_HOUR",         265e16,  1000, 500, 250, 1000e18);
        s[16] = Spec("COREWEAVE-H200-PERPETUAL",       "COREWEAVE_H200_HOUR",   257e16,  1000, 500, 250, 1000e18);
        s[17] = Spec("GCP-H200-PERPETUAL",             "GCP_H200_HOUR",         455e16,  1000, 500, 250, 1000e18);
        s[18] = Spec("AZURE-H200-PERPETUAL",           "AZURE_H200_HOUR",       505e16,  1000, 500, 250, 1000e18);
    }
}
