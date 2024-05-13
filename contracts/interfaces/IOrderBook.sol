// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IOrderBook {

    function getIncreaseOrder(address _account, uint256 _orderIndex) external view returns (
        uint256 collateralDelta,
        address collateralToken,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    );

    function getDecreaseOrder(address _account, uint256 _orderIndex) external view returns (
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    );

    function executeDecreaseOrder(address, uint256, address payable) external;
    function executeIncreaseOrder(address, uint256, address payable) external;
}
