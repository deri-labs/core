// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IPriceFeed.sol";
import "../interfaces/IPositionManager.sol";
import "../interfaces/IOrderBook.sol";

contract Reader {

    using SafeMath for uint256;

    struct Vars {
        uint256 i;
        uint256 index;
        address account;
        uint256 uintLength;
        uint256 addressLength;
    }

    function getVaultTokenInfo(address _vault, address _positionManager, address[] memory _tokens) public view returns (uint256[] memory) {
        uint256 propsLength = 6;
        IVault vault = IVault(_vault);
        IPositionManager positionManager = IPositionManager(_positionManager);
        uint256[] memory amounts = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            amounts[i * propsLength] = positionManager.maxGlobalLongSizes(token);
            amounts[i * propsLength + 1] = positionManager.maxGlobalShortSizes(token);
            amounts[i * propsLength + 2] = vault.globalLongSizes(token);
            amounts[i * propsLength + 3] = vault.globalShortSizes(token);
            amounts[i * propsLength + 4] = vault.minProfitBasisPoints();
            amounts[i * propsLength + 5] = vault.minProfitTime();
        }
        return amounts;
    }

    function getFundingRates(address _vault) public view returns (uint256[] memory) {
        uint256[] memory fundingRates = new uint256[](4);
        IVault vault = IVault(_vault);
        fundingRates[0] = vault.fundingRates(true);
        fundingRates[1] = vault.cumulativeFundingRates(true) + vault.getNextFundingRate(true);
        fundingRates[2] = vault.fundingRates(false);
        fundingRates[3] = vault.cumulativeFundingRates(false) + vault.getNextFundingRate(false);
        return fundingRates;
    }

    function getTokenBalances(address _account, address[] memory _tokens) public view returns (uint256[] memory) {
        uint256[] memory balances = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                balances[i] = _account.balance;
                continue;
            }
            balances[i] = IERC20(token).balanceOf(_account);
        }
        return balances;
    }

    function getPositions(address _vault, address _account, address[] memory _collateralTokens, address[] memory _indexTokens, bool[] memory _isLong) public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](_collateralTokens.length * 9);
        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            {
                (uint256 size,
                    uint256 collateral,
                    uint256 averagePrice,
                    uint256 entryFundingRate,
                /* reserveAmount */,
                    uint256 realisedPnl,
                    bool hasRealisedProfit,
                    uint256 lastIncreasedTime) = IVault(_vault).getPosition(_account, _collateralTokens[i], _indexTokens[i], _isLong[i]);

                amounts[i * 9] = size;
                amounts[i * 9 + 1] = collateral;
                amounts[i * 9 + 2] = averagePrice;
                amounts[i * 9 + 3] = entryFundingRate;
                amounts[i * 9 + 4] = hasRealisedProfit ? 1 : 0;
                amounts[i * 9 + 5] = realisedPnl;
                amounts[i * 9 + 6] = lastIncreasedTime;
            }
        }
        return amounts;
    }

    function getIncreaseOrders(
        address payable _orderBookAddress,
        address _account,
        uint256[] memory _indices
    ) external view returns (uint256[] memory, address[] memory) {
        Vars memory vars = Vars(0, 0, _account, 5, 3);

        uint256[] memory uintProps = new uint256[](vars.uintLength * _indices.length);
        address[] memory addressProps = new address[](vars.addressLength * _indices.length);

        IOrderBook orderBook = IOrderBook(_orderBookAddress);

        while (vars.i < _indices.length) {
            vars.index = _indices[vars.i];
            (
                uint256 collateralDelta,
                address collateralToken,
                address indexToken,
                uint256 sizeDelta,
                bool isLong,
                uint256 triggerPrice,
                bool triggerAboveThreshold,
            // uint256 executionFee
            ) = orderBook.getIncreaseOrder(vars.account, vars.index);

            uintProps[vars.i * vars.uintLength] = uint256(collateralDelta);
            uintProps[vars.i * vars.uintLength + 1] = uint256(sizeDelta);
            uintProps[vars.i * vars.uintLength + 2] = uint256(isLong ? 1 : 0);
            uintProps[vars.i * vars.uintLength + 3] = uint256(triggerPrice);
            uintProps[vars.i * vars.uintLength + 4] = uint256(triggerAboveThreshold ? 1 : 0);

            addressProps[vars.i * vars.addressLength] = (address(0));
            addressProps[vars.i * vars.addressLength + 1] = (collateralToken);
            addressProps[vars.i * vars.addressLength + 2] = (indexToken);

            vars.i++;
        }

        return (uintProps, addressProps);
    }

    function getDecreaseOrders(
        address payable _orderBookAddress,
        address _account,
        uint256[] memory _indices
    ) external view returns (uint256[] memory, address[] memory) {
        Vars memory vars = Vars(0, 0, _account, 5, 2);

        uint256[] memory uintProps = new uint256[](vars.uintLength * _indices.length);
        address[] memory addressProps = new address[](vars.addressLength * _indices.length);

        IOrderBook orderBook = IOrderBook(_orderBookAddress);

        while (vars.i < _indices.length) {
            vars.index = _indices[vars.i];
            (
                address collateralToken,
                uint256 collateralDelta,
                address indexToken,
                uint256 sizeDelta,
                bool isLong,
                uint256 triggerPrice,
                bool triggerAboveThreshold,
            // uint256 executionFee
            ) = orderBook.getDecreaseOrder(vars.account, vars.index);

            uintProps[vars.i * vars.uintLength] = uint256(collateralDelta);
            uintProps[vars.i * vars.uintLength + 1] = uint256(sizeDelta);
            uintProps[vars.i * vars.uintLength + 2] = uint256(isLong ? 1 : 0);
            uintProps[vars.i * vars.uintLength + 3] = uint256(triggerPrice);
            uintProps[vars.i * vars.uintLength + 4] = uint256(triggerAboveThreshold ? 1 : 0);

            addressProps[vars.i * vars.addressLength] = (collateralToken);
            addressProps[vars.i * vars.addressLength + 1] = (indexToken);

            vars.i++;
        }

        return (uintProps, addressProps);
    }
}
