// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@layerzerolabs/solidity-examples/contracts/token/oft/v2/OFTV2.sol";

abstract contract UsdToken is OFTV2 {

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