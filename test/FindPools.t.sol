// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@interfaces/ICLFactory.sol";

contract FindPoolsTest is Test {
    ICLFactory constant CL_FACTORY = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
    
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ZORA = 0x1111111111166b7FE7bd91427724B487980aFc69;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    function testFindPools() public {
        vm.createSelectFork("https://mainnet.base.org");
        
        // Try different tick spacings
        int24[6] memory tickSpacings = [int24(1), int24(10), int24(50), int24(100), int24(200), int24(2000)];
        
        console.log("Finding pools...\n");
        
        // USDC/WETH pools
        console.log("USDC/WETH pools:");
        for (uint i = 0; i < tickSpacings.length; i++) {
            address pool = CL_FACTORY.getPool(USDC, WETH, tickSpacings[i]);
            if (pool != address(0)) {
                console.log("  Tick spacing", uint24(int24(tickSpacings[i])), ":", pool);
            }
        }
        
        // ZORA/WETH pools
        console.log("\nZORA/WETH pools:");
        for (uint i = 0; i < tickSpacings.length; i++) {
            address pool = CL_FACTORY.getPool(ZORA, WETH, tickSpacings[i]);
            if (pool != address(0)) {
                console.log("  Tick spacing", uint24(int24(tickSpacings[i])), ":", pool);
            }
        }
        
        // ZORA/USDC pools
        console.log("\nZORA/USDC pools:");
        for (uint i = 0; i < tickSpacings.length; i++) {
            address pool = CL_FACTORY.getPool(ZORA, USDC, tickSpacings[i]);
            if (pool != address(0)) {
                console.log("  Tick spacing", uint24(int24(tickSpacings[i])), ":", pool);
            }
        }
    }
}