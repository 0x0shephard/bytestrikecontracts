// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "../Interfaces/IOracle.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title UpdatableETHOracle
 * @notice Simple oracle that returns ETH index price with owner update capability
 * @dev Ownership moves in two steps (Ownable2Step) and cannot be renounced: the owner is the only
 *      price writer.
 */
contract UpdatableETHOracle is IOracle, Ownable2Step {
    error InvalidPrice();

    uint256 public ethPrice; // Price in 1e18 format

    event PriceUpdated(uint256 indexed newPrice, uint256 timestamp);

    constructor(uint256 _initialPrice) Ownable(msg.sender) {
        if (_initialPrice == 0) revert InvalidPrice();
        ethPrice = _initialPrice;
        emit PriceUpdated(_initialPrice, block.timestamp);
    }

    /// @inheritdoc IOracle
    function getPrice() external view override returns (uint256) {
        return ethPrice;
    }

    /// @inheritdoc IOracle
    function getPrice(string memory) external view override returns (uint256) {
        return ethPrice;
    }

    /// @notice Update the ETH price (owner only)
    /// @param _newPrice New price in 1e18 format (e.g., 3.79e18 for $3.79)
    function updatePrice(uint256 _newPrice) external onlyOwner {
        if (_newPrice == 0) revert InvalidPrice();
        ethPrice = _newPrice;
        emit PriceUpdated(_newPrice, block.timestamp);
    }

    /// @notice Disabled: renouncing would permanently remove the oracle's only price writer.
    function renounceOwnership() public pure override {
        revert("Oracle: renounce disabled");
    }
}
