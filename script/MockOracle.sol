// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "../src/Interfaces/IOracle.sol";

/// @notice Simple mock oracle that returns a configurable price.
contract MockOracle is IOracle {
    uint256 private _price;
    uint8 private _decimals;

    constructor(uint256 initialPrice, uint8 decimals_) {
        _price = initialPrice;
        _decimals = decimals_;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function getPrice() external view override returns (uint256) {
        return _price;
    }

    function getPrice(string memory) external view override returns (uint256) {
        return _price;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}
