// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {vAMM} from "../src/vAMM.sol";

interface IPriceOracleView {
    function getPrice() external view returns (uint256);
}

/// @notice Moves affected B200 vAMMs one safe reset step toward oracle price.
/// @dev resetReserves enforces a 10% max price move and 1 hour cooldown, so this
///      script may need to be rerun after cooldown until mark/oracle are aligned.
///      Broadcast only after reviewing DiagnoseB200Liquidatable output:
///      forge script script/StepB200ReserveRealignment.s.sol:StepB200ReserveRealignment --rpc-url "$SEPOLIA_RPC_URL" --broadcast --slow
contract StepB200ReserveRealignment is Script {
    uint256 constant BPS = 10_000;
    uint256 constant MAX_PRICE_CHANGE_BPS = 1_000;
    uint256 constant DEFAULT_BASE_RESERVE = 100_000e18;

    struct MarketSpec {
        string name;
        address vammAddress;
        address oracle;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 baseReserve = vm.envOr("B200_RESET_BASE_RESERVE", DEFAULT_BASE_RESERVE);
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
        uint256 target = _nextPrice(mark, oracle);

        console.log("Market:", spec.name);
        console.log("  current mark:", mark);
        console.log("  oracle:", oracle);
        console.log("  next reset price:", target);
        console.log("  new base reserve:", baseReserve);

        if (target == mark) {
            console.log("  skipped: already aligned for this step");
            return;
        }

        market.resetReserves(target, baseReserve);
    }

    function _nextPrice(uint256 mark, uint256 oracle) internal pure returns (uint256) {
        require(mark > 0, "mark=0");
        require(oracle > 0, "oracle=0");

        if (mark == oracle) return mark;

        uint256 maxMove = mark * MAX_PRICE_CHANGE_BPS / BPS;
        if (maxMove == 0) maxMove = 1;

        if (mark > oracle) {
            uint256 floor = mark > maxMove ? mark - maxMove : 1;
            return oracle >= floor ? oracle : floor;
        }

        uint256 ceiling = mark + maxMove;
        return oracle <= ceiling ? oracle : ceiling;
    }

    function _markets() internal pure returns (MarketSpec[] memory specs) {
        specs = new MarketSpec[](3);
        specs[0] = MarketSpec({
            name: "B200-PERP-V2",
            vammAddress: 0x0D8132954F4BefAE87a240AFE6584320bED12322,
            oracle: 0x46Af9ACAE550245923B4EA700ba68dEd027ffc79
        });
        specs[1] = MarketSpec({
            name: "ORACLE-B200-PERP",
            vammAddress: 0x0E9bF74e394219004CbD2b7d6Dd3443418d116E9,
            oracle: 0x9E0aee0ff84E70055bb2d9eD48606F827f6096cB
        });
        specs[2] = MarketSpec({
            name: "COREWEAVE-B200-PERP",
            vammAddress: 0x283Eb1C70c1ddFed588EFFF0B20A129Bd366CB96,
            oracle: 0x2DFCa180061e3E8d0B8785c0067F2AC5aad2bc90
        });
    }
}
