// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@interfaces/IAerodromeOracle.sol";

contract OracleTest is Test {
    IAerodromeOracle constant ORACLE = IAerodromeOracle(0x43B36A7E6a4cdFe7de5Bd2Aa1FCcddf6a366dAA2);
    
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant NONE_CONNECTOR = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    
    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }
    
    function testOracleDirectCall() public view {
        console.log("Testing Oracle Direct Calls:");
        console.log("Oracle address:", address(ORACLE));
        console.log("");
        
        // Test 1: USDC -> WETH with NONE connector (the one you showed working)
        console.log("Test 1: USDC -> WETH with NONE connector");
        try ORACLE.getRate(USDC, WETH, NONE_CONNECTOR, 0) returns (uint256 rate, uint256 weight) {
            console.log("  Rate:", rate);
            console.log("  Weight:", weight);
            if (rate > 0) {
                // Correct calculation with proper precision
                uint256 price = 1e24 / rate;
                console.log("  Calculated WETH price in USDC (wrong):", price);
                
                // Actually, rate is too large, we need different approach
                // rate / 1e18 gives us the decimal rate
                // 1 / (rate/1e18) * 1e6 = 1e6 * 1e18 / rate = 1e24 / rate
                console.log("  Rate / 1e12 =", rate / 1e12); // Should be ~261326029
                uint256 correctPrice = 1e12 / (rate / 1e12); // This should work
                console.log("  Correct WETH price in USDC:", correctPrice);
            }
        } catch Error(string memory reason) {
            console.log("  ERROR:", reason);
        } catch {
            console.log("  ERROR: Unknown revert");
        }
        
        // Test 2: USDC -> WETH with WETH connector
        console.log("\nTest 2: USDC -> WETH with WETH connector");
        try ORACLE.getRate(USDC, WETH, WETH, 0) returns (uint256 rate, uint256 weight) {
            console.log("  Rate:", rate);
            console.log("  Weight:", weight);
        } catch Error(string memory reason) {
            console.log("  ERROR:", reason);
        } catch {
            console.log("  ERROR: Unknown revert");
        }
        
        // Test 3: USDC -> WETH with USDC connector (problematic?)
        console.log("\nTest 3: USDC -> WETH with USDC connector");
        try ORACLE.getRate(USDC, WETH, USDC, 0) returns (uint256 rate, uint256 weight) {
            console.log("  Rate:", rate);
            console.log("  Weight:", weight);
        } catch Error(string memory reason) {
            console.log("  ERROR:", reason);
        } catch {
            console.log("  ERROR: Unknown revert");
        }
        
        // Test 4: USDC -> WETH with cbBTC connector
        console.log("\nTest 4: USDC -> WETH with cbBTC connector");
        try ORACLE.getRate(USDC, WETH, CBBTC, 0) returns (uint256 rate, uint256 weight) {
            console.log("  Rate:", rate);
            console.log("  Weight:", weight);
        } catch Error(string memory reason) {
            console.log("  ERROR:", reason);
        } catch {
            console.log("  ERROR: Unknown revert");
        }
        
        // Test 5: USDC -> AERO with NONE connector
        console.log("\nTest 5: USDC -> AERO with NONE connector");
        try ORACLE.getRate(USDC, AERO, NONE_CONNECTOR, 0) returns (uint256 rate, uint256 weight) {
            console.log("  Rate:", rate);
            console.log("  Weight:", weight);
        } catch Error(string memory reason) {
            console.log("  ERROR:", reason);
        } catch {
            console.log("  ERROR: Unknown revert");
        }
        
        // Test 6: USDC -> USDC (edge case)
        console.log("\nTest 6: USDC -> USDC with NONE connector");
        try ORACLE.getRate(USDC, USDC, NONE_CONNECTOR, 0) returns (uint256 rate, uint256 weight) {
            console.log("  Rate:", rate);
            console.log("  Weight:", weight);
        } catch Error(string memory reason) {
            console.log("  ERROR:", reason);
        } catch {
            console.log("  ERROR: Unknown revert");
        }
    }
    
    function testLiquidityManagerOracleFunction() public {
        console.log("\nTesting LiquidityManager's getTokenPriceViaOracle:");
        
        // Deploy the LiquidityManager to test its oracle function
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        
        // Import and deploy a test version
        address liquidityManager = 0x1f37a1Efa41a5c9fDC653C440fE8F2f1633EA8A0; // Your deployed address
        
        // Test calling getTokenPriceViaOracle directly
        (bool success, bytes memory data) = liquidityManager.staticcall(
            abi.encodeWithSignature("getTokenPriceViaOracle(address)", WETH)
        );
        
        if (success) {
            uint256 price = abi.decode(data, (uint256));
            console.log("  WETH price from getTokenPriceViaOracle:", price);
        } else {
            console.log("  getTokenPriceViaOracle failed");
            // Try to decode revert reason
            if (data.length > 0) {
                if (data.length >= 68) {
                    assembly {
                        data := add(data, 0x04)
                    }
                    string memory reason = abi.decode(data, (string));
                    console.log("  Revert reason:", reason);
                }
            }
        }
    }
}