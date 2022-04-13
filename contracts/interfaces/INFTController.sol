// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface INFTController {
    function getBoostRate(address token, uint tokenId) external view returns (uint boostRate);

    function isWhitelistedNFT(address token) external view returns (bool);
}
