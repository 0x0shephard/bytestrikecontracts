// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IInsuranceFund} from "./Interfaces/IInsuranceFund.sol";
import {IFeeRouter} from "./Interfaces/IFeeRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeeRouter
/// @notice Token-specific router that receives fees and routes to InsuranceFund.
/// @dev Deploy one instance per quote token. Clearinghouse should transfer tokens here first, then call hooks.
contract FeeRouter is IFeeRouter {
	using SafeERC20 for IERC20;

	address public owner;
	address public immutable quoteToken;    // ERC20 this router handles
	address public clearinghouse;           // single CH allowed to call hooks
	address public insuranceFund;           // destination for fund share
	address public treasuryAdmin;           // address authorized to withdraw treasury share

	// Basis points splits. Remainder (if any) goes to treasury.
	uint16 public tradeToFundBps;           // out of 10000
	uint16 public liqToFundBps;             // out of 10000

	event OwnerTransferred(address indexed newOwner);
	event ClearinghouseSet(address indexed ch);
	event InsuranceFundSet(address indexed fund);
	event TreasuryAdminSet(address indexed treasuryAdmin);
	event TreasuryWithdrawn(address indexed to, uint256 amount);
	event SplitsSet(uint16 tradeToFundBps, uint16 liqToFundBps);
	event TradeFeeRouted(uint256 totalAmount, uint256 toInsuranceFund, uint256 toTreasury);
	event LiquidationPenaltyRouted(uint256 totalAmount, uint256 toInsuranceFund, uint256 toTreasury);

	modifier onlyOwner() {
		require(msg.sender == owner, "FR: not owner");
		_;
	}

	modifier onlyCH() {
		require(msg.sender == clearinghouse, "FR: not CH");
		_;
	}

	/// @param _quoteToken ERC20 token to route.
	/// @param _insuranceFund Insurance fund address for this token.
	/// @param _treasuryAdmin Address authorized to withdraw accumulated treasury fees.
	/// @param _clearinghouse Central clearinghouse allowed to trigger routing.
	/// @param _tradeToFundBps Portion of trade fees sent to insurance fund.
	/// @param _liqToFundBps Portion of liquidation penalties sent to insurance fund.
	constructor(
		address _quoteToken,
		address _insuranceFund,
		address _treasuryAdmin,
		address _clearinghouse,
		uint16 _tradeToFundBps,
		uint16 _liqToFundBps
	) {
		require(_quoteToken != address(0), "FR: token=0");
		require(_insuranceFund != address(0), "FR: fund=0");
		require(_treasuryAdmin != address(0), "FR: treasury admin=0");
		require(_clearinghouse != address(0), "FR: CH=0");
		require(_tradeToFundBps <= 10_000 && _liqToFundBps <= 10_000, "FR: bps>1e4");
		owner = msg.sender;
		quoteToken = _quoteToken;
		insuranceFund = _insuranceFund;
		treasuryAdmin = _treasuryAdmin;
		clearinghouse = _clearinghouse;
		tradeToFundBps = _tradeToFundBps;
		liqToFundBps = _liqToFundBps;
		emit InsuranceFundSet(_insuranceFund);
		emit TreasuryAdminSet(_treasuryAdmin);
		emit ClearinghouseSet(_clearinghouse);
		emit SplitsSet(_tradeToFundBps, _liqToFundBps);
	}

	/// @inheritdoc IFeeRouter
	/// @dev Uses balance delta to support fee-on-transfer tokens. The actual received
	/// amount may be less than `amount` parameter due to transfer fees.
	function onTradeFee(uint256 amount) external override onlyCH {
		require(amount > 0, "FR: amount=0");

		// Use actual balance for fee-on-transfer support
		uint256 actualBalance = IERC20(quoteToken).balanceOf(address(this));
		uint256 actualAmount = actualBalance < amount ? actualBalance : amount;

		if (actualAmount == 0) {
			emit TradeFeeRouted(amount, 0, 0);
			return;
		}

		uint256 toFund = (actualAmount * tradeToFundBps) / 10_000;
		uint256 toTreasury = actualAmount - toFund;

		if (toFund > 0) {
			// Approve and let InsuranceFund pull tokens (pull-pattern)
			IERC20(quoteToken).safeIncreaseAllowance(insuranceFund, toFund);
			IInsuranceFund(insuranceFund).onFeeReceived(toFund);
		}

		emit TradeFeeRouted(actualAmount, toFund, toTreasury);
	}

	/// @inheritdoc IFeeRouter
	/// @dev Uses balance delta to support fee-on-transfer tokens. The actual received
	/// amount may be less than `amount` parameter due to transfer fees.
	function onLiquidationPenalty(uint256 amount) external override onlyCH {
		require(amount > 0, "FR: amount=0");

		// Use actual balance for fee-on-transfer support
		uint256 actualBalance = IERC20(quoteToken).balanceOf(address(this));
		uint256 actualAmount = actualBalance < amount ? actualBalance : amount;

		if (actualAmount == 0) {
			emit LiquidationPenaltyRouted(amount, 0, 0);
			return;
		}

		uint256 toFund = (actualAmount * liqToFundBps) / 10_000;
		uint256 toTreasury = actualAmount - toFund;

		if (toFund > 0) {
			// Approve and let InsuranceFund pull tokens (pull-pattern)
			IERC20(quoteToken).safeIncreaseAllowance(insuranceFund, toFund);
			IInsuranceFund(insuranceFund).onFeeReceived(toFund);
		}

		emit LiquidationPenaltyRouted(actualAmount, toFund, toTreasury);
	}

	// ===== Admin =====
	function setClearinghouse(address ch) external onlyOwner {
		require(ch != address(0), "FR: CH=0");
		clearinghouse = ch;
		emit ClearinghouseSet(ch);
	}

	function setInsuranceFund(address fund) external onlyOwner {
		require(fund != address(0), "FR: fund=0");
		insuranceFund = fund;
		emit InsuranceFundSet(fund);
	}

	function setTreasuryAdmin(address _treasuryAdmin) external onlyOwner {
		require(_treasuryAdmin != address(0), "FR: treasury admin=0");
		treasuryAdmin = _treasuryAdmin;
		emit TreasuryAdminSet(_treasuryAdmin);
	}

	function withdrawTreasury(address to, uint256 amount) external {
		require(msg.sender == treasuryAdmin || msg.sender == owner, "FR: not treasury admin");
		require(to != address(0), "FR: to=0");
		require(amount > 0, "FR: amount=0");
		IERC20(quoteToken).safeTransfer(to, amount);
		emit TreasuryWithdrawn(to, amount);
	}

	function setSplits(uint16 _tradeToFundBps, uint16 _liqToFundBps) external onlyOwner {
		require(_tradeToFundBps <= 10_000 && _liqToFundBps <= 10_000, "FR: bps>1e4");
		tradeToFundBps = _tradeToFundBps;
		liqToFundBps = _liqToFundBps;
		emit SplitsSet(_tradeToFundBps, _liqToFundBps);
	}

	function transferOwnership(address newOwner) external onlyOwner {
		require(newOwner != address(0), "FR: owner=0");
		owner = newOwner;
		emit OwnerTransferred(newOwner);
	}
}