// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ILPool {
    function transfer(address _token, uint256 _amount, address _receiver) external;
}