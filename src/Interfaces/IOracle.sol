// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IOracle {
    function getPrice() external view returns (uint256);
    function getPrice(string memory symbol) external view returns (uint256);
}
