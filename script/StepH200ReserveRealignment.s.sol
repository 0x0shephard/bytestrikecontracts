// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {vAMM} from "../src/vAMM.sol";

interface IPriceOracleView {
    function getPrice() external view returns (uint256);
}

/// @notice Moves fresh H200 vAMMs one safe reset step upward toward oracle price.
/// @dev resetReserves enforces a 10% max price move and 1 hour cooldown.
contract StepH200ReserveRealignment is Script {
    uint256 constant BPS = 10_000;
    uint256 constant MAX_PRICE_CHANGE_BPS = 1_000;
    uint256 constant DEFAULT_BASE_RESERVE = 100_000e18;
    uint256 constant RESET_COOLDOWN = 1 hours;

    struct MarketSpec {
        string name;
        address vammAddress;
        address oracle;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 baseReserve = vm.envOr("H200_RESET_BASE_RESERVE", DEFAULT_BASE_RESERVE);
        MarketSpec[] memory specs = _markets();

        vm.startBroadcast(deployerPk);
        for (uint256 i = 0; i < specs.length; i++) {
            _stepOne(specs[i], baseReserve);
        }
        vm.stopBroadcast();
    }

    function _stepOne(MarketSpec memory spec, uint256 baseReserve) internal {
        vAMM market = vAMM(spec.vammAddress);
        uint256 mark = market.getMarkPrice();
        uint256 oracle = IPriceOracleView(spec.oracle).getPrice();
        uint64 lastReset = market.lastResetTimestamp();

        console.log("Market:", spec.name);
        console.log("  current mark:", mark);
        console.log("  oracle:", oracle);

        if (block.timestamp < uint256(lastReset) + RESET_COOLDOWN) {
            console.log("  skipped: reset cooldown active");
            return;
        }

        if (mark >= oracle) {
            console.log("  skipped: mark is not below oracle");
            return;
        }

        uint256 target = _nextPriceUp(mark, oracle);
        console.log("  next reset price:", target);
        console.log("  new base reserve:", baseReserve);

        if (target == mark) {
            console.log("  skipped: already aligned for this step");
            return;
        }

        market.resetReserves(target, baseReserve);
    }

    function _nextPriceUp(uint256 mark, uint256 oracle) internal pure returns (uint256) {
        require(mark > 0, "mark=0");
        require(oracle > 0, "oracle=0");
        require(mark < oracle, "mark>=oracle");

        uint256 maxMove = mark * MAX_PRICE_CHANGE_BPS / BPS;
        if (maxMove == 0) maxMove = 1;

        uint256 ceiling = mark + maxMove;
        return oracle <= ceiling ? oracle : ceiling;
    }

    function _markets() internal pure returns (MarketSpec[] memory specs) {
        specs = new MarketSpec[](6);
        specs[0] = MarketSpec({
            name: "H200-PERP-V2",
            vammAddress: 0x564d5076B7229Fffa7Ca369C7752b2EC4376aBF6,
            oracle: 0xFB968FBE19880479c0658479cCF9327a170D273B
        });
        specs[1] = MarketSpec({
            name: "AZURE-H200-PERPETUAL",
            vammAddress: 0x8a68985e036E7fD635eC8E8AFd8a86A61187D723,
            oracle: 0x6b719aD83Fa6850Bc7a5b05185613Dc467B137C2
        });
        specs[2] = MarketSpec({
            name: "ORACLE-H200-PERPETUAL",
            vammAddress: 0xc4C187F1a499Bf1f565F9816bD0427F676B772c2,
            oracle: 0x49fbbFDeBaeE2c1482f26D658ED3A1f9d34e0415
        });
        specs[3] = MarketSpec({
            name: "AWS-H200-PERPETUAL",
            vammAddress: 0x079A30C8Aa3D34FcF17B9e288bd05C04Df203e23,
            oracle: 0x79e76CE5DF18Ea85D3D232F3c0f176406fD1A7d9
        });
        specs[4] = MarketSpec({
            name: "COREWEAVE-H200-PERPETUAL",
            vammAddress: 0x15df002e93168Cf574Bdad50D05AC2bAAaC6Cd6a,
            oracle: 0xDc41c6FA9dd2F97B0bC886E772D427bfb52d4968
        });
        specs[5] = MarketSpec({
            name: "GCP-H200-PERPETUAL",
            vammAddress: 0x2395987E973CdFc4e145b1220D3ee34FC7c8E084,
            oracle: 0xafC1C09D1d7CD5bDF4908B8011D27d158f4fE204
        });
    }
}
