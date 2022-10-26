// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IMasterChef {
    function deposit(uint256 _pid, uint256 _amount, address _referrer) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function pendingTTNP(uint256 _pid, address _user) external view returns (uint256);
}
