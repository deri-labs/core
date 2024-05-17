// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IVault {

    function increasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) external;

    function decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external returns (uint256);

    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) external returns (uint256);

    function minProfitTime() external view returns (uint256);
    function minProfitBasisPoints() external view returns (uint256);
    function fundingRates(bool) external view returns (uint256);
    function cumulativeFundingRates(bool) external view returns (uint256);
    function getNextFundingRate(bool _isLong) external view returns (uint256);
    function globalLongSizes(address _token) external view returns (uint256);
    function globalShortSizes(address _token) external view returns (uint256);
    function getMaxPrice(address _token) external view returns (uint256);
    function getMinPrice(address _token) external view returns (uint256);
    function tokenToUsd(address _token, uint256 _tokenAmount) external view returns (uint256);
    function getPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) external view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256);
    function isPositionExist(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) external view returns (bool, bytes32);

}
