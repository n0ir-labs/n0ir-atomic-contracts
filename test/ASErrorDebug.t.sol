// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/LiquidityManager.sol";
import "@interfaces/INonfungiblePositionManager.sol";

contract ASErrorDebug is Test {
    address constant NEW_CONTRACT = 0x362E79f185D520DA87cd3bf285a36B89e305fc44;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant TARGET_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address constant POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    
    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
    }
    
    function testOracleWorksNow() public {
        console.log("Test 1: Verify oracle now works");
        
        (bool success, bytes memory data) = NEW_CONTRACT.staticcall(
            abi.encodeWithSignature("getTokenPriceViaOracle(address)", WETH)
        );
        
        if (success) {
            uint256 price = abi.decode(data, (uint256));
            console.log("  WETH price from oracle:", price);
            console.log("  This means $", price / 1e6, "per WETH (if price is in 6 decimals)");
            console.log("  Or $", price / 1e3, "per WETH (if price is in 3 decimals)");
            console.log("  Or $", price, "per WETH (if price is already scaled)");
        } else {
            console.log("  Oracle still failing!");
        }
    }
    
    function testWhereASErrorComes() public {
        console.log("\nTest 2: Try to trace where AS error comes from");
        
        // Create a test wallet with USDC
        address testWallet = address(0x1234);
        deal(USDC, testWallet, 10e6); // Give 10 USDC
        
        // Approve the contract
        vm.startPrank(testWallet);
        IERC20(USDC).approve(NEW_CONTRACT, 10e6);
        
        // Build params
        LiquidityManager.SwapRoute memory emptyRoute = LiquidityManager.SwapRoute({
            pools: new address[](0),
            tokens: new address[](0),
            tickSpacings: new int24[](0)
        });
        
        // Get current tick
        ICLPool pool = ICLPool(TARGET_POOL);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        console.log("  Current tick:", currentTick);
        console.log("  Tick spacing:", tickSpacing);
        
        // Calculate ticks
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        console.log("  Using tick range:");
        console.logInt(tickLower);
        console.logInt(tickUpper);
        
        LiquidityManager.PositionParams memory params = LiquidityManager.PositionParams({
            pool: TARGET_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 300,
            usdcAmount: 1e6, // 1 USDC
            slippageBps: 500, // 5%
            stake: false, // Don't stake to simplify
            token0Route: emptyRoute,
            token1Route: emptyRoute
        });
        
        // Call createPosition
        try LiquidityManager(NEW_CONTRACT).createPosition(params) returns (uint256 tokenId, uint128 liquidity) {
            console.log("  Success! TokenId:", tokenId, "Liquidity:", liquidity);
        } catch Error(string memory reason) {
            console.log("  Error:", reason);
            
            // If it's AS, it's likely from Position Manager's mint
            if (keccak256(bytes(reason)) == keccak256(bytes("AS"))) {
                console.log("  AS = Amount Slippage, likely from PositionManager.mint()");
                console.log("  This means amount0Min or amount1Min requirements not met");
            }
        } catch (bytes memory data) {
            console.log("  Low-level error, data length:", data.length);
        }
        
        vm.stopPrank();
    }
    
    function testCalculateOptimalAllocation() public {
        console.log("\nTest 3: Check calculateOptimalUSDCAllocation");
        
        ICLPool pool = ICLPool(TARGET_POOL);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        LiquidityManager lm = LiquidityManager(NEW_CONTRACT);
        
        (uint256 usdc0, uint256 usdc1) = lm.calculateOptimalUSDCAllocation(
            1e6, // 1 USDC total
            WETH, // token0
            USDC, // token1
            tickLower,
            tickUpper,
            pool
        );
        
        console.log("  For 1 USDC input:");
        console.log("    Allocate to token0 (WETH):", usdc0);
        console.log("    Allocate to token1 (USDC):", usdc1);
        console.log("    Total:", usdc0 + usdc1);
    }
}