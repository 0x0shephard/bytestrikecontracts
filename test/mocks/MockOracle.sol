// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "../../src/Interfaces/IOracle.sol";

/// @notice Simple mock oracle that returns a configurable price.
/// @dev Returns prices in 1e18 format for testing purposes
contract MockOracle is IOracle {
    uint256 private _price;
    uint8 private _decimals;
    string private _symbol;

    event PriceUpdated(uint256 oldPrice, uint256 newPrice);

    constructor(uint256 initialPrice, uint8 decimals_) {
        _price = initialPrice;
        _decimals = decimals_;
    }

    function setPrice(uint256 newPrice) external {
        uint256 oldPrice = _price;
        _price = newPrice;
        emit PriceUpdated(oldPrice, newPrice);
    }

    function getPrice() external view override returns (uint256) {
        // Price returned in 1e18 format
        return _price;
    }

    function getPrice(string memory /* symbol */) external view returns (uint256) {
        // For testing, return same price regardless of symbol
        // In production, different symbols would have different prices
        return _price;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function setSymbol(string memory symbol_) external {
        _symbol = symbol_;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }
}
