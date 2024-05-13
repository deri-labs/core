// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IERC20Extended.sol";
import "../interfaces/IBlastPoints.sol";

contract USDPool is ReentrancyGuard, Pausable, Ownable {

    using SafeERC20 for IERC20;

    IERC20Extended public usdToken;
    mapping(address => bool) public whitelistTokens;
    uint256 public exchangeAmount;
    uint256 public cap;
    uint256 public fee; // 10000 = 100%
    bool public isNativeExchange;

    event Exchange(address indexed account, address indexed _tokenIn, uint256 _amountIn, uint256 _usdAmount);
    event Redeem(address indexed account, address indexed _tokenOut, uint256 _amountOut, uint256 _usdAmount);

    constructor(address _usdToken, uint256 _cap, address _defaultWhitelistToken) {
        usdToken = IERC20Extended(_usdToken);
        cap = _cap;
        whitelistTokens[_defaultWhitelistToken] = true;
    }

    function exchange(address _tokenIn, uint256 _amountIn) public virtual nonReentrant whenNotPaused {
        require(!isNativeExchange, "USDPool: non-native exchange is not allowed");
        require(_amountIn > 0, "USDPool: amount must be greater than zero");
        require(whitelistTokens[_tokenIn], "USDPool: token not in whitelist");
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);

        uint256 _amountD18 = _toD18(_tokenIn, _amountIn);
        require(exchangeAmount + _amountD18 <= cap, "USDPool: cap exceeded");

        exchangeAmount += _amountD18;
        uint256 _amountOut = _amountD18 * (10000 - fee) / 10000;
        usdToken.mint(msg.sender, _amountOut);
        if (fee > 0) usdToken.mint(owner(), _amountD18 - _amountOut);
        emit Exchange(msg.sender, _tokenIn, _amountIn, _amountOut);
    }

    function redeem(address _tokenOut, uint256 _amount, address _receiver) public virtual nonReentrant {
        require(!isNativeExchange, "USDPool: non-native redeem is not allowed");
        require(_amount > 0, "USDPool: amount must be greater than zero");
        require(_receiver != address(0), "USDPool: receiver can not be zero address");
        IERC20Extended(usdToken).burn(msg.sender, _amount);

        uint256 _amountOut = _toD(_tokenOut, _amount);
        exchangeAmount = exchangeAmount >= _amount ? exchangeAmount - _amount : 0;
        IERC20(_tokenOut).safeTransfer(_receiver, _amountOut);
        emit Redeem(msg.sender, _tokenOut, _amountOut, _amount);
    }

    function exchangeNative() public virtual payable nonReentrant whenNotPaused {
        require(isNativeExchange, "USDPool: native exchange is not allowed");
        require(msg.value > 0, "USDPool: amount must be greater than zero");

        require(exchangeAmount + msg.value <= cap, "USDPool: cap exceeded");

        exchangeAmount += msg.value;
        uint256 _amountOut = msg.value * (10000 - fee) / 10000;
        usdToken.mint(msg.sender, _amountOut);
        if (fee > 0) usdToken.mint(owner(), msg.value - _amountOut);
        emit Exchange(msg.sender, address(0), msg.value, _amountOut);
    }

    function redeemNative(uint256 _amount) public virtual payable nonReentrant {
        require(isNativeExchange, "USDPool: native redeem is not allowed");
        require(_amount > 0, "USDPool: amount must be greater than zero");
        IERC20Extended(usdToken).burn(msg.sender, _amount);

        exchangeAmount = exchangeAmount >= _amount ? exchangeAmount - _amount : 0;
        _transferOutNative(msg.sender, _amount);
        emit Redeem(msg.sender, address(0), _amount, _amount);
    }

    function setWhitelistToken(address _token, bool _enabled) public virtual onlyOwner {
        whitelistTokens[_token] = _enabled;
    }

    function setCap(uint256 _cap) public virtual onlyOwner {
        cap = _cap;
    }

    function setFee(uint256 _fee) public virtual onlyOwner {
        fee = _fee;
    }

    function setNativeExchange(bool _isNativeExchange) public virtual onlyOwner {
        isNativeExchange = _isNativeExchange;
    }

    function setPaused(bool _paused) public virtual onlyOwner {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
    }

    function transfer(address _token, address _to, uint256 _amount) public virtual onlyOwner {
        if (_token != address(0))
            IERC20(_token).safeTransfer(_to, _amount);
        else
            _transferOutNative(_to, _amount);
    }

    function configurePointsOperator(address _blastPointsAddr, address _pointsOperator) public virtual onlyOwner {
        IBlastPoints(_blastPointsAddr).configurePointsOperator(_pointsOperator);
    }

    function _transferOutNative(address _to, uint256 _amount) internal {
        (bool sent,) = _to.call{value: _amount}("");
        require(sent, "USDPool: Failed to send native token.");
    }

    function _toD18(address token, uint256 _amount) internal view returns (uint256) {
        uint256 _decimals = IERC20Metadata(token).decimals();
        if (_decimals == 18) return _amount;
        return _amount * (10 ** (18 - _decimals));
    }

    function _toD(address token, uint256 _amount) internal view returns (uint256) {
        uint256 _decimals = IERC20Metadata(token).decimals();
        if (_decimals == 18) return _amount;
        return _amount / (10 ** (18 - _decimals));
    }

    receive() external payable {}
}
