// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IClearingHouse} from "../src/Interfaces/IClearingHouse.sol";

/**
 * @title FundingKeeper
 * @notice Accrues funding on every listed market through ClearingHouse.settleFunding.
 * @dev vAMM accrues at most MAX_FUNDING_ELAPSED (1 hour) per update and moves its funding clock to
 *      now, so funding for any gap past the first hour without an update is never charged. The cap is
 *      kept on purpose: it bounds what the first settlement after an unobserved oracle outage can
 *      charge. This keeper must therefore run at least every KEEPER_INTERVAL (30 minutes) so no
 *      market's gap reaches the cap. settleFunding(marketId, address(0)) only advances the market's
 *      funding indices; while the quote-token oracle is down it accrues up to the moment the feed
 *      went down and skips the rest, so keeper runs during an outage never drop live time.
 *
 *      Run (e.g. from cron every 30 minutes):
 *        CLEARING_HOUSE=<proxy> MARKET_IDS=<id1>,<id2>,... \
 *        forge script script/FundingKeeper.s.sol --rpc-url $RPC_URL --account <keeper> --broadcast
 *      MARKET_IDS must list every market registered in the MarketRegistry.
 */
contract FundingKeeper is Script {
    /// @notice Longest interval between two keeper runs, half of vAMM.MAX_FUNDING_ELAPSED.
    uint256 public constant KEEPER_INTERVAL = 30 minutes;

    function run() external {
        address clearingHouse = vm.envAddress("CLEARING_HOUSE");
        bytes32[] memory marketIds = vm.envBytes32("MARKET_IDS", ",");
        require(marketIds.length != 0, "MARKET_IDS empty");

        vm.startBroadcast();
        settleAll(clearingHouse, marketIds);
        vm.stopBroadcast();

        console.log("Funding settled on markets:", marketIds.length);
    }

    /// @notice Settles funding on each market (advances its funding indices to now).
    function settleAll(address clearingHouse, bytes32[] memory marketIds) public {
        for (uint256 i = 0; i < marketIds.length; i++) {
            IClearingHouse(clearingHouse).settleFunding(marketIds[i], address(0));
        }
    }
}
