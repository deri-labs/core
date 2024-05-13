// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract LpToken is ERC20, Ownable {

    mapping(address => bool) public isManager;

    modifier onlyManager() {
        require(isManager[msg.sender], "not manager");
        _;
    }

    function mint(address to, uint256 amount) public virtual onlyManager {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public virtual onlyManager {
        _burn(from, amount);
    }

    function setManager(address manager, bool enabled) public virtual onlyOwner {
        isManager[manager] = enabled;
    }
}