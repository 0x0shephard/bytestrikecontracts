// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IInsuranceFund} from "./Interfaces/IInsuranceFund.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title InsuranceFund
/// @notice Minimal ERC20-based fund that holds quote reserves, receives fee share, and pays out bad debt.
/// @dev Caller auth is intentionally simple: owner sets router and authorized modules (e.g., Clearinghouse).
contract InsuranceFund is IInsuranceFund, Ownable {
    using SafeERC20 for IERC20;

    // ========= Roles / Wiring =========
    address private _clearinghouse;
    address private _quoteToken;
    mapping(address => bool) private _routers; // fee routers allowed to push fees
    mapping(address => bool) private _authorized; // modules allowed to request payouts

    // ========= Accounting =========
    uint256 private _totalReceived;
    uint256 private _totalPaid;

    /// @param quoteToken_ ERC20 token used for all accounting and payouts (e.g., USDC/WETH).
    /// @param clearinghouse_ Core clearinghouse authorized to request payouts (optional at deploy time).
    constructor(address quoteToken_, address clearinghouse_) Ownable(msg.sender) {
        require(quoteToken_ != address(0), "IF: quote=0");
        _quoteToken = quoteToken_;
        if (clearinghouse_ != address(0)) {
            _clearinghouse = clearinghouse_;
            _authorized[clearinghouse_] = true;
            emit ClearinghouseUpdated(clearinghouse_);
            emit AuthorizedUpdated(clearinghouse_, true);
        }
    }

    // ========= Admin/Mutative =========
    /// @inheritdoc IInsuranceFund
    /// @dev Uses pull-pattern: verifies actual token balance increase to prevent spoofed accounting.
    function onFeeReceived(uint256 amount) external override {
        require(_routers[msg.sender], "IF: not router");
        require(amount > 0, "IF: amount=0");
        
        // Pull-pattern: verify tokens were actually transferred by checking balance delta
        uint256 balanceBefore = IERC20(_quoteToken).balanceOf(address(this));
        IERC20(_quoteToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(_quoteToken).balanceOf(address(this)) - balanceBefore;
        require(received > 0, "IF: no tokens received");
        
        _totalReceived += received;
        emit FeeReceived(msg.sender, received);
    }

    /// @inheritdoc IInsuranceFund
    function payout(address to, uint256 amount) external override {
        require(_authorized[msg.sender], "IF: not authorized");
        require(to != address(0), "IF: to=0");
        require(amount > 0, "IF: amount=0");
        IERC20(_quoteToken).safeTransfer(to, amount);
        _totalPaid += amount;
        emit Payout(to, amount);
    }

    /// @inheritdoc IInsuranceFund
    /// @notice Allows anyone to donate quote tokens to the insurance fund.
    /// @dev Uses pull-pattern: transfers tokens from sender and verifies balance delta.
    function donate(uint256 amount) external override {
        require(amount > 0, "IF: amount=0");

        // Pull tokens from sender and verify actual receipt
        uint256 balanceBefore = IERC20(_quoteToken).balanceOf(address(this));
        IERC20(_quoteToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(_quoteToken).balanceOf(address(this)) - balanceBefore;
        require(received > 0, "IF: no tokens received");

        _totalReceived += received;
        emit Donated(msg.sender, received);
    }

    /// @inheritdoc IInsuranceFund
    function setAuthorized(address caller, bool allowed) external override onlyOwner {
        _authorized[caller] = allowed;
        emit AuthorizedUpdated(caller, allowed);
    }

    /// @inheritdoc IInsuranceFund
    function setClearinghouse(address newClearinghouse) external override onlyOwner {
        require(newClearinghouse != address(0), "IF: ch=0");
        if (_clearinghouse != address(0)) {
            _authorized[_clearinghouse] = false;
            emit AuthorizedUpdated(_clearinghouse, false);
        }
        _clearinghouse = newClearinghouse;
        _authorized[newClearinghouse] = true;
        emit ClearinghouseUpdated(newClearinghouse);
        emit AuthorizedUpdated(newClearinghouse, true);
    }

    /// @inheritdoc IInsuranceFund
    /// @notice Enables or disables a fee router address. Only callable by the owner.
    function setFeeRouter(address router_, bool allowed) external override onlyOwner {
        require(router_ != address(0), "IF: router=0");
        _routers[router_] = allowed;
        emit RouterUpdated(router_, allowed);
    }

    /// @inheritdoc IInsuranceFund
    function rescueToken(address token, address to, uint256 amount) external override onlyOwner {
        require(token != _quoteToken, "IF: cannot rescue quote");
        require(to != address(0), "IF: to=0");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ========= Views =========
    /// @inheritdoc IInsuranceFund
    function quoteToken() external view override returns (address) {
        return _quoteToken; 
    }

    /// @inheritdoc IInsuranceFund
    function clearinghouse() external view override returns (address) { 
        return _clearinghouse; 
    }

    /// @inheritdoc IInsuranceFund
    function isRouter(address router_) external view override returns (bool) {
        return _routers[router_];
    }

    /// @inheritdoc IInsuranceFund
    function isAuthorized(address caller) external view override returns (bool) {
        return _authorized[caller];
    }

    /// @inheritdoc IInsuranceFund
    function balance() external view override returns (uint256) {
        return IERC20(_quoteToken).balanceOf(address(this));
    }

    /// @inheritdoc IInsuranceFund
    function totalReceived() external view override returns (uint256) {
        return _totalReceived; 
    }

    /// @inheritdoc IInsuranceFund
    function totalPaid() external view override returns (uint256) {
        return _totalPaid;
    }
}