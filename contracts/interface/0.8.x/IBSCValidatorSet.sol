// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

interface IBSCValidatorSet {
    function felony(address consensusAddress) external;

    function getValidators() external view returns (address[] memory);
    function numOfMaintaining() external view returns (uint256);
    function numOfCabinets() external view returns (uint256);
    function lastEvictionBlock() external view returns (uint256);
}
