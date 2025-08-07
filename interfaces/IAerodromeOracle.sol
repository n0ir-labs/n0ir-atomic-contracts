// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IAerodromeOracle
 * @notice Interface for Aerodrome Oracle for price discovery with connectors
 */
interface IAerodromeOracle {
    error ConnectorShouldBeNone();
    error MathOverflowedMulDiv();
    error PoolNotFound();
    error PoolWithConnectorNotFound();

    function FACTORY() external view returns (address);
    function INITCODE_HASH() external view returns (bytes32);
    function SUPPORTED_FEES_COUNT() external view returns (uint256);
    function fees(uint256 index) external view returns (uint24);
    
    /**
     * @notice Gets the rate between two tokens with optional connector
     * @param srcToken Source token address
     * @param dstToken Destination token address  
     * @param connector Connector token address (use 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF for NONE)
     * @param thresholdFilter Minimum liquidity threshold
     * @return rate The exchange rate
     * @return weight The liquidity weight
     */
    function getRate(
        address srcToken,
        address dstToken,
        address connector,
        uint256 thresholdFilter
    ) external view returns (uint256 rate, uint256 weight);
}