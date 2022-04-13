// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ITvlStats {
    function daoTotalDollarValue() external view returns (uint256);

    function insuranceTotalDollarValue() external view returns (uint256);

    function lendingTotalDollarValue() external view returns (uint256);
}
