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

interface IMintableToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

abstract contract B200ProviderBase is Script {
    address constant CU_ORACLE = 0x97f557594bA32e51c0eA215B1886111F24E957af;
    address constant REGISTRY = 0x236b75D39203506ee3180Ef2E1c7460a188C43c6;
    address constant CH = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    address constant USDC = 0x947Cc17D8CbC0Fc1E64de138eE4947d3AF9C26EE;
    address constant VAULT = 0x44345dFCD97973329A88aaE8c1432ea90525Ed13;
    address constant FEE_ROUTER = 0xBCEA366b30eb1dcAC6968AECcc215E8797553a5e;
    address constant INSURANCE_FUND = 0x132Ba3d3073FDa7440fb0594210C47eC19087eaD;
    address constant VAMM_IMPL = 0xC943C963DAFc8043E349a9191D4c567f2CB693AA;
    address constant DUMMY_BASE = 0x0000000000000000000000000000000000000001;

    uint256 constant INITIAL_BASE_RESERVE = 10_000e18;
    uint128 constant LIQUIDITY = 1e24;
    uint16 constant FEE_BPS = 10;
    uint256 constant FR_MAX_BPS_PER_HOUR = 100;
    uint256 constant K_FUNDING_X18 = 1e18;
    uint256 constant CU_ORACLE_MAX_AGE = 12 hours;

    uint128 constant SEED_SIZE = 100e18;
    uint256 constant SEED_MARGIN_X18 = 300e18;
    uint256 constant TARGET_SEED_COLLATERAL_X18 = 10_000e18;
    uint256 constant SEED_TOKEN_BUFFER = 10_000e6;
    uint256 constant GAS_FLOAT = 0.00002 ether;
    uint256 constant LONG_MAX_BPS = 11_000;
    uint256 constant SHORT_MIN_BPS = 8_500;
    uint256 constant BPS = 10_000;
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    struct Spec {
        string name;
        string assetSymbol;
        uint256 priceX18;
        uint256 imrBps;
        uint256 mmrBps;
        uint256 liqPenaltyBps;
        uint256 penaltyCap;
    }

    function _buildSpecs() internal pure returns (Spec[] memory s) {
        s = new Spec[](4);
        s[0] = Spec("AWS-B200-PERP", "AWS-B200", 3874294322165306000, 1000, 500, 250, 1000e18);
        s[1] = Spec("ORACLE-B200-PERP", "ORACLE-B200", 14e18, 1000, 500, 250, 1000e18);
        s[2] = Spec("COREWEAVE-B200-PERP", "COREWEAVE-B200", 18080284968793100000, 1000, 500, 250, 1000e18);
        s[3] = Spec("GCP-B200-PERP", "GCP-B200", 7282373090652320000, 1000, 500, 250, 1000e18);
    }

    function _nonce(bytes32 nonceBase, bytes32 marketId, bytes32 assetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonceBase, marketId, assetId, "bytestrike-sepolia-b200-provider-v1"));
    }

    function _hasCode(address target) internal view returns (bool ok) {
        uint256 size;
        assembly {
            size := extcodesize(target)
        }
        ok = size > 0;
    }
}

