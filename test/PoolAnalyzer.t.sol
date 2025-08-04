// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@interfaces/ICLPool.sol";
import "@interfaces/ICLFactory.sol";
import "@interfaces/IERC20.sol";

contract PoolAnalyzer is Test {
    address constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    
    function testAnalyzePool() public {
        vm.createSelectFork("https://mainnet.base.org");
        
        address poolAddress = 0x4A021bA3ab1F0121e7DF76f345C547db86Cb3468;
        ICLPool pool = ICLPool(poolAddress);
        
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        console.log("=== Pool Analysis ===");
        console.log("Pool:", poolAddress);
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        
        // Try to get token names
        try IERC20(token0).name() returns (string memory name) {
            console.log("Token0 Name:", name);
        } catch {}
        
        try IERC20(token1).name() returns (string memory name) {
            console.log("Token1 Name:", name);
        } catch {}
        
        try IERC20(token0).symbol() returns (string memory symbol) {
            console.log("Token0 Symbol:", symbol);
        } catch {}
        
        try IERC20(token1).symbol() returns (string memory symbol) {
            console.log("Token1 Symbol:", symbol);
        } catch {}
        
        // Check for pools with intermediate tokens
        console.log("\n=== Searching for routing paths ===");
        _findPools("Token0", token0);
        _findPools("Token1", token1);
    }
    
    function _findPools(string memory tokenName, address token) internal view {
        console.log("\nChecking pools for", tokenName, token);
        
        address[4] memory intermediates = [USDC, WETH, AERO, 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA]; // USDbC
        string[4] memory names = ["USDC", "WETH", "AERO", "USDbC"];
        int24[6] memory tickSpacings = [int24(1), int24(10), int24(50), int24(100), int24(200), int24(2000)];
        
        for (uint i = 0; i < intermediates.length; i++) {
            for (uint j = 0; j < tickSpacings.length; j++) {
                address poolAddr = ICLFactory(CL_FACTORY).getPool(token, intermediates[i], tickSpacings[j]);
                if (poolAddr != address(0)) {
                    console.log(string.concat("Found pool with ", names[i], " tick spacing: ", vm.toString(tickSpacings[j])));
                    console.log("  Pool address:", poolAddr);
                    
                    // Check liquidity
                    try ICLPool(poolAddr).liquidity() returns (uint128 liquidity) {
                        if (liquidity > 0) {
                            console.log("  Liquidity:", liquidity);
                        }
                    } catch {}
                }
            }
        }
    }
}