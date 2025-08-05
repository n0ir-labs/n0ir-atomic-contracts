// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILpSugar {
    struct Lp {
        address lp;
        string symbol;
        uint8 decimals;
        uint256 liquidity;
        int24 type_;
        int24 tick;
        uint160 sqrt_ratio;
        address token0;
        uint256 reserve0;
        uint256 staked0;
        address token1;
        uint256 reserve1;
        uint256 staked1;
        address gauge;
        uint256 gauge_liquidity;
        bool gauge_alive;
        address fee;
        address bribe;
        address factory;
        uint256 emissions;
        address emissions_token;
        uint256 pool_fee;
        uint256 unstaked_fee;
        uint256 token0_fees;
        uint256 token1_fees;
        address nfpm;
        address alm;
        address root;
    }
    
    function byAddress(address _pool) external view returns (Lp memory);
}