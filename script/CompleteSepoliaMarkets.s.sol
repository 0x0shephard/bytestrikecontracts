// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CuOracle} from "../src/Oracle/CuOracle.sol";
import {CuOracleAdapter} from "../src/Oracle/CuOracleAdapter.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {vAMM} from "../src/vAMM.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";
import {ICollateralVault} from "../src/Interfaces/ICollateralVault.sol";
import {IMarketRegistry} from "../src/Interfaces/IMarketRegistry.sol";

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @notice Phase A: repair/complete Sepolia market registration and recommit prices.
/// @dev Run this first, wait at least one block, then run CompleteSepoliaMarketsSeed.
contract CompleteSepoliaMarkets is Script {
    address constant CU_ORACLE      = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address constant REGISTRY       = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address constant CH             = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address constant USDC           = 0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE;
    address constant FEE_ROUTER     = 0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e;
    address constant INSURANCE_FUND = 0x132Ba3d3073FDa7440fb0594210C47eC19087eaD;
    address constant VAMM_IMPL      = 0xC943C963DAFc8043E349a9191D4c567f2CB693AA;
    address constant DUMMY_BASE     = 0x0000000000000000000000000000000000000001;

    uint256 constant INITIAL_BASE_RESERVE = 10_000e18;
    uint128 constant LIQUIDITY = 1e24;
    uint16 constant FEE_BPS = 10;
    uint256 constant FR_MAX_BPS_PER_HOUR = 100;
    uint256 constant K_FUNDING_X18 = 1e18;
    uint256 constant CU_ORACLE_MAX_AGE = 12 hours;

    struct Spec {
        string name;
        string assetSymbol;
        uint256 priceX18;
        uint256 imrBps;
        uint256 mmrBps;
        uint256 liqPenaltyBps;
        uint256 penaltyCap;
        bool replacement;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        require(nonceBase != bytes32(0), "NONCE_BASE=0");

        Spec[] memory specs = _buildSpecs();

        vm.startBroadcast(deployerPk);

        _pauseBrokenOriginals();

        for (uint256 i = 0; i < specs.length; i++) {
            _prepareMarket(specs[i], nonceBase);
        }

        vm.stopBroadcast();

        console.log("Phase A complete: markets registered/paused and oracle prices committed.");
        console.log("Wait at least one Sepolia block, then run CompleteSepoliaMarketsSeed.");
    }

    function _pauseBrokenOriginals() internal {
        _pauseIfBroken("B200-PERP");
        _pauseIfBroken("H200-PERP");
        _pauseIfBroken("H100-non-HyperScalers-PERP");
    }

    function _pauseIfBroken(string memory name) internal {
        bytes32 marketId = keccak256(bytes(name));
        IMarketRegistry.Market memory market = MarketRegistry(REGISTRY).getMarket(marketId);
        if (market.vamm == address(0)) return;
        if (_hasCode(market.vamm)) return;
        console.log("Broken market cannot be paused through registry:", name);
    }

    function _prepareMarket(Spec memory spec, bytes32 nonceBase) internal {
        bytes32 marketId = keccak256(bytes(spec.name));
        bytes32 assetId = keccak256(bytes(spec.assetSymbol));

        IMarketRegistry.Market memory existing = MarketRegistry(REGISTRY).getMarket(marketId);
        bool exists = existing.vamm != address(0);

        if (exists) {
            require(_hasCode(existing.vamm), "existing vAMM has no code");
            if (!existing.paused) {
                MarketRegistry(REGISTRY).pauseMarket(marketId, true);
            }
        } else {
            _registerAssetIfNeeded(assetId);
            address adapter = address(new CuOracleAdapter(CU_ORACLE, assetId, CU_ORACLE_MAX_AGE));
            address vammProxy = _deployVamm(adapter, spec.priceX18);
            vAMM(vammProxy).setRegistry(REGISTRY);

            MarketRegistry(REGISTRY).addMarket(IMarketRegistry.AddMarketConfig({
                marketId: marketId,
                vamm: vammProxy,
                oracle: adapter,
                baseAsset: DUMMY_BASE,
                quoteToken: USDC,
                baseUnit: 1e18,
                feeBps: FEE_BPS,
                feeRouter: FEE_ROUTER,
                insuranceFund: INSURANCE_FUND
            }));
            MarketRegistry(REGISTRY).pauseMarket(marketId, true);
            ClearingHouse(payable(CH)).setRiskParams(
                marketId,
                spec.imrBps,
                spec.mmrBps,
                spec.liqPenaltyBps,
                spec.penaltyCap,
                0,
                0
            );
            console.log("Registered market:", spec.name);
        }

        bytes32 nonce = _nonce(nonceBase, marketId, assetId);
        CuOracle(CU_ORACLE).commitPrice(assetId, keccak256(abi.encodePacked(spec.priceX18, nonce)));
        console.log("Committed price:", spec.name);
    }

    function _registerAssetIfNeeded(bytes32 assetId) internal {
        if (!CuOracle(CU_ORACLE).supportedAssets(assetId)) {
            CuOracle(CU_ORACLE).registerAsset(assetId);
        }
    }

    function _deployVamm(address adapter, uint256 priceX18) internal returns (address) {
        bytes memory init = abi.encodeCall(
            vAMM.initialize,
            (CH, adapter, priceX18, INITIAL_BASE_RESERVE, LIQUIDITY, FEE_BPS, FR_MAX_BPS_PER_HOUR, K_FUNDING_X18)
        );
        return address(new ERC1967Proxy(VAMM_IMPL, init));
    }

    function _hasCode(address target) internal view returns (bool ok) {
        uint256 size;
        assembly {
            size := extcodesize(target)
        }
        ok = size > 0;
    }

    function _nonce(bytes32 nonceBase, bytes32 marketId, bytes32 assetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, marketId, assetId, "bytestrike-sepolia-complete-v1"));
    }

    function _buildSpecs() internal pure returns (Spec[] memory s) {
        s = new Spec[](19);
        s[0] = Spec("A100-PERP", "A100", 176e16, 1000, 500, 250, 1000e18, false);
        s[1] = Spec("AWS-H100-PERP", "AWS-H100", 385e16, 1000, 500, 250, 1000e18, false);
        s[2] = Spec("AWS-H200-PERP", "AWS-H200", 404e16, 1000, 500, 250, 1000e18, false);
        s[3] = Spec("AZURE-H100-PERP", "AZURE-H100", 212e16, 1000, 500, 250, 1000e18, false);
        s[4] = Spec("COREWEAVE-H200-PERP", "COREWEAVE-H200", 1453e16, 1000, 500, 250, 1000e18, false);
        s[5] = Spec("GCP-H100-PERP", "GCP-H100", 388e16, 1000, 500, 250, 1000e18, false);
        s[6] = Spec("GCP-H200-PERP", "GCP-H200", 660e16, 1000, 500, 250, 1000e18, false);
        s[7] = Spec("ORACLE-H200-PERP", "ORACLE-H200", 647e16, 1000, 500, 250, 1000e18, false);
        s[8] = Spec("T4-PERP", "T4", 45e16, 1000, 500, 250, 1000e18, false);
        s[9] = Spec("H100-GPU-PERP", "H100-GPU", 375e16, 1000, 250, 200, 10000e18, false);
        s[10] = Spec("H100-HyperScalers-PERP", "H100-HyperScalers", 420e16, 1000, 500, 250, 1000e18, false);
        s[11] = Spec("ORACLE-H200-PERPETUAL", "ORACLE_H200_HOUR", 292e16, 1000, 500, 250, 1000e18, false);
        s[12] = Spec("AWS-H200-PERPETUAL", "AWS_H200_HOUR", 265e16, 1000, 500, 250, 1000e18, false);
        s[13] = Spec("COREWEAVE-H200-PERPETUAL", "COREWEAVE_H200_HOUR", 257e16, 1000, 500, 250, 1000e18, false);
        s[14] = Spec("GCP-H200-PERPETUAL", "GCP_H200_HOUR", 455e16, 1000, 500, 250, 1000e18, false);
        s[15] = Spec("AZURE-H200-PERPETUAL", "AZURE_H200_HOUR", 505e16, 1000, 500, 250, 1000e18, false);
        s[16] = Spec("B200-PERP-V2", "B200", 715e16, 1000, 500, 250, 1000e18, true);
        s[17] = Spec("H200-PERP-V2", "H200", 353e16, 1000, 500, 250, 1000e18, true);
        s[18] = Spec("H100-non-HyperScalers-PERP-V2", "H100-non-HyperScalers", 295e16, 1000, 500, 250, 1000e18, true);
    }
}

