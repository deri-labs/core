// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IVault.sol";

interface IPool {
    function redeem(address _tokenOut, uint256 _amount, address _receiver) external;
    function transfer(address _token, uint256 _amount, address _receiver) external;
}

contract FeeManager is Ownable {

    IVault public vault;
    address public usdToken;
    uint256 public collectedFee;
    int256 public collectedPnl;

    mapping(address => bool) public isKeeper;

    modifier onlyKeeper() {
        require(isKeeper[msg.sender], "FeeManager: only keeper");
        _;
    }

    constructor(address _vault, address _usdToken){
        vault = IVault(_vault);
        usdToken = _usdToken;
    }

    function distributeFee(address[] calldata receivers, uint256[] calldata ratios) external onlyKeeper {
        require(receivers.length == ratios.length, "FeeManager: invalid params");

        uint256 _totalFee = vault.vaultFee();
        uint256 _totalRatio;
        uint256 _amount = _usdToToken(usdToken, _totalFee);
        vault.withdraw(usdToken, address(this), _amount);
        for (uint256 i = 0; i < ratios.length; i++) {
            _totalRatio += ratios[i];
            IERC20(usdToken).transfer(receivers[i], _amount * ratios[i] / 10000);
        }
        require(_totalRatio == 10000, "FeeManager: invalid ratios");
        collectedFee += _totalFee;
        vault.feeCallback();
    }

    function balancePnl(address _lPool) external onlyKeeper {
        int256 pnl = vault.vaultPnl();
        require(pnl != 0, "FeeManager: balanced");
        if (pnl > 0) {
            uint256 _amount = _usdToToken(usdToken, uint256(pnl));
            vault.withdraw(usdToken, _lPool, _amount);
        } else if (pnl < 0) {
            uint256 _amount = _usdToToken(usdToken, uint256(- pnl));
            IPool(_lPool).transfer(usdToken, _amount, address(vault));
        }
        collectedPnl += pnl;
        vault.pnlCallback();
    }

    function _usdToToken(address _token, uint256 _amount) internal view returns (uint256) {
        return _amount / (10 ** (30 - IERC20Metadata(_token).decimals()));
    }

    function setKeeper(address _account, bool _enabled) external onlyOwner {
        isKeeper[_account] = _enabled;
    }
}
