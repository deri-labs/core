// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IOrderBook.sol";
import "./libraries/DataTypes.sol";
import "./libraries/Events.sol";
import "./interfaces/IVault.sol";

contract OrderBook is ReentrancyGuard, IOrderBook, Ownable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public vault;
    uint256 public minExecutionFee;

    mapping(address => mapping(uint256 => DataTypes.IncreaseOrder)) public increaseOrders; // account => index => order
    mapping(address => uint256) public increaseOrdersIndex; // account => latest index
    mapping(address => mapping(uint256 => DataTypes.DecreaseOrder)) public decreaseOrders;
    mapping(address => uint256) public decreaseOrdersIndex;

    constructor(address _vault, uint256 _minExecutionFee) {
        vault = _vault;
        minExecutionFee = _minExecutionFee;
    }

    function createIncreaseOrder(
        uint256 _collateralDelta,
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) public virtual payable nonReentrant {
        require(msg.value >= minExecutionFee, "OrderBook: insufficient execution fee");
        IERC20(_collateralToken).transferFrom(msg.sender, address(this), _collateralDelta);
        uint256 _orderIndex = increaseOrdersIndex[msg.sender];
        DataTypes.IncreaseOrder memory order = DataTypes.IncreaseOrder(
            msg.sender,
            _collateralDelta,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value
        );
        increaseOrdersIndex[msg.sender] = _orderIndex.add(1);
        increaseOrders[msg.sender][_orderIndex] = order;

        emit Events.CreateIncreaseOrder(
            msg.sender,
            _orderIndex,
            _collateralDelta,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value
        );
    }

    function updateIncreaseOrder(
        uint256 _orderIndex,
        uint256 _sizeDelta,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) public virtual nonReentrant {
        DataTypes.IncreaseOrder storage order = increaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;
        order.sizeDelta = _sizeDelta;

        emit Events.UpdateIncreaseOrder(
            msg.sender,
            _orderIndex,
            order.collateralToken,
            order.indexToken,
            order.isLong,
            _sizeDelta,
            _triggerPrice,
            _triggerAboveThreshold
        );
    }

    function cancelIncreaseOrder(uint256 _orderIndex) public virtual nonReentrant {
        DataTypes.IncreaseOrder memory order = increaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");
        delete increaseOrders[msg.sender][_orderIndex];
        IERC20(order.collateralToken).safeTransfer(msg.sender, order.collateralDelta);
        _transferOutETH(order.executionFee, msg.sender);
        emit Events.CancelIncreaseOrder(
            order.account,
            _orderIndex,
            order.collateralDelta,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee
        );
    }

    function executeIncreaseOrder(address _address, uint256 _orderIndex, address payable _feeReceiver) override public virtual nonReentrant {
        DataTypes.IncreaseOrder memory order = increaseOrders[_address][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");
        // increase long should use max price
        // increase short should use min price
        (uint256 currentPrice,) = validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.indexToken,
            order.isLong,
            true
        );
        delete increaseOrders[_address][_orderIndex];
        IERC20(order.collateralToken).safeTransfer(vault, order.collateralDelta);
        IVault(vault).increasePosition(order.account, order.collateralToken, order.indexToken, order.collateralDelta, order.sizeDelta, order.isLong);
        // pay executor
        _transferOutETH(order.executionFee, _feeReceiver);
        emit Events.ExecuteIncreaseOrder(
            order.account,
            _orderIndex,
            order.collateralDelta,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee,
            currentPrice
        );
    }

    function createDecreaseOrder(
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        uint256 _collateralDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) public virtual payable nonReentrant {
        require(msg.value >= minExecutionFee, "OrderBook: insufficient fee");
        uint256 _orderIndex = decreaseOrdersIndex[msg.sender];
        DataTypes.DecreaseOrder memory order = DataTypes.DecreaseOrder(
            msg.sender,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value
        );
        decreaseOrdersIndex[msg.sender] = _orderIndex.add(1);
        decreaseOrders[msg.sender][_orderIndex] = order;

        emit Events.CreateDecreaseOrder(
            msg.sender,
            _orderIndex,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value
        );
    }

    function updateDecreaseOrder(
        uint256 _orderIndex,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) public virtual nonReentrant {
        DataTypes.DecreaseOrder storage order = decreaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");
        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;
        order.sizeDelta = _sizeDelta;
        order.collateralDelta = _collateralDelta;

        emit Events.UpdateDecreaseOrder(
            msg.sender,
            _orderIndex,
            order.collateralToken,
            _collateralDelta,
            order.indexToken,
            _sizeDelta,
            order.isLong,
            _triggerPrice,
            _triggerAboveThreshold
        );
    }

    function cancelDecreaseOrder(uint256 _orderIndex) public virtual nonReentrant {
        DataTypes.DecreaseOrder memory order = decreaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");
        delete decreaseOrders[msg.sender][_orderIndex];
        _transferOutETH(order.executionFee, msg.sender);
        emit Events.CancelDecreaseOrder(
            order.account,
            _orderIndex,
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee
        );
    }

    function executeDecreaseOrder(address _address, uint256 _orderIndex, address payable _feeReceiver) override public virtual nonReentrant {
        DataTypes.DecreaseOrder memory order = decreaseOrders[_address][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");
        // decrease long should use min price
        // decrease short should use max price
        (uint256 currentPrice,) = validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.indexToken,
            !order.isLong,
            true
        );
        delete decreaseOrders[_address][_orderIndex];
        uint256 amountOut = IVault(vault).decreasePosition(
            order.account,
            order.collateralToken,
            order.indexToken,
            order.collateralDelta,
            order.sizeDelta,
            order.isLong,
            address(this)
        );
        // transfer released collateral to user
        // if (order.collateralToken == weth) _transferOutETH(amountOut, payable(order.account)); else
        IERC20(order.collateralToken).safeTransfer(order.account, amountOut);
        // pay executor
        _transferOutETH(order.executionFee, _feeReceiver);
        emit Events.ExecuteDecreaseOrder(
            order.account,
            _orderIndex,
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee,
            currentPrice
        );
    }

    function cancelMultiple(uint256[] memory _increaseOrderIndexes, uint256[] memory _decreaseOrderIndexes) public virtual {
        for (uint256 i = 0; i < _increaseOrderIndexes.length; i++) {
            cancelIncreaseOrder(_increaseOrderIndexes[i]);
        }
        for (uint256 i = 0; i < _decreaseOrderIndexes.length; i++) {
            cancelDecreaseOrder(_decreaseOrderIndexes[i]);
        }
    }

    function _transferOutETH(uint256 _amountOut, address _receiver) private {
        (bool sent,) = _receiver.call{value: _amountOut}("");
        require(sent, "OrderBook: failed to send ETH");
    }

    function getIncreaseOrder(address _account, uint256 _orderIndex) override public virtual view returns (
        uint256 collateralDelta,
        address collateralToken,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    ) {
        DataTypes.IncreaseOrder memory order = increaseOrders[_account][_orderIndex];
        return (
            order.collateralDelta,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee
        );
    }

    function getDecreaseOrder(address _account, uint256 _orderIndex) override public virtual view returns (
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    ) {
        DataTypes.DecreaseOrder memory order = decreaseOrders[_account][_orderIndex];
        return (
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee
        );
    }

    function validatePositionOrderPrice(
        bool _triggerAboveThreshold,
        uint256 _triggerPrice,
        address _indexToken,
        bool _maximizePrice,
        bool _raise
    ) public view returns (uint256, bool) {
        uint256 currentPrice = _maximizePrice ? IVault(vault).getMaxPrice(_indexToken) : IVault(vault).getMinPrice(_indexToken);
        bool isPriceValid = _triggerAboveThreshold ? currentPrice > _triggerPrice : currentPrice < _triggerPrice;
        if (_raise)
            require(isPriceValid, "OrderBook: invalid price for execution");
        return (currentPrice, isPriceValid);
    }

    function setMinExecutionFee(uint256 _minExecutionFee) public virtual onlyOwner {
        minExecutionFee = _minExecutionFee;
    }

    receive() external payable {}
}
