// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AerodromeAtomicOperations.sol";
import "../contracts/CDPWalletRegistry.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/ICLPool.sol";
import "@interfaces/INonfungiblePositionManager.sol";

contract FullCycleZoraUsdcTest is Test {
    AerodromeAtomicOperations public atomicOps;
    CDPWalletRegistry public registry;
    
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ZORA = 0x1111111111166b7FE7bd91427724B487980aFc69; // Actual ZORA token on Base
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    // Pool addresses
    address constant ZORA_USDC_POOL = 0x3f53f1Fd5b7723DDf38D93a584D280B9b94C3111; // tick spacing 100
    address constant USDC_WETH_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59; // tick spacing 100
    address constant ZORA_WETH_POOL = 0xAdB8Fb846DBD3Bd6A23335CEe65Bb610C1cf0ea3; // tick spacing 100
    
    // Contracts
    INonfungiblePositionManager constant POSITION_MANAGER = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    
    address public user;
    uint256 public positionTokenId;
    
    function setUp() public {
        // Fork Base mainnet at a recent block
        vm.createSelectFork("https://mainnet.base.org");
        
        // Deploy contracts
        registry = new CDPWalletRegistry();
        atomicOps = new AerodromeAtomicOperations(address(registry));
        
        // Setup user
        user = makeAddr("user");
        registry.registerWallet(user);
        
        // Fund user with USDC (10,000 USDC)
        deal(USDC, user, 10_000e6);
        
        // Approve atomic operations
        vm.prank(user);
        IERC20(USDC).approve(address(atomicOps), type(uint256).max);
    }
    
    function testFullCycleDirectPool() public {
        // Test 1: Direct USDC position (no swaps needed)
        console.log("\n=== TEST 1: Direct USDC Position ===");
        
        // Get pool info
        ICLPool pool = ICLPool(ZORA_USDC_POOL);
        (uint160 sqrtPriceX96,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        console.log("Pool:", ZORA_USDC_POOL);
        console.log("Token0 (ZORA):", pool.token0());
        console.log("Token1 (USDC):", pool.token1());
        console.log("Tick spacing:", uint256(int256(tickSpacing)));
        console.log("Current sqrtPriceX96:", sqrtPriceX96);
        
        // Calculate tick range around current price
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickLower = ((currentTick - 1000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 1000) / tickSpacing) * tickSpacing;
        
        console.log("Current tick:", currentTick);
        console.log("Tick lower:", tickLower);
        console.log("Tick upper:", tickUpper);
        
        // Create position with direct USDC (no routes needed)
        AerodromeAtomicOperations.SwapRoute[] memory routes = new AerodromeAtomicOperations.SwapRoute[](1);
        routes[0] = AerodromeAtomicOperations.SwapRoute({
            pools: new address[](1),
            tokenOut: ZORA,
            amountIn: 0 // Let contract calculate
        });
        routes[0].pools[0] = ZORA_USDC_POOL; // Direct swap USDC -> ZORA
        
        AerodromeAtomicOperations.SwapMintParams memory mintParams = AerodromeAtomicOperations.SwapMintParams({
            pool: ZORA_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            usdcAmount: 1000e6, // 1000 USDC
            minLiquidity: 0,
            deadline: block.timestamp + 300,
            stake: false, // Don't stake for this test
            slippageBps: 100, // 1% slippage
            routes: routes
        });
        
        vm.prank(user);
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapMintAndStake(mintParams);
        
        console.log("\nPosition created:");
        console.log("Token ID:", tokenId);
        console.log("Liquidity:", liquidity);
        
        positionTokenId = tokenId;
        
        // Verify position ownership
        address owner = POSITION_MANAGER.ownerOf(tokenId);
        console.log("Position owner:", owner);
        assertEq(owner, user, "User should own the position");
        
        // Exit position
        console.log("\n=== Exiting Position ===");
        
        // Create exit routes
        AerodromeAtomicOperations.SwapRoute[] memory exitRoutes = new AerodromeAtomicOperations.SwapRoute[](1);
        exitRoutes[0] = AerodromeAtomicOperations.SwapRoute({
            pools: new address[](1),
            tokenOut: USDC,
            amountIn: 0
        });
        exitRoutes[0].pools[0] = ZORA_USDC_POOL; // Direct swap ZORA -> USDC
        
        AerodromeAtomicOperations.ExitParams memory exitParams = AerodromeAtomicOperations.ExitParams({
            tokenId: tokenId,
            minUsdcOut: 900e6, // Expect at least 900 USDC back
            deadline: block.timestamp + 300,
            swapToUsdc: true,
            slippageBps: 100,
            routes: exitRoutes
        });
        
        // Approve position manager
        vm.prank(user);
        POSITION_MANAGER.approve(address(atomicOps), tokenId);
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        
        vm.prank(user);
        (uint256 usdcOut, uint256 aeroRewards) = atomicOps.fullExit(exitParams);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);
        
        console.log("\nExit results:");
        console.log("USDC received:", usdcOut);
        console.log("AERO rewards:", aeroRewards);
        console.log("User USDC balance change:", usdcAfter - usdcBefore);
        
        assertGt(usdcOut, 900e6, "Should receive at least 900 USDC");
        assertEq(usdcAfter - usdcBefore, usdcOut, "USDC balance should match output");
    }
    
    function testFullCycleSimplified() public {
        // Test 2: Simplified - using the same pool for swap
        console.log("\n=== TEST 2: Simplified Position (Same Pool Swap) ===");
        
        // For ZORA/USDC pool, we only need to swap USDC -> ZORA using the same pool
        
        ICLPool pool = ICLPool(ZORA_USDC_POOL);
        int24 tickSpacing = pool.tickSpacing();
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickLower = ((currentTick - 2000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 2000) / tickSpacing) * tickSpacing;
        
        // Single route using the same pool we're entering
        AerodromeAtomicOperations.SwapRoute[] memory routes = new AerodromeAtomicOperations.SwapRoute[](1);
        routes[0] = AerodromeAtomicOperations.SwapRoute({
            pools: new address[](1),
            tokenOut: ZORA,
            amountIn: 0
        });
        routes[0].pools[0] = ZORA_USDC_POOL;  // USDC -> ZORA using same pool
        
        AerodromeAtomicOperations.SwapMintParams memory mintParams = AerodromeAtomicOperations.SwapMintParams({
            pool: ZORA_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            usdcAmount: 2000e6, // 2000 USDC
            minLiquidity: 0,
            deadline: block.timestamp + 300,
            stake: false,
            slippageBps: 200, // 2% slippage for multi-hop
            routes: routes
        });
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        
        vm.prank(user);
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapMintAndStake(mintParams);
        
        console.log("\nSimplified position created:");
        console.log("Token ID:", tokenId);
        console.log("Liquidity:", liquidity);
        console.log("USDC spent:", usdcBefore - IERC20(USDC).balanceOf(user));
        
        // Exit using same pool
        console.log("\n=== Exiting with Same Pool ===");
        
        AerodromeAtomicOperations.SwapRoute[] memory exitRoutes = new AerodromeAtomicOperations.SwapRoute[](1);
        
        // Route for ZORA -> USDC using same pool
        exitRoutes[0] = AerodromeAtomicOperations.SwapRoute({
            pools: new address[](1),
            tokenOut: USDC,
            amountIn: 0
        });
        exitRoutes[0].pools[0] = ZORA_USDC_POOL; // ZORA -> USDC using same pool
        
        AerodromeAtomicOperations.ExitParams memory exitParams = AerodromeAtomicOperations.ExitParams({
            tokenId: tokenId,
            minUsdcOut: 1800e6, // Expect at least 1800 USDC back
            deadline: block.timestamp + 300,
            swapToUsdc: true,
            slippageBps: 200,
            routes: exitRoutes
        });
        
        vm.prank(user);
        POSITION_MANAGER.approve(address(atomicOps), tokenId);
        
        usdcBefore = IERC20(USDC).balanceOf(user);
        
        vm.prank(user);
        (uint256 usdcOut, uint256 aeroRewards) = atomicOps.fullExit(exitParams);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);
        
        console.log("\nExit results:");
        console.log("USDC received:", usdcOut);
        console.log("AERO rewards:", aeroRewards);
        console.log("Total USDC recovered:", usdcAfter - usdcBefore);
        
        assertGt(usdcOut, 1800e6, "Should receive at least 1800 USDC");
        assertEq(usdcAfter - usdcBefore, usdcOut, "USDC balance should match output");
    }
    
    function testFullCycleTwoTokenSwaps() public {
        // Test 3: Position requiring swaps to both tokens
        console.log("\n=== TEST 3: Two Token Swaps (No Optimization) ===");
        
        // For ZORA/USDC pool where we need both tokens
        // This simulates a case where USDC is token1, so we need to swap some USDC to ZORA
        
        ICLPool pool = ICLPool(ZORA_USDC_POOL);
        int24 tickSpacing = pool.tickSpacing();
        (, int24 currentTick,,,,) = pool.slot0();
        
        // Create a narrow range to force needing both tokens
        int24 tickLower = ((currentTick - 100) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 100) / tickSpacing) * tickSpacing;
        
        // Since ZORA is token0 and USDC is token1, we only need to swap to ZORA
        AerodromeAtomicOperations.SwapRoute[] memory routes = new AerodromeAtomicOperations.SwapRoute[](1);
        routes[0] = AerodromeAtomicOperations.SwapRoute({
            pools: new address[](1),
            tokenOut: ZORA,
            amountIn: 0 // Let contract calculate optimal amount
        });
        routes[0].pools[0] = ZORA_USDC_POOL;
        
        AerodromeAtomicOperations.SwapMintParams memory mintParams = AerodromeAtomicOperations.SwapMintParams({
            pool: ZORA_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            usdcAmount: 3000e6, // 3000 USDC
            minLiquidity: 0,
            deadline: block.timestamp + 300,
            stake: false,
            slippageBps: 100,
            routes: routes
        });
        
        vm.prank(user);
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapMintAndStake(mintParams);
        
        console.log("\nNarrow range position created:");
        console.log("Token ID:", tokenId);
        console.log("Liquidity:", liquidity);
        console.log("Tick lower:", tickLower);
        console.log("Tick upper:", tickUpper);
        
        // Exit with separate routes for each token
        console.log("\n=== Exiting with Separate Routes ===");
        
        AerodromeAtomicOperations.SwapRoute[] memory exitRoutes = new AerodromeAtomicOperations.SwapRoute[](1);
        
        // Route for ZORA -> USDC
        exitRoutes[0] = AerodromeAtomicOperations.SwapRoute({
            pools: new address[](1),
            tokenOut: USDC,
            amountIn: 0
        });
        exitRoutes[0].pools[0] = ZORA_USDC_POOL;
        
        AerodromeAtomicOperations.ExitParams memory exitParams = AerodromeAtomicOperations.ExitParams({
            tokenId: tokenId,
            minUsdcOut: 2700e6, // Expect at least 2700 USDC back
            deadline: block.timestamp + 300,
            swapToUsdc: true,
            slippageBps: 100,
            routes: exitRoutes
        });
        
        vm.prank(user);
        POSITION_MANAGER.approve(address(atomicOps), tokenId);
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        
        vm.prank(user);
        (uint256 usdcOut, uint256 aeroRewards) = atomicOps.fullExit(exitParams);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);
        
        console.log("\nExit results:");
        console.log("USDC received:", usdcOut);
        console.log("AERO rewards:", aeroRewards);
        console.log("Net USDC change:", usdcAfter - usdcBefore);
        
        assertGt(usdcOut, 2700e6, "Should receive at least 2700 USDC");
    }
}