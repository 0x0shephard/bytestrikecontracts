// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "../Interfaces/IOracle.sol";

/**
 * @title UpdatableETHOracle
 * @notice Simple oracle that returns ETH index price with owner update capability
 */
contract UpdatableETHOracle is IOracle {
    error OnlyOwner();
    error InvalidPrice();

    address public owner;
    uint256 public ethPrice; // Price in 1e18 format

    event PriceUpdated(uint256 indexed newPrice, uint256 timestamp);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(uint256 _initialPrice) {
        if (_initialPrice == 0) revert InvalidPrice();
        owner = msg.sender;
        ethPrice = _initialPrice;
        emit PriceUpdated(_initialPrice, block.timestamp);
    }

    /// @inheritdoc IOracle
    function getPrice() external view override returns (uint256) {
        return ethPrice;
    }

    /// @notice Update the ETH price (owner only)
    /// @param _newPrice New price in 1e18 format (e.g., 3.79e18 for $3.79)
    function updatePrice(uint256 _newPrice) external onlyOwner {
        if (_newPrice == 0) revert InvalidPrice();
        ethPrice = _newPrice;
        emit PriceUpdated(_newPrice, block.timestamp);
    }

    /// @notice Transfer ownership to a new address
    /// @param _newOwner Address of the new owner
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidPrice();
        address oldOwner = owner;
        owner = _newOwner;
        emit OwnershipTransferred(oldOwner, _newOwner);
    }
}
