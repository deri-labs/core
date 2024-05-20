// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/DataTypes.sol";
import "./libraries/Events.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/ILPool.sol";

contract Vault is IVault, ReentrancyGuard, Ownable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public usdToken;
    address public priceFeed;
    uint256 public maxLeverage;
    uint256 public marginFeeBasisPoints;
    uint256 public fundingInterval = 1 hours;
    uint256 public override minProfitTime;
    uint256 public override minProfitBasisPoints;

    mapping(bool => uint256) public override fundingRates;  // isLong => rate
    mapping(bool => uint256) public override cumulativeFundingRates;
    mapping(bool => uint256) public lastFundingTimes;
    mapping(address => bool) public isManager;
    mapping(bytes32 => DataTypes.Position) public positions;
    mapping(address => uint256) public override globalLongSizes;
    mapping(address => uint256) public override globalShortSizes;
    mapping(address => bool) public collateralTokens;
    mapping(address => bool) public indexTokens;
    mapping(address => bool) public equityTokens;

    uint256 public vaultFee;
    mapping(address => uint256) public tradingPoints; // account => points
    mapping(address => uint256) public collectedTokenFees;
    mapping(address => address) public lPools;
    mapping(address => int256) public collectedTokenPnl; // token => pnl

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;

    modifier onlyManager {
        require(isManager[msg.sender], "Vault: forbidden");
        _;
    }

    constructor(
        address _priceFeed,
        uint256 _maxLeverage,
        uint256 _marginFeeBasisPoints,
        uint256 _longFundingRate,
        uint256 _shortFundingRate,
        uint256 _minProfitBasisPoints,
        uint256 _minProfitTime
    ) {
        priceFeed = _priceFeed;
        maxLeverage = _maxLeverage;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        fundingRates[true] = _longFundingRate;
        fundingRates[false] = _shortFundingRate;
        minProfitBasisPoints = _minProfitBasisPoints;
        minProfitTime = _minProfitTime;
    }

    /**
        * @param _account account to increase position for
        * @param _collateralToken token to use as collateral
        * @param _indexToken token to use as index
        * @param _sizeDelta size to increase position by
        * @param _isLong true if long, false if short
    */
    function increasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) public virtual override nonReentrant onlyManager {
        require(collateralTokens[_collateralToken], "invalid collateral token");
        require(indexTokens[_indexToken], "invalid index token");

        updateCumulativeFundingRate(_isLong);
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position storage position = positions[key];
        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken);
        if (position.size == 0)
            position.averagePrice = price;
        if (position.size > 0 && _sizeDelta > 0)
            position.averagePrice = getNextAveragePrice(_indexToken, position.size, position.averagePrice, _isLong, price, _sizeDelta, position.lastIncreasedTime);

        uint256 fee = _collectMarginFees(_account, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate);
        uint256 collateralDeltaUsd = tokenToUsd(_collateralToken, _collateralDelta);
        position.collateral = position.collateral.add(collateralDeltaUsd);
        require(position.collateral >= fee, "Vault: insufficient collateral for fees");
        position.collateral = position.collateral.sub(fee);
        position.entryFundingRate = cumulativeFundingRates[_isLong];
        position.size = position.size.add(_sizeDelta);
        position.lastIncreasedTime = block.timestamp;
        require(position.size > 0, "Vault: invalid position.size");
        _validatePosition(position.size, position.collateral);
        validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

        // increase global size
        if (_isLong) {
            globalLongSizes[_indexToken] = globalLongSizes[_indexToken].add(_sizeDelta);
        } else {
            globalShortSizes[_indexToken] = globalShortSizes[_indexToken].add(_sizeDelta);
        }
        emit Events.IncreasePosition(key, _account, _collateralToken, _indexToken, collateralDeltaUsd, _sizeDelta, _isLong, price, fee);
        emit Events.UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
    }

    /**
        * @param _account account to decrease position for
        * @param _collateralToken token to use as collateral
        * @param _indexToken token to use as index
        * @param _collateralDelta amount of collateral to withdraw
        * @param _sizeDelta size to decrease position by
        * @param _isLong true if long, false if short
        * @param _receiver receiver of tokens
        * @return amountOut amount of tokens received
    */
    function decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) public virtual override nonReentrant onlyManager returns (uint256) {
        return _decreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
    }

    /**
        * @param _account account to close position for
        * @param _collateralToken token to use as collateral
        * @param _indexToken token to use as index
        * @param _isLong true if long, false if short
    */
    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public virtual override nonReentrant onlyManager returns (uint256) {
        updateCumulativeFundingRate(_isLong);
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position storage position = positions[key];
        require(position.size > 0, "Vault: empty position");
        (uint256 liquidationState, uint256 marginFees, int256 _userDelta) = validateLiquidation(_account, _collateralToken, _indexToken, _isLong, false);
        require(liquidationState != 0, "Vault: position cannot be liquidated");
        if (liquidationState == 2) {
            return _decreasePosition(_account, _collateralToken, _indexToken, 0, position.size, _isLong, msg.sender);  // liq
        }
        position.realisedPnl += _userDelta;
        _collectFeeAndPoints(_account, _indexToken, marginFees);
        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        emit Events.LiquidatePosition(key, _account, _collateralToken, _indexToken, _isLong, position.size, position.collateral, position.reserveAmount, position.realisedPnl, markPrice);
        if (_isLong) {
            globalLongSizes[_indexToken] = globalLongSizes[_indexToken].sub(position.size);
        } else {
            globalShortSizes[_indexToken] = globalShortSizes[_indexToken].sub(position.size);
        }
        _updatePnl(_indexToken, position.realisedPnl);
        delete positions[key];
        return 0;
    }

    function validateLiquidation(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) public virtual view returns (uint256, uint256, int256 _userDelta) {
        (uint256 size, uint256 collateral, uint256 averagePrice, uint256 entryFundingRate, , , ,
            uint256 lastIncreasedTime) = getPosition(_account, _collateralToken, _indexToken, _isLong);
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, size, averagePrice, _isLong, lastIncreasedTime);
        _userDelta = hasProfit ? int256(delta) : - int256(delta);
        uint256 marginFees = getFundingFee(_isLong, size, entryFundingRate);
        marginFees = marginFees.add(getPositionFee(size));

        if (!hasProfit && collateral < delta) {
            if (_raise) {revert("Vault: losses exceed collateral");}
            return (1, 0, - int256(collateral));
        }
        uint256 remainingCollateral = collateral;
        if (!hasProfit) {
            remainingCollateral = collateral.sub(delta);
        }
        if (remainingCollateral < marginFees) {
            if (_raise) {revert("Vault: fees exceed collateral");}
            if (hasProfit) remainingCollateral = collateral.add(delta);
            return (3, remainingCollateral, _userDelta);
        }
        if (remainingCollateral.mul(maxLeverage) < size.mul(BASIS_POINTS_DIVISOR)) {
            if (_raise) {revert("Vault: maxLeverage exceeded");}
            return (2, 0, 0);
        }
        return (0, 0, 0);
    }

    function updateCumulativeFundingRate(bool _isLong) public virtual {
        if (lastFundingTimes[_isLong] == 0) {
            lastFundingTimes[_isLong] = block.timestamp.div(fundingInterval).mul(fundingInterval);
            return;
        }
        if (lastFundingTimes[_isLong].add(fundingInterval) > block.timestamp)
            return;
        uint256 fundingRate = getNextFundingRate(_isLong);
        cumulativeFundingRates[_isLong] = cumulativeFundingRates[_isLong].add(fundingRate);
        lastFundingTimes[_isLong] = block.timestamp.div(fundingInterval).mul(fundingInterval);
        emit Events.UpdateFundingRate(_isLong, cumulativeFundingRates[_isLong]);
    }

    function _decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) internal returns (uint256) {
        updateCumulativeFundingRate(_isLong);
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position storage position = positions[key];
        require(position.size > 0, "Vault: empty position");
        require(position.size >= _sizeDelta, "Vault: position size exceeded");
        require(position.collateral >= _collateralDelta, "Vault: position collateral exceeded");

        {
            uint256 reserveDelta = position.reserveAmount.mul(_sizeDelta).div(position.size);
            position.reserveAmount = position.reserveAmount.sub(reserveDelta);
        }
        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);
        if (position.size != _sizeDelta) {
            position.entryFundingRate = cumulativeFundingRates[_isLong];
            position.size = position.size.sub(_sizeDelta);
            _validatePosition(position.size, position.collateral);
            validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);
            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit Events.DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit Events.UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
        } else {
            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit Events.DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit Events.ClosePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);
            _updatePnl(_indexToken, position.realisedPnl);
            delete positions[key];
        }
        // decrease global size
        if (_isLong) {
            globalLongSizes[_indexToken] = globalLongSizes[_indexToken].sub(_sizeDelta);
        } else {
            globalShortSizes[_indexToken] = globalShortSizes[_indexToken].sub(_sizeDelta);
        }
        if (usdOut > 0) {
            uint256 amountOutAfterFees = usdToToken(_collateralToken, usdOutAfterFee);
            _transferOut(_collateralToken, amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        }
        return 0;
    }

    function _reduceCollateral(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) internal returns (uint256, uint256) {

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position storage position = positions[key];
        uint256 fee = _collectMarginFees(_account, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate);
        bool hasProfit;
        uint256 adjustedDelta;
        {
            (bool _hasProfit, uint256 delta) = getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
            hasProfit = _hasProfit;
            adjustedDelta = _sizeDelta.mul(delta).div(position.size);
        }
        uint256 usdOut;
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);
        }
        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral.sub(adjustedDelta);
            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }
        if (_collateralDelta > 0) {
            usdOut = usdOut.add(_collateralDelta);
            position.collateral = position.collateral.sub(_collateralDelta);
        }
        if (position.size == _sizeDelta) {
            usdOut = usdOut.add(position.collateral);
            position.collateral = 0;
        }
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut.sub(fee);
        } else {
            position.collateral = position.collateral.sub(fee);
        }
        emit Events.UpdatePnl(key, hasProfit, adjustedDelta);
        return (usdOut, usdOutAfterFee);
    }

    function _collectMarginFees(
        address _account,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _size,
        uint256 _entryFundingRate
    ) internal returns (uint256) {
        uint256 feeUsd = getPositionFee(_sizeDelta);
        uint256 fundingFee = getFundingFee(_isLong, _size, _entryFundingRate);
        feeUsd = feeUsd.add(fundingFee);
        _collectFeeAndPoints(_account, _indexToken, feeUsd);
        return feeUsd;
    }

    function _collectFeeAndPoints(address _account, address _indexToken, uint256 _fee) internal {
        vaultFee = vaultFee += _fee;
        tradingPoints[_account] += _fee;
        collectedTokenFees[_indexToken] += _fee;
    }

    function _updatePnl(address _indexToken, int256 _realisedPnl) internal {
        if (_realisedPnl == 0) return;
        collectedTokenPnl[_indexToken] -= _realisedPnl;
        if (_realisedPnl > 0) {
            uint256 _amount = _toUsdToken(usdToken, uint256(_realisedPnl));
            ILPool(lPools[_indexToken]).transfer(usdToken, _amount, address(this));
        } else {
            uint256 _amount = _toUsdToken(usdToken, uint256(- _realisedPnl));
            _transferOut(usdToken, _amount, lPools[_indexToken]);
        }
        emit Events.UpdateTokenPnl(_indexToken, - _realisedPnl);
    }

    function _toUsdToken(address _token, uint256 _amount) internal view returns (uint256) {
        return _amount / (10 ** (30 - IERC20Metadata(_token).decimals()));
    }

    function _transferOut(address _token, uint256 _amount, address _receiver) internal {
        IERC20(_token).safeTransfer(_receiver, _amount);
    }

    function _validatePosition(uint256 _size, uint256 _collateral) internal pure {
        if (_size == 0) {
            require(_collateral == 0, "Vault: collateral should be withdrawn");
            return;
        }
        require(_size >= _collateral, "Vault: _size must be more than _collateral");
    }

    function getNextAveragePrice(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        uint256 _lastIncreasedTime
    ) public view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime);
        uint256 nextSize = _size.add(_sizeDelta);
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize.add(delta) : nextSize.sub(delta);
        } else {
            divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);
        }
        return _nextPrice.mul(nextSize).div(divisor);
    }

    function getNextFundingRate(bool _isLong) public virtual override view returns (uint256) {
        if (lastFundingTimes[_isLong].add(fundingInterval) > block.timestamp)
            return 0;
        uint256 intervals = block.timestamp.sub(lastFundingTimes[_isLong]).div(fundingInterval);
        return fundingRates[_isLong].mul(intervals);
    }

    function getPositionKey(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public virtual pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _collateralToken, _indexToken, _isLong));
    }

    function getPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public virtual override view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0 ? uint256(position.realisedPnl) : uint256(- position.realisedPnl);
        return (position.size, position.collateral, position.averagePrice, position.entryFundingRate,
            position.reserveAmount, realisedPnl, position.realisedPnl >= 0, position.lastIncreasedTime);
    }

    function getPositionDelta(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public virtual view returns (bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position memory position = positions[key];
        return getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
    }

    function isPositionExist(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public virtual override view returns (bool exist, bytes32 key) {
        key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        exist = positions[key].size > 0;
    }

    function getFundingFee(bool _isLong, uint256 _size, uint256 _entryFundingRate) public virtual view returns (uint256) {
        if (_size == 0) return 0;
        uint256 fundingRate = cumulativeFundingRates[_isLong].sub(_entryFundingRate);
        if (fundingRate == 0) return 0;
        return _size.mul(fundingRate).div(FUNDING_RATE_PRECISION);
    }

    function getMaxPrice(address _token) public virtual override view returns (uint256) {
        if (equityTokens[_token])
            return IPriceFeed(priceFeed).getPrice(_token, true, false);
        return IPriceFeed(priceFeed).getPrice(_token, true, true);
    }

    function getMinPrice(address _token) public virtual override view returns (uint256) {
        if (equityTokens[_token])
            return IPriceFeed(priceFeed).getPrice(_token, false, false);
        return IPriceFeed(priceFeed).getPrice(_token, false, true);
    }

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public virtual view returns (bool, uint256) {
        require(_averagePrice > 0, "Vault: invalid _averagePrice");
        uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price ? _averagePrice.sub(price) : price.sub(_averagePrice);
        uint256 delta = _size.mul(priceDelta).div(_averagePrice);
        bool hasProfit;
        if (_isLong) {
            hasProfit = price > _averagePrice;
        } else {
            hasProfit = _averagePrice > price;
        }
        uint256 minBps = block.timestamp > _lastIncreasedTime.add(minProfitTime) ? 0 : minProfitBasisPoints;
        if (hasProfit && delta.mul(BASIS_POINTS_DIVISOR) <= _size.mul(minBps)) {
            delta = 0;
        }
        return (hasProfit, delta);
    }

    function usdToToken(address _token, uint256 _usdAmount) public virtual view returns (uint256) {
        if (_usdAmount == 0) return 0;
        return _usdAmount.mul(10 ** IERC20Metadata(_token).decimals()).div(getMaxPrice(_token));
    }

    function tokenToUsd(address _token, uint256 _tokenAmount) public virtual override view returns (uint256) {
        if (_tokenAmount == 0) return 0;
        return _tokenAmount.mul(getMinPrice(_token)).div(10 ** IERC20Metadata(_token).decimals());
    }

    function getPositionFee(uint256 _sizeDelta) public virtual view returns (uint256) {
        if (_sizeDelta == 0) return 0;
        return _sizeDelta.mul(marginFeeBasisPoints).div(BASIS_POINTS_DIVISOR);
    }

    function setManager(address _manager, bool _isManager) public virtual onlyOwner {
        isManager[_manager] = _isManager;
    }

    function setPriceFeed(address _priceFeed) public virtual onlyOwner {
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage) public virtual onlyOwner {
        require(_maxLeverage > 10000, "Vault: invalid _maxLeverage");
        maxLeverage = _maxLeverage;
    }

    function setMarginFeeBasisPoints(uint256 _marginFeeBasisPoints) public virtual onlyOwner {
        require(_marginFeeBasisPoints <= 500, "Vault: invalid _marginFeeBasisPoints"); // 5%
        marginFeeBasisPoints = _marginFeeBasisPoints;
    }

    function setMinProfit(uint256 _minProfitBasisPoints, uint256 _minProfitTime) public virtual onlyOwner {
        minProfitBasisPoints = _minProfitBasisPoints;
        minProfitTime = _minProfitTime;
    }

    function setFundingRate(uint256 _fundingInterval, uint256 _longFundingRate, uint256 _shortFundingRate) public virtual onlyOwner {
        fundingInterval = _fundingInterval;
        fundingRates[true] = _longFundingRate;
        fundingRates[false] = _shortFundingRate;
    }

    function setCollateralToken(address _token, bool _isCollateral) public virtual onlyOwner {
        collateralTokens[_token] = _isCollateral;
    }

    function setIndexTokens(address[] calldata _tokens, bool[] calldata _isIndex) public virtual onlyOwner {
        require(_tokens.length == _isIndex.length, "Vault: invalid params");
        for (uint256 i = 0; i < _tokens.length; i++)
            indexTokens[_tokens[i]] = _isIndex[i];
    }

    function setEquityToken(address _token, bool _isEquity) public virtual onlyOwner {
        equityTokens[_token] = _isEquity;
    }

    function setLPools(address[] calldata _indexTokens, address[] calldata _lPools) public virtual onlyOwner {
        require(_indexTokens.length == _lPools.length, "Vault: invalid params");
        for (uint256 i = 0; i < _indexTokens.length; i++)
            lPools[_indexTokens[i]] = _lPools[i];
    }

    function setUsdToken(address _usdToken) public virtual onlyOwner {
        usdToken = _usdToken;
    }

    function distributeFee(address[] calldata receivers, uint256[] calldata ratios) public virtual onlyOwner {
        require(receivers.length == ratios.length, "Vault: invalid params");

        uint256 _totalRatio;
        uint256 _amount = _toUsdToken(usdToken, vaultFee);
        for (uint256 i = 0; i < ratios.length; i++) {
            _totalRatio += ratios[i];
            IERC20(usdToken).transfer(receivers[i], _amount * ratios[i] / 10000);
        }
        require(_totalRatio == 10000, "FeeManager: invalid ratios");
        vaultFee = 0;
    }

}
