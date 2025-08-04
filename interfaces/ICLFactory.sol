// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICLFactory {
    function getPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) external view returns (address pool);
    
    function poolImplementation() external view returns (address);
    
    function parameters()
        external
        view
        returns (
            address factory,
            address token0,
            address token1,
            int24 tickSpacing,
            uint24 fee
        );
        
    function gauge(address pool) external view returns (address);
    
    function voter() external view returns (address);
    
    function tickSpacingToFee(int24 tickSpacing) external view returns (uint24 fee);
    
    function isPool(address pool) external view returns (bool);
    
    function allPools(uint256 index) external view returns (address);
    
    function allPoolsLength() external view returns (uint256);
}