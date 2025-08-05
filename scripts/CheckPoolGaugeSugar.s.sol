// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

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

contract CheckPoolGaugeSugar is Script {
    address constant LP_SUGAR = 0x27fc745390d1f4BaF8D184FBd97748340f786634;
    address constant TEST_POOL = 0x3f53f1Fd5b7723DDf38D93a584D280B9b94C3111;
    
    function run() public view {
        console.log("Checking ZORA/USDC pool via Sugar:", TEST_POOL);
        console.log("");
        
        ILpSugar sugar = ILpSugar(LP_SUGAR);
        
        try sugar.byAddress(TEST_POOL) returns (ILpSugar.Lp memory poolData) {
            console.log("Pool found in Sugar!");
            console.log("  Symbol:", poolData.symbol);
            console.log("  Gauge:", poolData.gauge);
            console.log("  Gauge alive:", poolData.gauge_alive);
            console.log("  Gauge liquidity:", poolData.gauge_liquidity);
            console.log("  Emissions:", poolData.emissions);
            console.log("  Emissions token:", poolData.emissions_token);
            
            if (poolData.gauge != address(0)) {
                console.log("\n==> POOL HAS A GAUGE! <==");
                console.log("Gauge address:", poolData.gauge);
            } else {
                console.log("\n==> Pool has NO gauge");
            }
        } catch Error(string memory reason) {
            console.log("Error:", reason);
        } catch {
            console.log("Pool not found or error querying Sugar");
        }
    }
}