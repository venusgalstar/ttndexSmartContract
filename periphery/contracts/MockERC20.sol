// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./utils/ERC20.sol";
import "./utils/Ownable.sol";

contract MockERC20 is ERC20, Ownable {
    constructor(
        string memory name,
        string memory symbol,
        uint256 supply
    ) ERC20(name, symbol) {
        _mint(msg.sender, supply);
    }

    function mintTokens(uint256 _amount) external onlyOwner {
        _mint(msg.sender, _amount);
    }
}