contract DeployB200ProviderMarkets is B200ProviderBase {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        require(nonceBase != bytes32(0), "NONCE_BASE=0");

        Spec[] memory specs = _buildSpecs();
        bytes32[] memory marketIds = new bytes32[](specs.length);
        bytes32[] memory assetIds = new bytes32[](specs.length);
        bytes32[] memory nonces = new bytes32[](specs.length);
        address[] memory adapters = new address[](specs.length);
        address[] memory vamms = new address[](specs.length);

        vm.startBroadcast(deployerPk);
        for (uint256 i = 0; i < specs.length; i++) {
            (marketIds[i], assetIds[i], nonces[i], adapters[i], vamms[i]) = _prepareOne(specs[i], nonceBase);
        }
        vm.stopBroadcast();

        _writeArtifacts(specs, marketIds, assetIds, nonces, adapters, vamms);
        console.log("B200 provider phase A complete. Wait one block, then run SeedB200ProviderMarkets.");
    }

    function _prepareOne(Spec memory spec, bytes32 nonceBase)
        internal
        returns (bytes32 marketId, bytes32 assetId, bytes32 nonce, address adapter, address vammProxy)
    {
        marketId = keccak256(bytes(spec.name));
        assetId = keccak256(bytes(spec.assetSymbol));
        nonce = _nonce(nonceBase, marketId, assetId);

        IMarketRegistry.Market memory existing = MarketRegistry(REGISTRY).getMarket(marketId);
        if (existing.vamm == address(0)) {
            if (!CuOracle(CU_ORACLE).supportedAssets(assetId)) {
                CuOracle(CU_ORACLE).registerAsset(assetId);
            }

            adapter = address(new CuOracleAdapter(CU_ORACLE, assetId, CU_ORACLE_MAX_AGE));
            vammProxy = _deployVamm(adapter, spec.priceX18);
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
            console.log("Registered:", spec.name);
        } else {
            require(_hasCode(existing.vamm), "existing vAMM has no code");
            adapter = existing.oracle;
            vammProxy = existing.vamm;
            if (!existing.paused) {
                MarketRegistry(REGISTRY).pauseMarket(marketId, true);
            }
            console.log("Exists:", spec.name);
        }

        CuOracle(CU_ORACLE).commitPrice(assetId, keccak256(abi.encodePacked(spec.priceX18, nonce)));
        console.log("Committed:", spec.name);
        console.log("  marketId:", vm.toString(marketId));
        console.log("  assetId:", vm.toString(assetId));
        console.log("  vAMM:", vammProxy);
        console.log("  adapter:", adapter);
    }

    function _deployVamm(address adapter, uint256 priceX18) internal returns (address) {
        bytes memory init = abi.encodeCall(
            vAMM.initialize,
            (CH, adapter, priceX18, INITIAL_BASE_RESERVE, LIQUIDITY, FEE_BPS, FR_MAX_BPS_PER_HOUR, K_FUNDING_X18)
        );
        return address(new ERC1967Proxy(VAMM_IMPL, init));
    }

    function _writeArtifacts(
        Spec[] memory specs,
        bytes32[] memory marketIds,
        bytes32[] memory assetIds,
        bytes32[] memory nonces,
        address[] memory adapters,
        address[] memory vamms
    ) internal {
        string memory key = "b200Providers";
        string memory all;

        vm.serializeString(key, "network", "sepolia");
        vm.serializeUint(key, "chainId", 11155111);
        vm.serializeAddress(key, "cuOracle", CU_ORACLE);
        vm.serializeAddress(key, "marketRegistry", REGISTRY);

        for (uint256 i = 0; i < specs.length; i++) {
            string memory item = string(abi.encodePacked("m", vm.toString(i)));
            vm.serializeString(item, "name", specs[i].name);
            vm.serializeString(item, "assetSymbol", specs[i].assetSymbol);
            vm.serializeBytes32(item, "marketId", marketIds[i]);
            vm.serializeBytes32(item, "assetId", assetIds[i]);
            vm.serializeBytes32(item, "nonce", nonces[i]);
            vm.serializeUint(item, "priceX18", specs[i].priceX18);
            vm.serializeAddress(item, "adapter", adapters[i]);
            string memory itemJson = vm.serializeAddress(item, "vamm", vamms[i]);
            all = vm.serializeString(key, vm.toString(i), itemJson);
        }

        vm.writeJson(all, "./deployments/sepolia-b200-providers.json");
        console.log("Wrote deployments/sepolia-b200-providers.json");
    }
}