/// @notice Phase B: reveal prices, seed balanced OI, and unpause the completed markets.
contract CompleteSepoliaMarketsSeed is Script {
    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address constant REGISTRY = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address constant CH = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address constant USDC = 0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE;
    address constant VAULT = 0x44345dFCD97973329A88aaE8c1432ea90525Ed13;
    bytes32 constant H100_ASSET_ID = keccak256("H100");
    uint256 constant H100_PRICE_X18 = 422e16;

    uint128 constant SEED_SIZE = 100e18;
    uint256 constant SEED_MARGIN_X18 = 300e18;
    uint256 constant DEPOSIT_USDC = 10_000e6;
    uint256 constant LONG_MAX_BPS = 11_000;
    uint256 constant SHORT_MIN_BPS = 8_500;
    uint256 constant BPS = 10_000;

    struct SeedSpec {
        string name;
        string assetSymbol;
        uint256 priceX18;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 seedLongPk = vm.envUint("SEED_LONG_PK");
        uint256 seedShortPk = vm.envUint("SEED_SHORT_PK");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        require(nonceBase != bytes32(0), "NONCE_BASE=0");

        SeedSpec[] memory specs = _buildSpecs();

        vm.startBroadcast(deployerPk);
        CuOracle(CU_ORACLE).updatePrices(H100_ASSET_ID, H100_PRICE_X18, _h100Nonce(nonceBase));
        for (uint256 i = 0; i < specs.length; i++) {
            bytes32 marketId = keccak256(bytes(specs[i].name));
            bytes32 assetId = keccak256(bytes(specs[i].assetSymbol));
            CuOracle(CU_ORACLE).updatePrices(assetId, specs[i].priceX18, _nonce(nonceBase, marketId, assetId));
        }
        vm.stopBroadcast();
        console.log("Prices revealed.");

        vm.startBroadcast(seedLongPk);
        IERC20(USDC).approve(VAULT, DEPOSIT_USDC);
        ClearingHouse(payable(CH)).deposit(USDC, DEPOSIT_USDC);
        vm.stopBroadcast();

        vm.startBroadcast(seedShortPk);
        IERC20(USDC).approve(VAULT, DEPOSIT_USDC);
        ClearingHouse(payable(CH)).deposit(USDC, DEPOSIT_USDC);
        vm.stopBroadcast();

        for (uint256 i = 0; i < specs.length; i++) {
            _seedOne(specs[i], deployerPk, seedLongPk, seedShortPk);
        }

        console.log("Phase B complete: markets seeded and unpaused.");
    }

    function _seedOne(SeedSpec memory spec, uint256 deployerPk, uint256 seedLongPk, uint256 seedShortPk) internal {
        bytes32 marketId = keccak256(bytes(spec.name));
        uint256 notional = (uint256(SEED_SIZE) * spec.priceX18) / 1e18;
        uint256 maxQuoteIn = (notional * LONG_MAX_BPS) / BPS;
        uint256 minQuoteOut = (notional * SHORT_MIN_BPS) / BPS;

        vm.startBroadcast(deployerPk);
        MarketRegistry(REGISTRY).pauseMarket(marketId, false);
        vm.stopBroadcast();

        vm.startBroadcast(seedLongPk);
        ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
        ClearingHouse(payable(CH)).openPosition(marketId, true, SEED_SIZE, maxQuoteIn);
        vm.stopBroadcast();

        vm.startBroadcast(seedShortPk);
        ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
        ClearingHouse(payable(CH)).openPosition(marketId, false, SEED_SIZE, minQuoteOut);
        vm.stopBroadcast();

        console.log("Seeded:", spec.name);
    }

    function _nonce(bytes32 nonceBase, bytes32 marketId, bytes32 assetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, marketId, assetId, "bytestrike-sepolia-complete-v1"));
    }

    function _h100Nonce(bytes32 nonceBase) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, H100_ASSET_ID, "bytestrike-sepolia-h100-refresh-v1"));
    }

    function _buildSpecs() internal pure returns (SeedSpec[] memory s) {
        s = new SeedSpec[](19);
        s[0] = SeedSpec("A100-PERP", "A100", 176e16);
        s[1] = SeedSpec("AWS-H100-PERP", "AWS-H100", 385e16);
        s[2] = SeedSpec("AWS-H200-PERP", "AWS-H200", 404e16);
        s[3] = SeedSpec("AZURE-H100-PERP", "AZURE-H100", 212e16);
        s[4] = SeedSpec("COREWEAVE-H200-PERP", "COREWEAVE-H200", 1453e16);
        s[5] = SeedSpec("GCP-H100-PERP", "GCP-H100", 388e16);
        s[6] = SeedSpec("GCP-H200-PERP", "GCP-H200", 660e16);
        s[7] = SeedSpec("ORACLE-H200-PERP", "ORACLE-H200", 647e16);
        s[8] = SeedSpec("T4-PERP", "T4", 45e16);
        s[9] = SeedSpec("H100-GPU-PERP", "H100-GPU", 375e16);
        s[10] = SeedSpec("H100-HyperScalers-PERP", "H100-HyperScalers", 420e16);
        s[11] = SeedSpec("ORACLE-H200-PERPETUAL", "ORACLE_H200_HOUR", 292e16);
        s[12] = SeedSpec("AWS-H200-PERPETUAL", "AWS_H200_HOUR", 265e16);
        s[13] = SeedSpec("COREWEAVE-H200-PERPETUAL", "COREWEAVE_H200_HOUR", 257e16);
        s[14] = SeedSpec("GCP-H200-PERPETUAL", "GCP_H200_HOUR", 455e16);
        s[15] = SeedSpec("AZURE-H200-PERPETUAL", "AZURE_H200_HOUR", 505e16);
        s[16] = SeedSpec("B200-PERP-V2", "B200", 715e16);
        s[17] = SeedSpec("H200-PERP-V2", "H200", 353e16);
        s[18] = SeedSpec("H100-non-HyperScalers-PERP-V2", "H100-non-HyperScalers", 295e16);
    }
}

