// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IVault {

    function priceFeed() external view returns (address);
    function maxLeverage() external view returns (uint256);
    function minProfitTime() external view returns (uint256);
    function fundingInterval() external view returns (uint256);
    function isManager(address _account) external view returns (bool);
    function minProfitBasisPoints() external view returns (uint256);
    function fundingRates(bool) external view returns (uint256);
    function cumulativeFundingRates(bool) external view returns (uint256);
    function lastFundingTimes(bool) external view returns (uint256);
    function vaultFee() external view returns (uint256);
    function vaultPnl() external view returns (int256);

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

    function getNextFundingRate(bool _isLong) external view returns (uint256);
    function marginFeeBasisPoints() external view returns (uint256);
    function collateralTokens(address _token) external view returns (bool);
    function indexTokens(address _token) external view returns (bool);
    function equityTokens(address _token) external view returns (bool);
    function globalLongSizes(address _token) external view returns (uint256);
    function globalShortSizes(address _token) external view returns (uint256);
    function getMaxPrice(address _token) external view returns (uint256);
    function getMinPrice(address _token) external view returns (uint256);
    function tokenToUsd(address _token, uint256 _tokenAmount) external view returns (uint256);
    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) external view returns (bool, uint256);
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

    function setMaxLeverage(uint256 _maxLeverage) external;
    function setManager(address _manager, bool _isManager) external;
    function setFundingRate(uint256 _fundingInterval, uint256 _fundingRateFactor, uint256 _stableFundingRateFactor) external;
    function setPriceFeed(address _priceFeed) external;
    function withdraw(address _token, address _receiver, uint256 _amount) external;
    function feeCallback() external;
    function pnlCallback() external;
}
