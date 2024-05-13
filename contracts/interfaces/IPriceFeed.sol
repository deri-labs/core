// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IPriceFeed {

    function getPrice(address _token, bool _maximise, bool _fresh) external view returns (uint256);
    function getUpdateFee(bytes[] calldata _updateData, address _token) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata _priceData, address _token) external payable;
}