/// @notice Targeted recommit for the final replacement market if a partial broadcast
/// dropped its CuOracle commit.
contract CommitH100NonHyperScalersV2 is Script {
    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    bytes32 constant MARKET_ID = keccak256("H100-non-HyperScalers-PERP-V2");
    bytes32 constant ASSET_ID = keccak256("H100-non-HyperScalers");
    uint256 constant PRICE_X18 = 295e16;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        bytes32 nonce = keccak256(abi.encode(nonceBase, MARKET_ID, ASSET_ID, "bytestrike-sepolia-complete-v1"));
        bytes32 commitment = keccak256(abi.encodePacked(PRICE_X18, nonce));

        vm.startBroadcast(deployerPk);
        CuOracle(CU_ORACLE).commitPrice(ASSET_ID, commitment);
        vm.stopBroadcast();
    }
}

/// @notice Refreshes the original H100 oracle so seed wallets with existing
/// H100-PERP positions can settle funding while new markets are seeded.
contract CommitH100Refresh is Script {
    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    bytes32 constant H100_ASSET_ID = keccak256("H100");
    uint256 constant H100_PRICE_X18 = 422e16;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        bytes32 nonce = keccak256(abi.encode(nonceBase, H100_ASSET_ID, "bytestrike-sepolia-h100-refresh-v1"));
        bytes32 commitment = keccak256(abi.encodePacked(H100_PRICE_X18, nonce));

        vm.startBroadcast(deployerPk);
        CuOracle(CU_ORACLE).commitPrice(H100_ASSET_ID, commitment);
        vm.stopBroadcast();
    }
}

