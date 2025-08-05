// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IOffchainOracle
 * @notice Interface for 1inch Offchain Oracle for price discovery
 */
interface IOffchainOracle {
    /**
     * @notice Gets the rate between two tokens
     * @param srcToken Source token address
     * @param dstToken Destination token address
     * @param useWrappers Whether to use wrapper tokens in calculations
     * @return rate The exchange rate (with 18 decimals precision)
     */
    function getRate(
        address srcToken,
        address dstToken,
        bool useWrappers
    ) external view returns (uint256 rate);
    
    /**
     * @notice Gets the rate to ETH for a token
     * @param srcToken Source token address
     * @param useSrcWrappers Whether to use wrapper tokens
     * @return rate The rate to ETH (with 18 decimals precision)
     */
    function getRateToEth(
        address srcToken,
        bool useSrcWrappers
    ) external view returns (uint256 rate);
}