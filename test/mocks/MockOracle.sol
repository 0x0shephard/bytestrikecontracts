// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "../../src/Interfaces/IOracle.sol";

/// @notice Simple mock oracle that returns a configurable price.
/// @dev Returns prices in 1e18 format for testing purposes
contract MockOracle is IOracle {
    uint256 private _price;
    uint8 private _decimals;
    string private _symbol;
    mapping(string => uint256) private _symbolPrices;

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

    function setSymbolPrice(string memory sym, uint256 price) external {
        _symbolPrices[sym] = price;
    }

    function getPrice() external view override returns (uint256) {
        return _price;
    }

    function getPrice(string memory sym) external view override returns (uint256) {
        uint256 p = _symbolPrices[sym];
        if (p != 0) return p;
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