/// @notice Recommits original H100 plus every completed market price in one short pass.
contract CommitAllSepoliaPrices is Script {
    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    bytes32 constant H100_ASSET_ID = keccak256("H100");
    uint256 constant H100_PRICE_X18 = 422e16;

    struct SeedSpec {
        string name;
        string assetSymbol;
        uint256 priceX18;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        SeedSpec[] memory specs = _buildSpecs();

        vm.startBroadcast(deployerPk);
        _commit(H100_ASSET_ID, H100_PRICE_X18, _h100Nonce(nonceBase));
        for (uint256 i = 0; i < specs.length; i++) {
            bytes32 marketId = keccak256(bytes(specs[i].name));
            bytes32 assetId = keccak256(bytes(specs[i].assetSymbol));
            _commit(assetId, specs[i].priceX18, _nonce(nonceBase, marketId, assetId));
        }
        vm.stopBroadcast();
    }

    function _commit(bytes32 assetId, uint256 priceX18, bytes32 nonce) internal {
        CuOracle(CU_ORACLE).commitPrice(assetId, keccak256(abi.encodePacked(priceX18, nonce)));
    }

    function _nonce(bytes32 nonceBase, bytes32 marketId, bytes32 assetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, marketId, assetId, "bytestrike-sepolia-complete-v1"));
    }

    function _h100Nonce(bytes32 nonceBase) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, H100_ASSET_ID, "bytestrike-sepolia-h100-refresh-v1"));
    }

    function _buildSpecs() internal pure returns (SeedSpec[] memory s) {
        s = new SeedSpec[](19);
        s[0] = SeedSpec("A100-PERP", "A100", 176e16);
        s[1] = SeedSpec("AWS-H100-PERP", "AWS-H100", 385e16);
        s[2] = SeedSpec("AWS-H200-PERP", "AWS-H200", 404e16);
        s[3] = SeedSpec("AZURE-H100-PERP", "AZURE-H100", 212e16);
        s[4] = SeedSpec("COREWEAVE-H200-PERP", "COREWEAVE-H200", 1453e16);
        s[5] = SeedSpec("GCP-H100-PERP", "GCP-H100", 388e16);
        s[6] = SeedSpec("GCP-H200-PERP", "GCP-H200", 660e16);
        s[7] = SeedSpec("ORACLE-H200-PERP", "ORACLE-H200", 647e16);
        s[8] = SeedSpec("T4-PERP", "T4", 45e16);
        s[9] = SeedSpec("H100-GPU-PERP", "H100-GPU", 375e16);
        s[10] = SeedSpec("H100-HyperScalers-PERP", "H100-HyperScalers", 420e16);
        s[11] = SeedSpec("ORACLE-H200-PERPETUAL", "ORACLE_H200_HOUR", 292e16);
        s[12] = SeedSpec("AWS-H200-PERPETUAL", "AWS_H200_HOUR", 265e16);
        s[13] = SeedSpec("COREWEAVE-H200-PERPETUAL", "COREWEAVE_H200_HOUR", 257e16);
        s[14] = SeedSpec("GCP-H200-PERPETUAL", "GCP_H200_HOUR", 455e16);
        s[15] = SeedSpec("AZURE-H200-PERPETUAL", "AZURE_H200_HOUR", 505e16);
        s[16] = SeedSpec("B200-PERP-V2", "B200", 715e16);
        s[17] = SeedSpec("H200-PERP-V2", "H200", 353e16);
        s[18] = SeedSpec("H100-non-HyperScalers-PERP-V2", "H100-non-HyperScalers", 295e16);
    }
}

