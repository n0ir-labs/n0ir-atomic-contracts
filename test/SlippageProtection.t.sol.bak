// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AerodromeAtomicOperations.sol";
import "../contracts/CDPWalletRegistry.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/ICLPool.sol";

contract SlippageProtectionTest is Test {
    AerodromeAtomicOperations public atomic;
    CDPWalletRegistry public walletRegistry;
    
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USER = address(0x1337);
    
    uint256 baseMainnetFork;
    address testPool;
    
    function setUp() public {
        baseMainnetFork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(baseMainnetFork);
        
        walletRegistry = new CDPWalletRegistry();
        walletRegistry.registerWallet(USER);
        
        atomic = new AerodromeAtomicOperations(address(walletRegistry));
        
        // Find USDC/WETH pool
        ICLFactory factory = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
        testPool = factory.getPool(USDC < WETH ? USDC : WETH, USDC > WETH ? USDC : WETH, 100);
        require(testPool != address(0), "Pool not found");
        
        deal(USDC, USER, 100000e6);
        
        vm.startPrank(USER);
        IERC20(USDC).approve(address(atomic), type(uint256).max);
        vm.stopPrank();
    }
    
    function testCustomSlippageProtection() public {
        vm.startPrank(USER);
        
        // Test with custom slippage (5%)
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: testPool,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 1000e6,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: false,
            slippageBps: 500 // 5% slippage
        });
        
        (uint256 tokenId, uint128 liquidity) = atomic.swapMintAndStake(params);
        
        assertGt(tokenId, 0, "Should receive valid tokenId");
        assertGt(liquidity, 0, "Should receive liquidity");
        
        vm.stopPrank();
    }
    
    function testExcessiveSlippageReverts() public {
        vm.startPrank(USER);
        
        // Test with excessive slippage (15%)
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: testPool,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 1000e6,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: false,
            slippageBps: 1500 // 15% slippage - should revert
        });
        
        vm.expectRevert("Slippage too high");
        atomic.swapMintAndStake(params);
        
        vm.stopPrank();
    }
    
    function testFullExitWithSlippage() public {
        vm.startPrank(USER);
        
        // First mint a position
        AerodromeAtomicOperations.SwapMintParams memory mintParams = AerodromeAtomicOperations.SwapMintParams({
            pool: testPool,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 10000e6,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: false,
            slippageBps: 200 // 2% slippage
        });
        
        (uint256 tokenId,) = atomic.swapMintAndStake(mintParams);
        
        // Transfer position to atomic contract
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
        positionManager.approve(address(atomic), tokenId);
        
        // Exit with custom slippage
        AerodromeAtomicOperations.ExitParams memory exitParams = AerodromeAtomicOperations.ExitParams({
            tokenId: tokenId,
            minUsdcOut: 9000e6, // Expecting at least 90% back
            deadline: block.timestamp + 1 hours,
            swapToUsdc: true,
            slippageBps: 300 // 3% slippage
        });
        
        (uint256 usdcOut,) = atomic.fullExit(exitParams);
        
        assertGt(usdcOut, 9000e6, "Should receive at least minUsdcOut");
        assertLt(usdcOut, 10100e6, "Should not exceed original amount too much");
        
        vm.stopPrank();
    }
    
    function testDefaultSlippageUsedWhenZero() public {
        vm.startPrank(USER);
        
        // Test with slippageBps = 0 (should use default)
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: testPool,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 1000e6,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: false,
            slippageBps: 0 // Should use default (1%)
        });
        
        (uint256 tokenId, uint128 liquidity) = atomic.swapMintAndStake(params);
        
        assertGt(tokenId, 0, "Should receive valid tokenId");
        assertGt(liquidity, 0, "Should receive liquidity");
        
        vm.stopPrank();
    }
}