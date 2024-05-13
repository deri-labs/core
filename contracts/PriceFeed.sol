// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@deri-labs/x-oracle/contracts/interfaces/IXOracle.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPriceFeed.sol";

contract PriceFeed is IPriceFeed, Ownable {

    IPyth public pyth;
    IXOracle public xOracle;
    uint256 public validTime;
    mapping(address => bytes32) public feedIds;
    mapping(address => bool) public isStableToken;

    constructor() {
        validTime = 3 seconds;
    }

    function getPrice(address _token, bool _maximise, bool _fresh) external override view returns (uint256) {
        if (isStableToken[_token])
            return 1e30;
        bytes32 _feedId = feedIds[_token];
        if (_feedId == 0)
            return getPriceFromXOracle(_token, _maximise, _fresh);
        else
            return getPriceFromPyth(_feedId, _maximise, _fresh);
    }

    function getPriceFromXOracle(address _token, bool _maximise, bool _fresh) internal view returns (uint256) {
        IXOracle.PriceStruct memory _feed = xOracle.getPrice(_token);
        require(_feed.price > 0, "PriceFeed: xOracle price not available");
        if (_fresh && block.timestamp > _feed.timestamp)
            require(block.timestamp - _feed.timestamp <= validTime, "PriceFeed: xOracle price too old");

        uint256 _price = uint256(_feed.price);
        uint256 _confidence = uint256(_feed.conf);
        uint256 _decimals = 30 - uint256(_feed.decimals);
        _price = _maximise ? _price + _confidence : _price - _confidence;
        return _price * 10 ** _decimals;
    }

    function getPriceFromPyth(bytes32 _feedId, bool _maximise, bool _fresh) internal view returns (uint256) {
        PythStructs.Price memory _feed = pyth.getPriceUnsafe(_feedId);
        require(_feed.price > 0, "PriceFeed: pyth price not available");
        if (_fresh && block.timestamp > _feed.publishTime)
            require(block.timestamp - _feed.publishTime <= validTime, "PriceFeed: pyth price too old");

        uint256 _price = abs(_feed.price);
        uint256 _confidence = uint256(_feed.conf);
        uint256 _exponent = 30 - abs(_feed.expo);
        _price = _maximise ? _price + _confidence : _price - _confidence;
        return _price * 10 ** _exponent;
    }

    function latestTime(address _token) external view returns (uint256 _diff) {
        PythStructs.Price memory _feed = pyth.getPriceUnsafe(feedIds[_token]);
        _diff = block.timestamp - _feed.publishTime;
    }

    function getUpdateFee(bytes[] calldata _updateData, address _token) external override view returns (uint256) {
        if (feedIds[_token] == 0)
            return 0;
        return pyth.getUpdateFee(_updateData);
    }

    function updatePriceFeeds(bytes[] calldata _updateData, address _token) external override payable {
        if (feedIds[_token] == 0)
            xOracle.updatePrice(_updateData);
        else
            pyth.updatePriceFeeds{value: msg.value}(_updateData);
    }

    function setPyth(address _pyth) external onlyOwner {
        pyth = IPyth(_pyth);
    }

    function setXOracle(address _xOracle) external onlyOwner {
        xOracle = IXOracle(_xOracle);
    }

    function setValidTime(uint256 _validTime) external onlyOwner {
        validTime = _validTime;
    }

    function setFeedIds(address[] calldata _tokens, bytes32[] calldata _feedIds) external onlyOwner {
        require(_tokens.length == _feedIds.length, "PriceFeed: invalid feedIds");
        for (uint256 i = 0; i < _tokens.length; i++)
            feedIds[_tokens[i]] = _feedIds[i];
    }

    function abs(int256 n) internal pure returns (uint256) {
        unchecked {
            return uint256(n >= 0 ? n : - n);
        }
    }

    function setStableToken(address _token, bool _isStableToken) external onlyOwner {
        isStableToken[_token] = _isStableToken;
    }

}
