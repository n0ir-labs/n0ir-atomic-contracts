// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AerodromeAtomicOperations.sol";
import "../contracts/CDPWalletRegistry.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IGauge.sol";
import "@interfaces/ICLPool.sol";

contract WorkingLifecycleTest is Test {
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
    
    function testCreateStakedPositionAndExit() public {
        vm.startPrank(USER);
        
        console.log("\n=== Full Lifecycle Test ===");
        
        // Step 1: Create position
        ICLPool pool = ICLPool(TEST_POOL);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        uint256 initialBalance = IERC20(USDC).balanceOf(USER);
        console.log("Initial USDC:", initialBalance / 1e6);
        
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
        
        (uint256 tokenId, uint128 liquidity) = atomic.swapMintAndStake(mintParams);
        console.log("\nPosition created and staked");
        console.log("Token ID:", tokenId);
        console.log("Liquidity:", liquidity);
        
        // Step 2: Exit immediately
        console.log("\nExiting position...");
        
        AerodromeAtomicOperations.ExitParams memory exitParams = AerodromeAtomicOperations.ExitParams({
            tokenId: tokenId,
            minUsdcOut: 900e6,
            deadline: block.timestamp + 3600,
            swapToUsdc: true,
            slippageBps: 0
        });
        
        (uint256 usdcOut, uint256 aeroRewards) = atomic.fullExit(exitParams);
        
        console.log("\nExit complete");
        console.log("USDC out:", usdcOut / 1e6);
        console.log("AERO rewards:", aeroRewards);
        
        uint256 finalBalance = IERC20(USDC).balanceOf(USER);
        int256 pnl = int256(finalBalance) - int256(initialBalance);
        
        console.log("\nFinal results:");
        console.log("Final USDC:", finalBalance / 1e6);
        console.log("Net P&L:");
        console.logInt(pnl / 1e6);
        console.log("USDC");
        
        // Verify position is burned
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
        vm.expectRevert();
        positionManager.ownerOf(tokenId);
        
        vm.stopPrank();
    }
    
    function testCreateUnstakedPositionAndExit() public {
        vm.startPrank(USER);
        
        console.log("\n=== Unstaked Position Test ===");
        
        ICLPool pool = ICLPool(TEST_POOL);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        int24 tickLower = ((currentTick - 1000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 1000) / tickSpacing) * tickSpacing;
        
        // Create without staking
        AerodromeAtomicOperations.SwapMintParams memory mintParams = AerodromeAtomicOperations.SwapMintParams({
            pool: TEST_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            usdcAmount: 500e6,
            minLiquidity: 0,
            deadline: block.timestamp + 3600,
            stake: false,
            slippageBps: 0
        });
        
        (uint256 tokenId, uint128 liquidity) = atomic.swapAndMint(mintParams);
        console.log("Position created (not staked)");
        console.log("Token ID:", tokenId);
        
        // Exit using fullExit (requires approval)
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
        positionManager.approve(address(atomic), tokenId);
        
        AerodromeAtomicOperations.ExitParams memory exitParams = AerodromeAtomicOperations.ExitParams({
            tokenId: tokenId,
            minUsdcOut: 450e6,
            deadline: block.timestamp + 3600,
            swapToUsdc: true,
            slippageBps: 0
        });
        
        (uint256 usdcOut,) = atomic.fullExit(exitParams);
        console.log("Exit complete, USDC:", usdcOut / 1e6);
        
        vm.stopPrank();
    }
}