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

contract LPool is ReentrancyGuard, Pausable, Ownable {

    using SafeERC20 for IERC20;

    IERC20Extended public lpToken;
    mapping(address => bool) public whitelistTokens;
    address[] public tokenList;
    uint256 public cap;
    uint256 public fee; // 10000 = 100%
    mapping(address => bool) public isManager;

    event BuyLP(address indexed account, address indexed _tokenIn, uint256 _amountIn, uint256 _usdAmount);
    event RedeemLP(address indexed account, address indexed _tokenOut, uint256 _amountOut, uint256 _usdAmount);

    constructor(address _lpToken, uint256 _cap, address _defaultWhitelistToken) {
        lpToken = IERC20Extended(_lpToken);
        cap = _cap;
        setWhitelistToken(_defaultWhitelistToken, true);
    }

    function buyLP(address _tokenIn, uint256 _amountIn) external payable nonReentrant whenNotPaused {
        require(_amountIn > 0, "LPool: amount must be greater than zero");
        require(whitelistTokens[_tokenIn], "LPool: token not in whitelist");

        uint256 _aum = aum();
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);

        uint256 _amountD18 = _toD18(_tokenIn, _amountIn);
        _amountD18 = _aum == 0 ? _amountD18 : _amountD18 * lpToken.totalSupply() / _aum;
        require(lpToken.totalSupply() + _amountD18 <= cap, "LPool: cap exceeded");

        uint256 _amountOut = _amountD18 * (10000 - fee) / 10000;
        lpToken.mint(msg.sender, _amountOut);
        if (fee > 0) lpToken.mint(owner(), _amountD18 - _amountOut);
        emit BuyLP(msg.sender, _tokenIn, _amountIn, _amountD18);
    }

    function redeemLP(address _tokenOut, uint256 _amount) external payable nonReentrant {
        require(_amount > 0, "LPool: amount must be greater than zero");

        uint256 _aum = aum();
        uint256 _amountD18 = _amount * _aum / lpToken.totalSupply();
        IERC20Extended(lpToken).burn(msg.sender, _amount);

        uint256 _amountOut = _toD(_tokenOut, _amountD18);
        IERC20(_tokenOut).safeTransfer(msg.sender, _amountOut);
        emit RedeemLP(msg.sender, _tokenOut, _amountOut, _amountD18);
    }

    function aum() public view returns (uint256 _aum) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address _token = tokenList[i];
            uint256 _balance = IERC20(_token).balanceOf(address(this));
            if (_balance > 0)
                _aum += _toD18(_token, _balance);
        }
    }

    function lpPrice() external view returns (uint256) {
        uint256 _aum = aum();
        if (_aum == 0) return 10 ** 8;
        return aum() * 10 ** 8 / lpToken.totalSupply(); // d8
    }

    function setWhitelistToken(address _token, bool _enabled) public onlyOwner {
        whitelistTokens[_token] = _enabled;
        bool _match = false;
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokenList[i] == _token) {
                _match = true;
                if (!_enabled) {
                    tokenList[i] = tokenList[tokenList.length - 1];
                    tokenList.pop();
                }
                return;
            }
        }
        if (!_match && _enabled) tokenList.push(_token);
    }

    function setCap(uint256 _cap) external onlyOwner {
        cap = _cap;
    }

    function setFee(uint256 _fee) external onlyOwner {
        fee = _fee;
    }

    function setPaused(bool _paused) external onlyOwner {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
    }

    function setManager(address manager, bool enabled) external onlyOwner {
        isManager[manager] = enabled;
    }

    function transfer(address _token, uint256 _amount, address _receiver) external {
        require(isManager[msg.sender], "LPool: not manager");
        IERC20(_token).safeTransfer(_receiver, _amount);
    }

    function configurePointsOperator(address _blastPointsAddr, address _pointsOperator) external onlyOwner {
        IBlastPoints(_blastPointsAddr).configurePointsOperator(_pointsOperator);
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

}