abstract contract SepoliaSeedBase is Script {
    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address constant REGISTRY = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address constant CH = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address constant USDC = 0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE;
    address constant VAULT = 0x44345dFCD97973329A88aaE8c1432ea90525Ed13;
    bytes32 constant H100_ASSET_ID = keccak256("H100");
    uint256 constant H100_PRICE_X18 = 422e16;

    uint128 constant SEED_SIZE = 100e18;
    uint256 constant SEED_MARGIN_X18 = 300e18;
    uint256 constant TARGET_SEED_COLLATERAL_X18 = 10_000e18;
    uint256 constant LONG_MAX_BPS = 11_000;
    uint256 constant SHORT_MIN_BPS = 8_500;
    uint256 constant BPS = 10_000;

    struct SeedSpec {
        string name;
        string assetSymbol;
        uint256 priceX18;
    }

    function _revealAll(bytes32 nonceBase) internal {
        SeedSpec[] memory specs = _buildSpecs();
        CuOracle(CU_ORACLE).updatePrices(H100_ASSET_ID, H100_PRICE_X18, _h100Nonce(nonceBase));
        for (uint256 i = 0; i < specs.length; i++) {
            bytes32 marketId = keccak256(bytes(specs[i].name));
            bytes32 assetId = keccak256(bytes(specs[i].assetSymbol));
            CuOracle(CU_ORACLE).updatePrices(assetId, specs[i].priceX18, _nonce(nonceBase, marketId, assetId));
        }
    }

    function _ensureSeedDeposit() internal {
        uint256 currentX18 = ICollateralVault(VAULT).getTokenValueX18(
            USDC,
            ICollateralVault(VAULT).balanceOf(msg.sender, USDC)
        );
        if (currentX18 >= TARGET_SEED_COLLATERAL_X18) return;

        uint256 shortfallX18 = TARGET_SEED_COLLATERAL_X18 - currentX18;
        uint256 depositAmount = (shortfallX18 * 1e6) / 1e18;
        if (depositAmount == 0) depositAmount = 1;

        IERC20(USDC).approve(VAULT, depositAmount);
        ClearingHouse(payable(CH)).deposit(USDC, depositAmount);
    }

    function _seedRange(uint256 start, uint256 end, uint256 deployerPk, uint256 seedLongPk, uint256 seedShortPk) internal {
        SeedSpec[] memory specs = _buildSpecs();
        if (end > specs.length) end = specs.length;

        for (uint256 i = start; i < end; i++) {
            _seedOne(specs[i], deployerPk, seedLongPk, seedShortPk);
        }
    }

    function _seedOne(SeedSpec memory spec, uint256 deployerPk, uint256 seedLongPk, uint256 seedShortPk) internal {
        bytes32 marketId = keccak256(bytes(spec.name));
        uint256 notional = (uint256(SEED_SIZE) * spec.priceX18) / 1e18;
        uint256 maxQuoteIn = (notional * LONG_MAX_BPS) / BPS;
        uint256 minQuoteOut = (notional * SHORT_MIN_BPS) / BPS;
        address seedLong = vm.addr(seedLongPk);
        address seedShort = vm.addr(seedShortPk);

        vm.startBroadcast(deployerPk);
        if (!MarketRegistry(REGISTRY).isActive(marketId)) {
            MarketRegistry(REGISTRY).pauseMarket(marketId, false);
        }
        vm.stopBroadcast();

        IClearingHouse.PositionView memory longPos = ClearingHouse(payable(CH)).getPosition(seedLong, marketId);
        if (longPos.size == 0) {
            vm.startBroadcast(seedLongPk);
            ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
            ClearingHouse(payable(CH)).openPosition(marketId, true, SEED_SIZE, maxQuoteIn);
            vm.stopBroadcast();
        }

        IClearingHouse.PositionView memory shortPos = ClearingHouse(payable(CH)).getPosition(seedShort, marketId);
        if (shortPos.size == 0) {
            vm.startBroadcast(seedShortPk);
            ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
            ClearingHouse(payable(CH)).openPosition(marketId, false, SEED_SIZE, minQuoteOut);
            vm.stopBroadcast();
        }

        console.log("Seeded/skipped:", spec.name);
    }

    function _nonce(bytes32 nonceBase, bytes32 marketId, bytes32 assetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, marketId, assetId, "bytestrike-sepolia-complete-v1"));
    }

    function _h100Nonce(bytes32 nonceBase) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, H100_ASSET_ID, "bytestrike-sepolia-h100-refresh-v1"));
    }

    function _buildSpecs() internal pure returns (SeedSpec[] memory s) {
        s = new SeedSpec[](19);
        s[0] = SeedSpec("A100-PERP", "A100", 176e16);
        s[1] = SeedSpec("AWS-H100-PERP", "AWS-H100", 385e16);
        s[2] = SeedSpec("AWS-H200-PERP", "AWS-H200", 404e16);
        s[3] = SeedSpec("AZURE-H100-PERP", "AZURE-H100", 212e16);
        s[4] = SeedSpec("COREWEAVE-H200-PERP", "COREWEAVE-H200", 1453e16);
        s[5] = SeedSpec("GCP-H100-PERP", "GCP-H100", 388e16);
        s[6] = SeedSpec("GCP-H200-PERP", "GCP-H200", 660e16);
        s[7] = SeedSpec("ORACLE-H200-PERP", "ORACLE-H200", 647e16);
        s[8] = SeedSpec("T4-PERP", "T4", 45e16);
        s[9] = SeedSpec("H100-GPU-PERP", "H100-GPU", 375e16);
        s[10] = SeedSpec("H100-HyperScalers-PERP", "H100-HyperScalers", 420e16);
        s[11] = SeedSpec("ORACLE-H200-PERPETUAL", "ORACLE_H200_HOUR", 292e16);
        s[12] = SeedSpec("AWS-H200-PERPETUAL", "AWS_H200_HOUR", 265e16);
        s[13] = SeedSpec("COREWEAVE-H200-PERPETUAL", "COREWEAVE_H200_HOUR", 257e16);
        s[14] = SeedSpec("GCP-H200-PERPETUAL", "GCP_H200_HOUR", 455e16);
        s[15] = SeedSpec("AZURE-H200-PERPETUAL", "AZURE_H200_HOUR", 505e16);
        s[16] = SeedSpec("B200-PERP-V2", "B200", 715e16);
        s[17] = SeedSpec("H200-PERP-V2", "H200", 353e16);
        s[18] = SeedSpec("H100-non-HyperScalers-PERP-V2", "H100-non-HyperScalers", 295e16);
    }
}

