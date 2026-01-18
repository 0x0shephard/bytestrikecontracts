// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IInsuranceFund
/// @notice Receives protocol fee share and maintains reserves to cover bad debt and incentives.
/// @dev Interface only; implementations may use AccessControl for auth (e.g., CLEARINGHOUSE_ROLE, ADMIN_ROLE).
interface IInsuranceFund {
    // ========= Events =========
    /// @notice Emitted when fees are routed in by the fee router (accounting hook).
    event FeeReceived(address indexed from, uint256 amount);

    /// @notice Emitted when someone voluntarily tops up the fund.
    event Donated(address indexed from, uint256 amount);

    /// @notice Emitted on successful payout from the fund.
    event Payout(address indexed to, uint256 amount);

    /// @notice Admin updates the fee router that is allowed to notify fee intake.
    event RouterUpdated(address indexed router, bool allowed);
    event ClearinghouseUpdated(address indexed clearinghouse);

    /// @notice Admin updates authorized caller (e.g., clearinghouse) that can request payouts.
    event AuthorizedUpdated(address indexed caller, bool allowed);

    /// @notice Admin rescues arbitrary tokens accidentally sent to the fund.
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ========= Admin/Mutative =========
    /// @notice Accounting hook for the fee router to call after transferring quote tokens in.
    /// @dev Implementations should restrict caller to the configured router.
    /// @param amount Amount of quote tokens received (1e18 if quote has 18 decimals).
    function onFeeReceived(uint256 amount) external;

    /// @notice Transfer funds out to a target, e.g., to cover bad debt or pay incentives.
    /// @dev Implementations should restrict caller to an authorized module (e.g., Clearinghouse) and ensure sufficient balance.
    function payout(address to, uint256 amount) external;

    /// @notice Optional convenience to donate to the fund with prior approval and transferFrom in implementation.
    /// @dev Implementation may ignore or use this purely for accounting; tokens should already be transferred.
    function donate(uint256 amount) external;

    /// @notice Set or revoke an authorized caller that can request payouts.
    function setAuthorized(address caller, bool allowed) external;

    /// @notice Set the clearinghouse address responsible for orchestrating payouts.
    function setClearinghouse(address clearinghouse) external;

    /// @notice Enable or disable a fee router that is allowed to notify fee intake.
    function setFeeRouter(address router, bool allowed) external;

    /// @notice Rescue arbitrary tokens mistakenly sent to this contract.
    /// @dev Admin-only in implementation; quote token rescue should typically be disallowed or guarded.
    function rescueToken(address token, address to, uint256 amount) external;

    // ========= Views =========
    /// @notice Quote token held by this fund for payouts (per-market fund recommended).
    function quoteToken() external view returns (address);

    /// @notice Current clearinghouse address.
    function clearinghouse() external view returns (address);

    /// @notice Returns whether an address is an authorized fee router.
    function isRouter(address router) external view returns (bool);

    /// @notice Returns whether an address is authorized to request payouts.
    function isAuthorized(address caller) external view returns (bool);

    /// @notice Current available balance in quote token as tracked by the fund.
    /// @dev Implementations may compute this as ERC20(quoteToken).balanceOf(address(this)).
    function balance() external view returns (uint256);

    /// @notice Cumulative accounting: total fees and donations received.
    function totalReceived() external view returns (uint256);

    /// @notice Cumulative accounting: total payouts sent.
    function totalPaid() external view returns (uint256);
}
