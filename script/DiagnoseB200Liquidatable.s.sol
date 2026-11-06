// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ClearingHouse} from "../src/ClearingHouse.sol";
import {vAMM} from "../src/vAMM.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

interface IPriceOracleView {
    function getPrice() external view returns (uint256);
}

/// @notice Read-only Sepolia diagnostic for B200 markets whose longs can revert
///         with ImmediatelyLiquidatable due to mark/oracle divergence.
/// @dev Run without --broadcast:
///      forge script script/DiagnoseB200Liquidatable.s.sol:DiagnoseB200Liquidatable --rpc-url "$SEPOLIA_RPC_URL"
contract DiagnoseB200Liquidatable is Script {
    address constant CH = 0xDf4DDD4019097B335dD507f916984A1A53E40a0d;
    uint256 constant TEST_SIZE = 1e18;
    uint256 constant BPS = 10_000;

    struct MarketSpec {
        string name;
        bytes32 marketId;
        address vammAddress;
        address oracle;
    }

    function run() external {
        address trader = vm.envOr("DIAG_TRADER", address(0xCc624fFA5df1F3F4b30aa8abd30186a86254F406));
        MarketSpec[] memory specs = _markets();

        console.log("B200 immediately-liquidatable diagnostics");
        console.log("Trader:", trader);
        console.log("Test size:", TEST_SIZE);

        for (uint256 i = 0; i < specs.length; i++) {
            _diagnoseOne(specs[i], trader);
        }
    }

    function _diagnoseOne(MarketSpec memory spec, address trader) internal {
        uint256 mark = vAMM(spec.vammAddress).getMarkPrice();
        uint256 oracle = IPriceOracleView(spec.oracle).getPrice();
        (uint256 baseReserve, uint256 quoteReserve) = vAMM(spec.vammAddress).getReserves();
        (
            uint256 imrBps,
            uint256 mmrBps,
            uint256 liquidationPenaltyBps,
            uint256 penaltyCap,
            uint256 maxPositionSize,
            uint256 minPositionSize
        ) = ClearingHouse(payable(CH)).marketRiskParams(spec.marketId);

        console.log("");
        console.log("Market:", spec.name);
        console.log("  mark:", mark);
        console.log("  oracle:", oracle);
        console.log("  mark/oracle bps:", oracle == 0 ? 0 : mark * BPS / oracle);
        console.log("  base reserve:", baseReserve);
        console.log("  quote reserve:", quoteReserve);
        console.log("  imrBps:", imrBps);
        console.log("  mmrBps:", mmrBps);
        console.log("  liquidationPenaltyBps:", liquidationPenaltyBps);
        console.log("  penaltyCap:", penaltyCap);
        console.log("  maxPositionSize:", maxPositionSize);
        console.log("  minPositionSize:", minPositionSize);

        vm.prank(trader);
        try IClearingHouse(CH).openPosition(spec.marketId, true, uint128(TEST_SIZE), 0) {
            console.log("  long 1e18 simulation: OK");
        } catch (bytes memory reason) {
            console.log("  long 1e18 simulation: REVERT");
            console.logBytes(reason);
        }

        vm.prank(trader);
        try IClearingHouse(CH).openPosition(spec.marketId, false, uint128(TEST_SIZE), 0) {
            console.log("  short 1e18 simulation: OK");
        } catch (bytes memory reason) {
            console.log("  short 1e18 simulation: REVERT");
            console.logBytes(reason);
        }
    }

    function _markets() internal pure returns (MarketSpec[] memory specs) {
        specs = new MarketSpec[](3);
        specs[0] = MarketSpec({
            name: "B200-PERP-V2",
            marketId: 0x02164b06b5fff171a87dbb519e6d639871a0cfbc0e44d411313256d0168b60fe,
            vammAddress: 0x0D8132954F4BefAE87a240AFE6584320bED12322,
            oracle: 0x46Af9ACAE550245923B4EA700ba68dEd027ffc79
        });
        specs[1] = MarketSpec({
            name: "ORACLE-B200-PERP",
            marketId: 0x409078466c3ce47594bb7591497b09163aae7262d949015e19a7c4c947434d80,
            vammAddress: 0x0E9bF74e394219004CbD2b7d6Dd3443418d116E9,
            oracle: 0x9E0aee0ff84E70055bb2d9eD48606F827f6096cB
        });
        specs[2] = MarketSpec({
            name: "COREWEAVE-B200-PERP",
            marketId: 0x75da99206b1151e67ba75b25d99b3e2609e1d80b86bb0339fe90a7c4e64930f0,
            vammAddress: 0x283Eb1C70c1ddFed588EFFF0B20A129Bd366CB96,
            oracle: 0x2DFCa180061e3E8d0B8785c0067F2AC5aad2bc90
        });
    }
}
