// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AerodromeAtomicOperations.sol";
import "../contracts/CDPWalletRegistry.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IGauge.sol";
import "@interfaces/ICLPool.sol";

contract SimpleTwoTxTest is Test {
    AerodromeAtomicOperations public atomic;
    CDPWalletRegistry public walletRegistry;
    
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    
    address constant USER = address(0x1337);
    address constant TEST_POOL = 0x3f53f1Fd5b7723DDf38D93a584D280B9b94C3111;
    
    uint256 baseMainnetFork;
    
    function setUp() public {
        baseMainnetFork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(baseMainnetFork);
        
        walletRegistry = new CDPWalletRegistry();
        walletRegistry.registerWallet(USER);
        atomic = new AerodromeAtomicOperations(address(walletRegistry));
        
        deal(USDC, USER, 10000e6);
        
        vm.startPrank(USER);
        IERC20(USDC).approve(address(atomic), type(uint256).max);
        vm.stopPrank();
    }
    
    function testSimpleTwoTransactions() public {
        console.log("\n=== Simple Two Transaction Test (No Time Warp) ===");
        
        // Store initial state
        uint256 initialBlock = block.number;
        uint256 initialTimestamp = block.timestamp;
        uint256 tokenId;
        
        // Transaction 1: Create and stake position
        {
            vm.startPrank(USER);
            
            ICLPool pool = ICLPool(TEST_POOL);
            (, int24 currentTick,,,,) = pool.slot0();
            int24 tickSpacing = pool.tickSpacing();
            
            int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
            int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
            
            uint256 balanceBefore = IERC20(USDC).balanceOf(USER);
            console.log("\n--- TRANSACTION 1 ---");
            console.log("Block:", block.number);
            console.log("Timestamp:", block.timestamp);
            console.log("USDC balance:", balanceBefore / 1e6);
            
            AerodromeAtomicOperations.SwapMintParams memory mintParams = AerodromeAtomicOperations.SwapMintParams({
                pool: TEST_POOL,
                tickLower: tickLower,
                tickUpper: tickUpper,
                usdcAmount: 1000e6,
                minLiquidity: 0,
                deadline: block.timestamp + 3600,
                stake: true,
                slippageBps: 0
            });
            
            uint128 liquidity;
            (tokenId, liquidity) = atomic.swapMintAndStake(mintParams);
            
            console.log("\nPosition created!");
            console.log("Token ID:", tokenId);
            console.log("Liquidity:", liquidity);
            console.log("USDC spent:", (balanceBefore - IERC20(USDC).balanceOf(USER)) / 1e6);
            
            vm.stopPrank();
        }
        
        // Small gap between transactions (simulating real usage)
        vm.roll(block.number + 10);
        
        // Transaction 2: Exit position
        {
            vm.startPrank(USER);
            
            console.log("\n--- TRANSACTION 2 ---");
            console.log("Block:", block.number);
            console.log("Timestamp:", block.timestamp);
            console.log("Blocks passed:", block.number - initialBlock);
            
            uint256 balanceBefore = IERC20(USDC).balanceOf(USER);
            
            AerodromeAtomicOperations.ExitParams memory exitParams = AerodromeAtomicOperations.ExitParams({
                tokenId: tokenId,
                minUsdcOut: 900e6,
                deadline: block.timestamp + 3600, // Fresh deadline
                swapToUsdc: true,
                slippageBps: 0
            });
            
            (uint256 usdcOut, uint256 aeroRewards) = atomic.fullExit(exitParams);
            
            console.log("\nPosition exited!");
            console.log("USDC recovered:", usdcOut / 1e6);
            console.log("AERO rewards:", aeroRewards);
            console.log("Total USDC balance:", IERC20(USDC).balanceOf(USER) / 1e6);
            
            // Calculate P&L
            uint256 totalSpent = 1000e6;
            uint256 totalReceived = usdcOut;
            int256 pnl = int256(totalReceived) - int256(totalSpent);
            
            console.log("\n--- SUMMARY ---");
            console.log("Total spent: 1000 USDC");
            console.log("Total received:", totalReceived / 1e6, "USDC");
            console.log("Net P&L:");
            console.logInt(pnl / 1e6);
            console.log("USDC");
            console.log("(Plus", aeroRewards / 1e18, "AERO rewards)");
            
            // Verify NFT is burned
            INonfungiblePositionManager positionManager = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
            vm.expectRevert();
            positionManager.ownerOf(tokenId);
            console.log("NFT successfully burned: true");
            
            vm.stopPrank();
        }
    }
}