contract SeedSepoliaMarketFreshByIndex is SepoliaSeedBase {
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 constant GAS_FLOAT = 0.00001 ether;

    function run() external {
        uint256 index = vm.envUint("SEED_INDEX");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");

        SeedSpec[] memory specs = _buildSpecs();
        require(index < specs.length, "bad index");

        SeedSpec memory spec = specs[index];
        bytes32 marketId = keccak256(bytes(spec.name));
        IMarketRegistry.Market memory market = MarketRegistry(REGISTRY).getMarket(marketId);
        require(market.vamm != address(0), "missing market");

        if (vAMM(market.vamm).totalLongOI() >= SEED_SIZE && vAMM(market.vamm).totalShortOI() >= SEED_SIZE) {
            console.log("Already seeded:", spec.name);
            return;
        }

        uint256 freshLongPk = _freshPk(nonceBase, index, true);
        uint256 freshShortPk = _freshPk(nonceBase, index, false);
        address freshLong = vm.addr(freshLongPk);
        address freshShort = vm.addr(freshShortPk);

        vm.startBroadcast(deployerPk);
        _fundFreshWallet(freshLong);
        _fundFreshWallet(freshShort);
        if (!MarketRegistry(REGISTRY).isActive(marketId)) {
            MarketRegistry(REGISTRY).pauseMarket(marketId, false);
        }
        vm.stopBroadcast();

        uint256 notional = (uint256(SEED_SIZE) * spec.priceX18) / 1e18;
        uint256 maxQuoteIn = (notional * LONG_MAX_BPS) / BPS;
        uint256 minQuoteOut = (notional * SHORT_MIN_BPS) / BPS;

        if (vAMM(market.vamm).totalLongOI() < SEED_SIZE) {
            vm.startBroadcast(freshLongPk);
            _ensureSeedDeposit();
            ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
            ClearingHouse(payable(CH)).openPosition(marketId, true, SEED_SIZE, maxQuoteIn);
            vm.stopBroadcast();
        }

        if (vAMM(market.vamm).totalShortOI() < SEED_SIZE) {
            vm.startBroadcast(freshShortPk);
            _ensureSeedDeposit();
            ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
            ClearingHouse(payable(CH)).openPosition(marketId, false, SEED_SIZE, minQuoteOut);
            vm.stopBroadcast();
        }

        console.log("Fresh seeded:", spec.name);
        console.log("  long:", freshLong);
        console.log("  short:", freshShort);
    }

    function _fundFreshWallet(address wallet) internal {
        if (wallet.balance < GAS_FLOAT) {
            (bool ok,) = payable(wallet).call{value: GAS_FLOAT - wallet.balance}("");
            require(ok, "eth fund failed");
        }
        if (IERC20(USDC).balanceOf(wallet) < 10_000e6) {
            IMintableERC20(USDC).mint(wallet, 10_000e6);
        }
    }

    function _freshPk(bytes32 nonceBase, uint256 index, bool isLong) internal pure returns (uint256) {
        uint256 raw = uint256(keccak256(abi.encode(nonceBase, index, isLong, "bytestrike-sepolia-fresh-seed-v1")));
        return (raw % (SECP256K1_N - 1)) + 1;
    }
}