contract SeedB200ProviderMarkets is B200ProviderBase {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        bytes32 nonceBase = vm.envBytes32("NONCE_BASE");
        require(nonceBase != bytes32(0), "NONCE_BASE=0");

        Spec[] memory specs = _buildSpecs();
        uint256 seedLongPk = _freshPk(nonceBase, true);
        uint256 seedShortPk = _freshPk(nonceBase, false);
        address seedLong = vm.addr(seedLongPk);
        address seedShort = vm.addr(seedShortPk);

        vm.startBroadcast(deployerPk);
        _fundSeedWallet(seedLong);
        _fundSeedWallet(seedShort);
        for (uint256 i = 0; i < specs.length; i++) {
            bytes32 marketId = keccak256(bytes(specs[i].name));
            bytes32 assetId = keccak256(bytes(specs[i].assetSymbol));
            CuOracle(CU_ORACLE).updatePrices(assetId, specs[i].priceX18, _nonce(nonceBase, marketId, assetId));
            console.log("Revealed:", specs[i].name);
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < specs.length; i++) {
            _seedOne(specs[i], deployerPk, seedLongPk, seedShortPk);
        }

        console.log("B200 provider markets seeded and unpaused.");
        console.log("  long seed:", seedLong);
        console.log("  short seed:", seedShort);
    }

    function _fundSeedWallet(address wallet) internal {
        if (wallet.balance < GAS_FLOAT) {
            (bool ok,) = payable(wallet).call{value: GAS_FLOAT - wallet.balance}("");
            require(ok, "eth fund failed");
        }
        if (IERC20(USDC).balanceOf(wallet) < SEED_TOKEN_BUFFER) {
            IMintableToken(USDC).mint(wallet, SEED_TOKEN_BUFFER);
        }
    }

    function _seedOne(Spec memory spec, uint256 deployerPk, uint256 seedLongPk, uint256 seedShortPk) internal {
        bytes32 marketId = keccak256(bytes(spec.name));
        IMarketRegistry.Market memory market = MarketRegistry(REGISTRY).getMarket(marketId);
        require(market.vamm != address(0), "missing market");

        vm.startBroadcast(deployerPk);
        if (!MarketRegistry(REGISTRY).isActive(marketId)) {
            MarketRegistry(REGISTRY).pauseMarket(marketId, false);
        }
        vm.stopBroadcast();

        uint256 notional = (uint256(SEED_SIZE) * spec.priceX18) / 1e18;
        uint256 maxQuoteIn = (notional * LONG_MAX_BPS) / BPS;
        uint256 minQuoteOut = (notional * SHORT_MIN_BPS) / BPS;
        address seedLong = vm.addr(seedLongPk);
        address seedShort = vm.addr(seedShortPk);

        IClearingHouse.PositionView memory longPos = ClearingHouse(payable(CH)).getPosition(seedLong, marketId);
        if (longPos.size == 0) {
            vm.startBroadcast(seedLongPk);
            _ensureSeedDeposit(seedLong);
            ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
            ClearingHouse(payable(CH)).openPosition(marketId, true, SEED_SIZE, maxQuoteIn);
            vm.stopBroadcast();
        }

        IClearingHouse.PositionView memory shortPos = ClearingHouse(payable(CH)).getPosition(seedShort, marketId);
        if (shortPos.size == 0) {
            vm.startBroadcast(seedShortPk);
            _ensureSeedDeposit(seedShort);
            ClearingHouse(payable(CH)).addMargin(marketId, SEED_MARGIN_X18);
            ClearingHouse(payable(CH)).openPosition(marketId, false, SEED_SIZE, minQuoteOut);
            vm.stopBroadcast();
        }

        console.log("Seeded/skipped:", spec.name);
    }

    function _ensureSeedDeposit(address user) internal {
        uint256 currentX18 = ICollateralVault(VAULT).getTokenValueX18(
            USDC,
            ICollateralVault(VAULT).balanceOf(user, USDC)
        );
        if (currentX18 >= TARGET_SEED_COLLATERAL_X18) return;

        uint256 shortfallX18 = TARGET_SEED_COLLATERAL_X18 - currentX18;
        uint256 depositAmount = (shortfallX18 * 1e6) / 1e18;
        if (depositAmount == 0) depositAmount = 1;

        uint256 walletBalance = IERC20(USDC).balanceOf(user);
        if (walletBalance < depositAmount) {
            IMintableToken(USDC).mint(user, depositAmount - walletBalance);
        }

        IERC20(USDC).approve(VAULT, depositAmount);
        ClearingHouse(payable(CH)).deposit(USDC, depositAmount);
    }

    function _freshPk(bytes32 nonceBase, bool isLong) internal pure returns (uint256) {
        uint256 raw = uint256(keccak256(abi.encode(nonceBase, isLong, "bytestrike-sepolia-b200-provider-seed-v1")));
        return (raw % (SECP256K1_N - 1)) + 1;
    }
}
