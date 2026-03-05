// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFeeRouter
/// @notice Splits and routes protocol fees and liquidation penalties between an insurance fund and a treasury.
/// @dev Deploy one instance per quote token. Clearinghouse transfers tokens to the router, then calls hooks.
interface IFeeRouter {
    // ========= Events =========

    /// @notice Emitted when the clearinghouse address is updated.
    event ClearinghouseSet(address indexed ch);

    /// @notice Emitted when the insurance fund address is updated.
    event InsuranceFundSet(address indexed fund);

    /// @notice Emitted when the treasury admin address is updated.
    event TreasuryAdminSet(address indexed treasuryAdmin);

    /// @notice Emitted when treasury funds are withdrawn.
    event TreasuryWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when the insurance-fund / treasury split ratios are updated.
    event SplitsSet(uint16 tradeToFundBps, uint16 liqToFundBps);

    /// @notice Emitted when a trade fee is split and routed.
    event TradeFeeRouted(uint256 totalAmount, uint256 toInsuranceFund, uint256 toTreasury);

    /// @notice Emitted when a liquidation penalty is split and routed.
    event LiquidationPenaltyRouted(uint256 totalAmount, uint256 toInsuranceFund, uint256 toTreasury);

    // ========= Fee Routing =========

    /// @notice Routes a trade fee to the insurance fund and treasury according to the configured split.
    /// @dev Called by the clearinghouse after transferring quote tokens to this contract.
    /// @param amount Quote-token amount (native decimals) to route.
    function onTradeFee(uint256 amount) external;

    /// @notice Routes a liquidation penalty to the insurance fund and treasury according to the configured split.
    /// @dev Called by the clearinghouse after transferring quote tokens to this contract.
    /// @param amount Quote-token amount (native decimals) to route.
    function onLiquidationPenalty(uint256 amount) external;

    // ========= Admin =========

    /// @notice Updates the clearinghouse address authorized to call fee-routing hooks.
    /// @param ch New clearinghouse address; must not be zero.
    function setClearinghouse(address ch) external;

    /// @notice Updates the insurance fund destination for the fund share of fees.
    /// @param fund New insurance fund address; must not be zero.
    function setInsuranceFund(address fund) external;

    /// @notice Updates the address authorized to withdraw accumulated treasury fees.
    /// @param treasuryAdmin New treasury admin address; must not be zero.
    function setTreasuryAdmin(address treasuryAdmin) external;

    /// @notice Withdraws accumulated treasury fees to a specified address.
    /// @dev Callable by the treasury admin or the contract owner.
    /// @param to Destination address for the withdrawal; must not be zero.
    /// @param amount Quote-token amount to withdraw; must be greater than zero.
    function withdrawTreasury(address to, uint256 amount) external;

    /// @notice Updates the basis-point split ratios for insurance fund vs treasury.
    /// @param tradeToFundBps Portion of trade fees routed to the insurance fund (out of 10 000).
    /// @param liqToFundBps Portion of liquidation penalties routed to the insurance fund (out of 10 000).
    function setSplits(uint16 tradeToFundBps, uint16 liqToFundBps) external;
}