contract RevealSepoliaPrices is SepoliaSeedBase {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");

        vm.startBroadcast(deployerPk);
        _revealAll(nonceBase);
        vm.stopBroadcast();
    }
}

contract RevealSepoliaReplacementPrices is SepoliaSeedBase {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");

        vm.startBroadcast(deployerPk);
        _revealOne(nonceBase, "B200-PERP-V2", "B200", 715e16);
        _revealOne(nonceBase, "H200-PERP-V2", "H200", 353e16);
        _revealOne(nonceBase, "H100-non-HyperScalers-PERP-V2", "H100-non-HyperScalers", 295e16);
        vm.stopBroadcast();
    }

    function _revealOne(bytes32 nonceBase, string memory marketName, string memory assetSymbol, uint256 priceX18) internal {
        bytes32 marketId = keccak256(bytes(marketName));
        bytes32 assetId = keccak256(bytes(assetSymbol));
        CuOracle(CU_ORACLE).updatePrices(assetId, priceX18, _nonce(nonceBase, marketId, assetId));
    }
}

contract CommitRemainingSepoliaPrices is Script {
    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;

    struct SeedSpec {
        string name;
        string assetSymbol;
        uint256 priceX18;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        SeedSpec[5] memory specs = _remainingSpecs();

        vm.startBroadcast(deployerPk);
        for (uint256 i = 0; i < specs.length; i++) {
            bytes32 marketId = keccak256(bytes(specs[i].name));
            bytes32 assetId = keccak256(bytes(specs[i].assetSymbol));
            bytes32 nonce = _nonce(nonceBase, marketId, assetId);
            CuOracle(CU_ORACLE).commitPrice(assetId, keccak256(abi.encodePacked(specs[i].priceX18, nonce)));
        }
        vm.stopBroadcast();
    }

    function _remainingSpecs() internal pure returns (SeedSpec[5] memory s) {
        s[0] = SeedSpec("GCP-H200-PERPETUAL", "GCP_H200_HOUR", 455e16);
        s[1] = SeedSpec("AZURE-H200-PERPETUAL", "AZURE_H200_HOUR", 505e16);
        s[2] = SeedSpec("B200-PERP-V2", "B200", 715e16);
        s[3] = SeedSpec("H200-PERP-V2", "H200", 353e16);
        s[4] = SeedSpec("H100-non-HyperScalers-PERP-V2", "H100-non-HyperScalers", 295e16);
    }

    function _nonce(bytes32 nonceBase, bytes32 marketId, bytes32 assetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, marketId, assetId, "bytestrike-sepolia-complete-v1"));
    }
}

