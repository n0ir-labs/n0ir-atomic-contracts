// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IGauge {
    function deposit(uint256 tokenId) external;
    
    function withdraw(uint256 tokenId) external;
    
    function getReward(uint256 tokenId) external;
    
    function earned(uint256 tokenId) external view returns (uint256);
    
    function rewardToken() external view returns (address);
    
    function pool() external view returns (address);
    
    function feeVault() external view returns (address);
    
    function stakedTokenIds(address owner) external view returns (uint256[] memory);
    
    function stakedByIndex(address owner, uint256 index) external view returns (uint256);
    
    function stakedContains(address owner, uint256 tokenId) external view returns (bool);
}