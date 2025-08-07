// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@interfaces/IAerodromeOracle.sol";

contract OracleDebugTest is Test {
    IAerodromeOracle constant ORACLE = IAerodromeOracle(0x43B36A7E6a4cdFe7de5Bd2Aa1FCcddf6a366dAA2);
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant NONE_CONNECTOR = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    
    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
    }
    
    function testOracleAndCalculation() public view {
        console.log("Testing oracle and calculation:");
        
        // Get the rate
        (uint256 rate, uint256 weight) = ORACLE.getRate(USDC, WETH, NONE_CONNECTOR, 0);
        console.log("Rate:", rate);
        console.log("Weight:", weight);
        
        // Test different calculation methods
        console.log("\nTesting calculations:");
        
        // Original broken calculation
        uint256 price1 = (1e6 * 1e18) / rate;
        console.log("1. (1e6 * 1e18) / rate =", price1, "(WRONG - underflows to 0)");
        
        // Also broken
        uint256 price2 = 1e24 / rate;
        console.log("2. 1e24 / rate =", price2, "(WRONG - still 0)");
        
        // Our "fix"
        uint256 price3 = 1e30 / rate / 1e6;
        console.log("3. 1e30 / rate / 1e6 =", price3, "(Our fix)");
        
        // Check if price3 > 0
        console.log("4. Is price3 > 0?", price3 > 0 ? "YES" : "NO");
        
        // Alternative calculation
        uint256 price4 = (1e30 / rate);
        console.log("5. 1e30 / rate =", price4, "(before dividing by 1e6)");
        
        // Manual calculation check
        console.log("\nManual check:");
        console.log("rate ~= 2.61e26");
        console.log("1e30 / 2.61e26 ~= 3827");
        console.log("Expected WETH price: ~3827 USDC");
    }
}