contract RevealRemainingSepoliaPrices is Script {
    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;

    struct SeedSpec {
        string name;
        string assetSymbol;
        uint256 priceX18;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        SeedSpec[5] memory specs = _remainingSpecs();

        vm.startBroadcast(deployerPk);
        for (uint256 i = 0; i < specs.length; i++) {
            bytes32 marketId = keccak256(bytes(specs[i].name));
            bytes32 assetId = keccak256(bytes(specs[i].assetSymbol));
            CuOracle(CU_ORACLE).updatePrices(assetId, specs[i].priceX18, _nonce(nonceBase, marketId, assetId));
        }
        vm.stopBroadcast();
    }

    function _remainingSpecs() internal pure returns (SeedSpec[5] memory s) {
        s[0] = SeedSpec("GCP-H200-PERPETUAL", "GCP_H200_HOUR", 455e16);
        s[1] = SeedSpec("AZURE-H200-PERPETUAL", "AZURE_H200_HOUR", 505e16);
        s[2] = SeedSpec("B200-PERP-V2", "B200", 715e16);
        s[3] = SeedSpec("H200-PERP-V2", "H200", 353e16);
        s[4] = SeedSpec("H100-non-HyperScalers-PERP-V2", "H100-non-HyperScalers", 295e16);
    }

    function _nonce(bytes32 nonceBase, bytes32 marketId, bytes32 assetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, marketId, assetId, "bytestrike-sepolia-complete-v1"));
    }
}

contract PrepareSepoliaSeedWallets is SepoliaSeedBase {
    function run() external {
        uint256 seedLongPk = vm.envUint("SEED_LONG_PK");
        uint256 seedShortPk = vm.envUint("SEED_SHORT_PK");

        vm.startBroadcast(seedLongPk);
        _ensureSeedDeposit();
        vm.stopBroadcast();

        vm.startBroadcast(seedShortPk);
        _ensureSeedDeposit();
        vm.stopBroadcast();
    }
}

contract SeedSepoliaMarkets0_5 is SepoliaSeedBase {
    function run() external {
        _seedRange(0, 5, vm.envUint("PRIVATE_KEY"), vm.envUint("SEED_LONG_PK"), vm.envUint("SEED_SHORT_PK"));
    }
}

contract SeedSepoliaMarketByIndex is SepoliaSeedBase {
    function run() external {
        uint256 index = vm.envUint("SEED_INDEX");
        _seedRange(index, index + 1, vm.envUint("PRIVATE_KEY"), vm.envUint("SEED_LONG_PK"), vm.envUint("SEED_SHORT_PK"));
    }
}

contract SeedSepoliaMarkets5_10 is SepoliaSeedBase {
    function run() external {
        _seedRange(5, 10, vm.envUint("PRIVATE_KEY"), vm.envUint("SEED_LONG_PK"), vm.envUint("SEED_SHORT_PK"));
    }
}

contract SeedSepoliaMarkets10_15 is SepoliaSeedBase {
    function run() external {
        _seedRange(10, 15, vm.envUint("PRIVATE_KEY"), vm.envUint("SEED_LONG_PK"), vm.envUint("SEED_SHORT_PK"));
    }
}

contract SeedSepoliaMarkets15_19 is SepoliaSeedBase {
    function run() external {
        _seedRange(15, 19, vm.envUint("PRIVATE_KEY"), vm.envUint("SEED_LONG_PK"), vm.envUint("SEED_SHORT_PK"));
    }
}
