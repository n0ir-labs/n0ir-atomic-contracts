// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ICLFactory
 * @notice Interface for Aerodrome V3 Concentrated Liquidity Pool Factory
 * @dev Used to query pool addresses for token pairs with specific tick spacings
 */
interface ICLFactory {
    /**
     * @notice Returns the pool address for a given token pair and tick spacing
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param tickSpacing The tick spacing of the pool
     * @return pool The address of the pool (returns address(0) if pool doesn't exist)
     * @dev Tokens are automatically sorted, so order doesn't matter
     */
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);

    /**
     * @notice Returns all created pools
     * @param index The index of the pool in the array
     * @return pool The address of the pool at the given index
     */
    function allPools(uint256 index) external view returns (address pool);

    /**
     * @notice Returns the total number of pools created
     * @return The total number of pools
     */
    function allPoolsLength() external view returns (uint256);

    /**
     * @notice Returns the fee for a given tick spacing
     * @param tickSpacing The tick spacing to query
     * @return fee The fee in basis points for the tick spacing
     */
    function tickSpacingToFee(int24 tickSpacing) external view returns (uint24 fee);

    /**
     * @notice Checks if an address is a valid pool created by this factory
     * @param pool The address to check
     * @return isValid True if the address is a pool created by this factory
     */
    function isPool(address pool) external view returns (bool isValid);

    /**
     * @notice Returns the voter contract address
     * @return The address of the voter contract
     */
    function voter() external view returns (address);

    /**
     * @notice Returns the pool implementation address
     * @return The address of the pool implementation contract
     */
    function poolImplementation() external view returns (address);
}