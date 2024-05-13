// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPositionManager.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IOrderBook.sol";
import "./interfaces/IPriceFeed.sol";
import "./libraries/Events.sol";

contract PositionManager is IPositionManager, ReentrancyGuard, Ownable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public vault;
    address public orderBook;
    address public priceFeed;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    mapping(address => uint256) public override maxGlobalLongSizes;
    mapping(address => uint256) public override maxGlobalShortSizes;

    uint256 public minLiquidationFee;
    mapping(bytes32 => uint256) public liquidationFees;
    mapping(address => bool) public isKeeper;

    constructor(address _vault, address _priceFeed, uint256 _minLiquidationFee) {
        vault = _vault;
        priceFeed = _priceFeed;
        minLiquidationFee = _minLiquidationFee;
    }

    function _update(bytes[] calldata _updateData, address _token) internal returns (uint256 _fee) {
        if (_updateData.length == 0) return 0;
        _fee = IPriceFeed(priceFeed).getUpdateFee(_updateData, _token);
        require(msg.value >= _fee, "PositionManager: insufficient fee");
        IPriceFeed(priceFeed).updatePriceFeeds{value: _fee}(_updateData, _token);
    }

    /**
        * @param _collateralToken collateral token
        * @param _indexToken index token
        * @param _collateralDelta collateral delta which is being deposited
        * @param _sizeDelta size delta
        * @param _isLong is long if true, short if false
        * @param _acceptablePrice acceptable price of index token
        * @param _updateData price update data
    */
    function increasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        bytes[] calldata _updateData
    ) public virtual payable nonReentrant {
        uint256 _fee = _update(_updateData, _indexToken);
        _preChargeFee(msg.sender, _collateralToken, _indexToken, _isLong, _fee);
        IERC20(_collateralToken).safeTransferFrom(msg.sender, vault, _collateralDelta);
        address _vault = vault;
        uint256 markPrice = _isLong ? IVault(_vault).getMaxPrice(_indexToken) : IVault(_vault).getMinPrice(_indexToken);
        if (_isLong) {
            require(markPrice <= _acceptablePrice, "PositionManager: mark price higher than limit");
        } else {
            require(markPrice >= _acceptablePrice, "PositionManager: mark price lower than limit");
        }
        _validateMaxGlobalSize(_indexToken, _isLong, _sizeDelta);
        IVault(_vault).increasePosition(msg.sender, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);
    }

    /**
        * @param _collateralToken collateral token
        * @param _indexToken index token
        * @param _collateralDelta collateral delta which is being withdrawn
        * @param _sizeDelta size delta
        * @param _isLong is long if true, short if false
        * @param _receiver receiver of the tokens
        * @param _acceptablePrice acceptable price of index token
        * @param _updateData data to update
    */
    function decreasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        bytes[] calldata _updateData
    ) public virtual payable nonReentrant {
        _update(_updateData, _indexToken);
        address _vault = vault;
        uint256 markPrice = _isLong ? IVault(_vault).getMinPrice(_indexToken) : IVault(_vault).getMaxPrice(_indexToken);
        if (_isLong) {
            require(markPrice >= _acceptablePrice, "PositionManager: mark price lower than limit");
        } else {
            require(markPrice <= _acceptablePrice, "PositionManager: mark price higher than limit");
        }
        uint256 amountOut = IVault(_vault).decreasePosition(msg.sender, _collateralToken, _indexToken, _collateralDelta,
            _sizeDelta, _isLong, address(this));
        IERC20(_collateralToken).safeTransfer(_receiver, amountOut);
        _payFee(msg.sender, _collateralToken, _indexToken, _isLong, payable(msg.sender));
    }

    /**
        * @param _account account to liquidate
        * @param _collateralToken collateral token
        * @param _indexToken index token
        * @param _isLong is long if true, short if false
        * @param _updateData data to update
    */
    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        address payable _feeReceiver,
        bytes[] calldata _updateData
    ) public virtual payable nonReentrant {
        require(isKeeper[msg.sender] || msg.sender == _account, "PositionManager: forbidden");
        _update(_updateData, _indexToken);
        uint256 _amount = IVault(vault).liquidatePosition(_account, _collateralToken, _indexToken, _isLong);
        if (_amount > 0)
            IERC20(_collateralToken).safeTransfer(_account, _amount);
        _payFee(_account, _collateralToken, _indexToken, _isLong, _feeReceiver);
    }

    /**
        * @param _account account to liquidate
        * @param _orderIndex order index which is being liquidated
        * @param _feeReceiver receiver of the fee
        * @param _updateData data to update which is being liquidated
    */
    function executeIncreaseOrder(
        address _account,
        uint256 _orderIndex,
        address payable _feeReceiver,
        bytes[] calldata _updateData
    ) public virtual payable {
        require(isKeeper[msg.sender], "PositionManager: forbidden");
        (,,address _indexToken,,,,,)= IOrderBook(orderBook).getIncreaseOrder(_account, _orderIndex);
        _update(_updateData, _indexToken);
        _validateIncreaseOrder(_account, _orderIndex);
        IOrderBook(orderBook).executeIncreaseOrder(_account, _orderIndex, _feeReceiver);
    }

    /**
        * @param _account account to liquidate
        * @param _orderIndex order index which is being liquidated
        * @param _feeReceiver receiver of the fee
        * @param _updateData data to update which is being liquidated
    */
    function executeDecreaseOrder(
        address _account,
        uint256 _orderIndex,
        address payable _feeReceiver,
        bytes[] calldata _updateData
    ) public virtual payable {
        require(isKeeper[msg.sender], "PositionManager: forbidden");
        (,,address _indexToken,,,,,)= IOrderBook(orderBook).getDecreaseOrder(_account, _orderIndex);
        _update(_updateData, _indexToken);
        IOrderBook(orderBook).executeDecreaseOrder(_account, _orderIndex, _feeReceiver);
    }

    function _validateIncreaseOrder(address _account, uint256 _orderIndex) internal view {
        (
            uint256 _collateralDelta,
            address _collateralToken,
            address _indexToken,
            uint256 _sizeDelta,
            bool _isLong,
            , // triggerPrice
            , // triggerAboveThreshold
        // executionFee
        ) = IOrderBook(orderBook).getIncreaseOrder(_account, _orderIndex);

        _validateMaxGlobalSize(_indexToken, _isLong, _sizeDelta);

        // shorts are okay
        if (!_isLong) {return;}

        // if the position size is not increasing, this is a collateral deposit
        require(_sizeDelta > 0, "PositionManager: long deposit");

        IVault _vault = IVault(vault);
        (uint256 size, uint256 collateral, , , , , ,) = _vault.getPosition(_account, _collateralToken, _indexToken, _isLong);

        // if there is no existing position, do not charge a fee
        if (size == 0) {return;}

        uint256 nextSize = size.add(_sizeDelta);
        uint256 collateralDelta = _vault.tokenToUsd(_collateralToken, _collateralDelta);
        uint256 nextCollateral = collateral.add(collateralDelta);
        uint256 prevLeverage = size.mul(BASIS_POINTS_DIVISOR).div(collateral);
        uint256 nextLeverage = nextSize.mul(BASIS_POINTS_DIVISOR).div(nextCollateral);
        require(nextLeverage >= prevLeverage, "PositionManager: long leverage decrease");
    }

    function _preChargeFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _paid) internal {
        if (minLiquidationFee == 0)
            return;
        (bool exist, bytes32 key) = IVault(vault).isPositionExist(_account, _collateralToken, _indexToken, _isLong);
        if (!exist) {
            uint256 liqFee = msg.value - _paid;
            require(liqFee >= minLiquidationFee, "PositionManager: insufficient fee");
            liquidationFees[key] = liqFee;
        }
    }

    function _payFee(address _account, address _collateralToken, address _indexToken, bool _isLong, address payable _feeReceiver) internal {
        (bool exist, bytes32 key) = IVault(vault).isPositionExist(_account, _collateralToken, _indexToken, _isLong);
        uint256 _payAmount = liquidationFees[key];
        if (!exist && _payAmount > 0) {
            liquidationFees[key] = 0;
            _transferOutETH(_payAmount, _feeReceiver);
        }
    }

    function _validateMaxGlobalSize(address _indexToken, bool _isLong, uint256 _sizeDelta) internal view {
        if (_sizeDelta == 0) {
            return;
        }
        if (_isLong) {
            if (IVault(vault).globalLongSizes(_indexToken).add(_sizeDelta) > maxGlobalLongSizes[_indexToken])
                revert("PositionManager: max global longs exceeded");
        } else {
            if (IVault(vault).globalShortSizes(_indexToken).add(_sizeDelta) > maxGlobalShortSizes[_indexToken])
                revert("PositionManager: max global shorts exceeded");
        }
    }

    function _transferOutETH(uint256 _amountOut, address payable _receiver) internal {
        (bool sent,) = _receiver.call{value: _amountOut}("");
        require(sent, "PositionManager: failed to transfer out ether");
    }

    function setKeeper(address _account, bool _isActive) public virtual onlyOwner {
        isKeeper[_account] = _isActive;
    }

    function setOrderBook(address _orderBook) public virtual onlyOwner {
        orderBook = _orderBook;
    }

    function setMaxGlobalSizes(address[] memory _tokens, uint256[] memory _longSizes, uint256[] memory _shortSizes) public virtual onlyOwner {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            maxGlobalLongSizes[token] = _longSizes[i];
            maxGlobalShortSizes[token] = _shortSizes[i];
        }
    }

    function setMinLiquidationFee(uint256 _minLiquidationFee) public virtual onlyOwner {
        minLiquidationFee = _minLiquidationFee;
    }

    receive() external payable {}
}
