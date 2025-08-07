// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/LiquidityManager.sol";

contract DeployedContractTest is Test {
    address constant DEPLOYED_CONTRACT = 0xA2C602c7Ee83d807d39C2fEb9f4d0b3f94193598;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
    }
    
    function testDeployedOracleFunction() public {
        console.log("Testing deployed contract at:", DEPLOYED_CONTRACT);
        console.log("");
        
        // Test 1: Call getTokenPriceViaOracle for WETH
        console.log("Test 1: getTokenPriceViaOracle(WETH)");
        (bool success, bytes memory data) = DEPLOYED_CONTRACT.staticcall(
            abi.encodeWithSignature("getTokenPriceViaOracle(address)", WETH)
        );
        
        if (success) {
            uint256 price = abi.decode(data, (uint256));
            console.log("  Success! WETH price:", price);
        } else {
            console.log("  Failed!");
            if (data.length >= 68) {
                assembly {
                    data := add(data, 0x04)
                }
                string memory reason = abi.decode(data, (string));
                console.log("  Revert reason:", reason);
            }
        }
        
        // Test 2: Call getTokenPriceViaOracle for USDC
        console.log("\nTest 2: getTokenPriceViaOracle(USDC)");
        (success, data) = DEPLOYED_CONTRACT.staticcall(
            abi.encodeWithSignature("getTokenPriceViaOracle(address)", USDC)
        );
        
        if (success) {
            uint256 price = abi.decode(data, (uint256));
            console.log("  Success! USDC price:", price);
        } else {
            console.log("  Failed!");
        }
        
        // Test 3: Try calling the oracle directly from this test to confirm it works
        console.log("\nTest 3: Direct oracle call from test contract");
        LiquidityManager lm = new LiquidityManager(address(0));
        try lm.getTokenPriceViaOracle(WETH) returns (uint256 price) {
            console.log("  Fresh contract WETH price:", price);
        } catch Error(string memory reason) {
            console.log("  Fresh contract failed:", reason);
        }
    }
    
    function testCreatePositionSimulation() public {
        console.log("\nSimulating createPosition call:");
        
        // Build the same params as Python test
        LiquidityManager.SwapRoute memory emptyRoute = LiquidityManager.SwapRoute({
            pools: new address[](0),
            tokens: new address[](0),
            tickSpacings: new int24[](0)
        });
        
        LiquidityManager.PositionParams memory params = LiquidityManager.PositionParams({
            pool: 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59,
            tickLower: -201810,
            tickUpper: -201310,
            deadline: block.timestamp + 300,
            usdcAmount: 1e6,
            slippageBps: 500,
            stake: true,
            token0Route: emptyRoute,
            token1Route: emptyRoute
        });
        
        // Try to call createPosition (will fail due to no approval, but we can see where it fails)
        (bool success, bytes memory data) = DEPLOYED_CONTRACT.call(
            abi.encodeWithSignature("createPosition((address,int24,int24,uint256,uint256,uint256,bool,(address[],address[],int24[]),(address[],address[],int24[])))", params)
        );
        
        if (!success) {
            console.log("  Failed as expected");
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