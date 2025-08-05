// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ISugarHelper {
    struct PopulatedTick {
        int24 tick;
        uint160 sqrtRatioX96;
        int128 liquidityNet;
        uint128 liquidityGross;
    }

    function estimateAmount0(
        uint256 amount1,
        address pool,
        uint160 sqrtRatioX96,
        int24 tickLow,
        int24 tickHigh
    ) external view returns (uint256 amount0);

    function estimateAmount1(
        uint256 amount0,
        address pool,
        uint160 sqrtRatioX96,
        int24 tickLow,
        int24 tickHigh
    ) external view returns (uint256 amount1);

    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160 sqrtRatioX96);

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) external pure returns (uint256 amount0, uint256 amount1);

    function getLiquidityForAmounts(
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96
    ) external pure returns (uint256 liquidity);
}