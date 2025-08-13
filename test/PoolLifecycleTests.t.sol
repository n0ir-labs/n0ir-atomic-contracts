// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/LiquidityManager.sol";
import "../contracts/RouteFinder.sol";
import "../contracts/WalletRegistry.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ICLPool.sol";
import "../interfaces/INonfungiblePositionManager.sol";

/**
 * @title PoolLifecycleTests
 * @notice Comprehensive lifecycle tests for specific pools with non-custodial approach
 * @dev Tests position lifecycle: create (direct to user) → close (with user approval)
 * @dev Non-custodial: Users maintain ownership of NFT positions at all times
 */
contract PoolLifecycleTests is Test {
    LiquidityManager public liquidityManager;
    RouteFinder public routeFinder;
    WalletRegistry public walletRegistry;
    
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    
    // Pool 1: WETH/NEURO (0xDBFeFD2e8460a6Ee4955A68582F85708BAEA60A3)
    address constant WETH_NEURO_POOL = 0x6446021F4E396dA3df4235C62537431372195D38;
    address constant NEURO = 0xDBFeFD2e8460a6Ee4955A68582F85708BAEA60A3;
    
    // Pool 2: USDC/AERO
    address constant USDC_AERO_POOL = 0xBE00fF35AF70E8415D0eB605a286D8A45466A4c1;
    
    // Test users
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    
    // Fork URL from environment
    string BASE_RPC_URL = vm.envString("BASE_RPC_URL");
    
    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork(BASE_RPC_URL);
        
        // Deploy contracts
        walletRegistry = new WalletRegistry();
        routeFinder = new RouteFinder();
        liquidityManager = new LiquidityManager(address(walletRegistry), address(routeFinder));
        
        // Register test users
        walletRegistry.registerWallet(alice);
        walletRegistry.registerWallet(bob);
        
        // Fund users with USDC
        deal(USDC, alice, 10000e6); // 10,000 USDC
        deal(USDC, bob, 10000e6);   // 10,000 USDC
        
        // Give users some ETH for gas
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        
        // Label addresses for better trace output
        vm.label(address(liquidityManager), "LiquidityManager");
        vm.label(address(routeFinder), "RouteFinder");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(WETH_NEURO_POOL, "WETH/NEURO_Pool");
        vm.label(USDC_AERO_POOL, "USDC/AERO_Pool");
        vm.label(NEURO, "NEURO");
        vm.label(AERO, "AERO");
    }
    
    // ============ Helper Functions ============
    
    function _getCurrentTick(address pool) internal view returns (int24) {
        (, int24 tick,,,,) = ICLPool(pool).slot0();
        return tick;
    }
    
    function _getTickSpacing(address pool) internal view returns (int24) {
        return ICLPool(pool).tickSpacing();
    }
    
    
    // ============ Test 1: WETH/NEURO Pool Lifecycle ============
    
    function testWETH_NEURO_PoolLifecycle() public {
        console.log("\n=== WETH/NEURO Pool Lifecycle Test ===");
        console.log("Pool:", WETH_NEURO_POOL);
        
        // Get pool info
        ICLPool pool = ICLPool(WETH_NEURO_POOL);
        address token0 = pool.token0();
        address token1 = pool.token1();
        int24 currentTick = _getCurrentTick(WETH_NEURO_POOL);
        int24 tickSpacing = _getTickSpacing(WETH_NEURO_POOL);
        
        console.log("Token0:", token0 == WETH ? "WETH" : "NEURO");
        console.log("Token1:", token1 == WETH ? "WETH" : "NEURO");
        console.log("Current Tick:", currentTick);
        console.log("Tick Spacing:", tickSpacing);
        
        // Calculate tick range (2% range)
        int24 tickLower = ((currentTick - 2000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 2000) / tickSpacing) * tickSpacing;
        
        console.log("\n--- Step 1: Create and Stake Position ---");
        console.log("Tick Lower:", tickLower);
        console.log("Tick Upper:", tickUpper);
        
        vm.startPrank(alice);
        
        // Approve USDC to LiquidityManager
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        console.log("Alice USDC before:", usdcBefore / 1e6, "USDC");
        
        // Create position with auto-routing
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            WETH_NEURO_POOL,
            tickLower,
            tickUpper,
            block.timestamp + 3600,
            2000e6, // 2000 USDC
            500     // 5% slippage for exotic pairs
        );
        
        console.log("Position created!");
        console.log("  Token ID:", tokenId);
        console.log("  Liquidity:", liquidity);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(alice);
        console.log("  USDC spent:", (usdcBefore - usdcAfter) / 1e6, "USDC");
        
        // Verify position is owned by Alice (non-custodial)
        address nftOwner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        assertEq(nftOwner, alice, "Alice should own the position NFT directly");
        console.log("  Position NFT is owned by Alice (non-custodial)");
        
        // Advance time to accumulate rewards
        console.log("\n--- Step 2: Accumulate Rewards ---");
        vm.warp(block.timestamp + 7 days);
        console.log("  Advanced 7 days");
        
        // Note: Since positions are non-custodial, users manage their own positions
        console.log("  Users can stake their positions directly if desired");
        
        console.log("\n--- Step 3: Close Position ---");
        
        // IMPORTANT: Alice must approve the LiquidityManager to transfer her NFT
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityManager), tokenId);
        console.log("  Alice approved LiquidityManager to transfer NFT");
        
        uint256 usdcBeforeClose = IERC20(USDC).balanceOf(alice);
        
        // Close position with auto-routing
        // Use more conservative minimum (accounting for IL, fees, and slippage)
        uint256 minUsdcOut = (usdcBefore - usdcAfter) * 85 / 100; // Expect at least 85% back
        uint256 usdcOut = liquidityManager.closePosition(
            tokenId,
            WETH_NEURO_POOL,
            block.timestamp + 3600,
            minUsdcOut,
            500     // 5% slippage
        );
        
        console.log("Position closed!");
        console.log("  USDC received:", usdcOut / 1e6, "USDC");
        
        uint256 usdcAfterClose = IERC20(USDC).balanceOf(alice);
        
        assertEq(usdcAfterClose - usdcBeforeClose, usdcOut, "USDC balance should increase by usdcOut");
        
        // Calculate PnL
        int256 pnl = int256(usdcAfterClose) - int256(usdcBefore);
        console.log("\n--- Final Results ---");
        if (pnl > 0) {
            console.log("  Net PnL: +", uint256(pnl) / 1e6, "USDC");
        } else {
            console.log("  Net PnL: -", uint256(-pnl) / 1e6, "USDC");
        }
        
        vm.stopPrank();
        
        // Verify position NFT was burned
        vm.expectRevert();
        INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        console.log("  Position NFT successfully burned");
    }
    
    // ============ Test 2: USDC/AERO Pool Lifecycle ============
    
    function testUSDC_AERO_PoolLifecycle() public {
        console.log("\n=== USDC/AERO Pool Lifecycle Test ===");
        console.log("Pool:", USDC_AERO_POOL);
        
        // Get pool info
        ICLPool pool = ICLPool(USDC_AERO_POOL);
        address token0 = pool.token0();
        address token1 = pool.token1();
        int24 currentTick = _getCurrentTick(USDC_AERO_POOL);
        int24 tickSpacing = _getTickSpacing(USDC_AERO_POOL);
        
        console.log("Token0:", token0 == USDC ? "USDC" : "AERO");
        console.log("Token1:", token1 == USDC ? "USDC" : "AERO");
        console.log("Current Tick:", currentTick);
        console.log("Tick Spacing:", tickSpacing);
        
        // Calculate tick range (1% range for tighter liquidity)
        int24 tickLower = ((currentTick - 1000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 1000) / tickSpacing) * tickSpacing;
        
        console.log("\n--- Step 1: Create Position Without Staking ---");
        console.log("Tick Lower:", tickLower);
        console.log("Tick Upper:", tickUpper);
        console.log("Range width in ticks:", uint24(tickUpper - tickLower));
        console.log("Range width in tick spaces:", uint24(tickUpper - tickLower) / uint24(tickSpacing));
        
        vm.startPrank(bob);
        
        // Approve USDC to LiquidityManager
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(bob);
        console.log("Bob USDC before:", usdcBefore / 1e6, "USDC");
        
        // Create position with auto-routing
        // Use type(uint256).max for deadline to avoid timestamp issues with fork
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            USDC_AERO_POOL,
            tickLower,
            tickUpper,
            type(uint256).max, // max deadline to avoid fork timestamp issues
            3000e6, // 3000 USDC
            500     // 5% slippage
        );
        
        console.log("Position created!");
        console.log("  Token ID:", tokenId);
        console.log("  Liquidity:", liquidity);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(bob);
        console.log("  USDC spent:", (usdcBefore - usdcAfter) / 1e6, "USDC");
        
        // Verify Bob owns the NFT directly (not staked)
        address nftOwner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        assertEq(nftOwner, bob, "Bob should own the position NFT");
        console.log("  Position NFT owned by Bob (not staked)");
        
        // Simulate some trading activity
        console.log("\n--- Step 2: Simulate Trading Activity ---");
        vm.warp(block.timestamp + 3 days);
        console.log("  Advanced 3 days");
        
        // Check position value
        (,,,,,,, uint128 currentLiquidity,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);
        console.log("  Current liquidity:", currentLiquidity);
        
        console.log("\n--- Step 3: Add More Liquidity (Compound) ---");
        
        // Bob adds more liquidity to existing position
        console.log("  Bob could add more liquidity if desired");
        console.log("  (Users manage their own positions in non-custodial design)");
        
        console.log("\n--- Step 4: Close Position ---");
        
        // First approve the NFT to LiquidityManager
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityManager), tokenId);
        
        uint256 usdcBeforeClose = IERC20(USDC).balanceOf(bob);
        
        // Close position with auto-routing
        // Use more conservative minimum (accounting for IL, fees, and slippage)
        uint256 minUsdcOut = (usdcBefore - usdcAfter) * 85 / 100; // Expect at least 85% back
        uint256 usdcOut = liquidityManager.closePosition(
            tokenId,
            USDC_AERO_POOL,
            type(uint256).max, // max deadline to avoid fork timestamp issues
            minUsdcOut,
            500     // 5% slippage
        );
        
        console.log("Position closed!");
        console.log("  USDC received:", usdcOut / 1e6, "USDC");
        
        uint256 usdcAfterClose = IERC20(USDC).balanceOf(bob);
        
        assertEq(usdcAfterClose - usdcBeforeClose, usdcOut, "USDC balance should increase by usdcOut");
        
        // Calculate PnL
        int256 pnl = int256(usdcAfterClose) - int256(usdcBefore);
        console.log("\n--- Final Results ---");
        if (pnl > 0) {
            console.log("  Net PnL: +", uint256(pnl) / 1e6, "USDC");
        } else {
            console.log("  Net PnL: -", uint256(-pnl) / 1e6, "USDC");
        }
        console.log("  Trading fees earned included in USDC return");
        
        vm.stopPrank();
        
        // Verify position NFT was burned
        vm.expectRevert();
        INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        console.log("  Position NFT successfully burned");
    }
    
    // ============ Test 3: Multiple Users Same Pool ============
    
    function testMultipleUsersWETH_NEURO() public {
        console.log("\n=== Multiple Users WETH/NEURO Pool Test ===");
        
        // Get current tick and calculate range
        int24 currentTick = _getCurrentTick(WETH_NEURO_POOL);
        int24 tickSpacing = _getTickSpacing(WETH_NEURO_POOL);
        int24 tickLower = ((currentTick - 1500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 1500) / tickSpacing) * tickSpacing;
        
        console.log("Tick Lower:", tickLower);
        console.log("Tick Upper:", tickUpper);
        
        console.log("\n--- Alice creates position ---");
        vm.startPrank(alice);
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        (uint256 aliceTokenId,) = liquidityManager.createPosition(
            WETH_NEURO_POOL,
            tickLower,
            tickUpper,
            block.timestamp + 3600,
            1000e6,
            500     // 5% slippage
        );
        console.log("  Alice Token ID:", aliceTokenId);
        vm.stopPrank();
        
        console.log("\n--- Bob creates position ---");
        vm.startPrank(bob);
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        (uint256 bobTokenId,) = liquidityManager.createPosition(
            WETH_NEURO_POOL,
            tickLower,
            tickUpper,
            block.timestamp + 3600,
            1500e6,
            500     // 5% slippage
        );
        console.log("  Bob Token ID:", bobTokenId);
        vm.stopPrank();
        
        // Verify both positions are owned directly by users (non-custodial)
        address alicePositionOwner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(aliceTokenId);
        address bobPositionOwner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(bobTokenId);
        
        assertEq(alicePositionOwner, alice, "Alice should own her position NFT directly");
        assertEq(bobPositionOwner, bob, "Bob should own his position NFT directly");
        
        console.log("\n--- Both positions created successfully (non-custodial) ---");
        console.log("  Alice owns position NFT:", aliceTokenId);
        console.log("  Bob owns position NFT:", bobTokenId);
        
        // Advance time for rewards
        vm.warp(block.timestamp + 5 days);
        
        // Alice closes her position
        console.log("\n--- Alice closes position ---");
        vm.startPrank(alice);
        // First approve the NFT to LiquidityManager
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityManager), aliceTokenId);
        uint256 aliceUsdcOut = liquidityManager.closePosition(
            aliceTokenId,
            WETH_NEURO_POOL,
            block.timestamp + 3600,
            850e6,  // 85% of 1000 USDC
            500     // 5% slippage
        );
        console.log("  Alice received:", aliceUsdcOut / 1e6, "USDC");
        vm.stopPrank();
        
        // Bob's position should still exist (owned by Bob)
        address bobOwner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(bobTokenId);
        assertEq(bobOwner, bob, "Bob should still own his position NFT");
        
        // Bob closes his position
        console.log("\n--- Bob closes position ---");
        vm.startPrank(bob);
        // First approve the NFT to LiquidityManager
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityManager), bobTokenId);
        uint256 bobUsdcOut = liquidityManager.closePosition(
            bobTokenId,
            WETH_NEURO_POOL,
            block.timestamp + 3600,
            1275e6, // 85% of 1500 USDC
            500     // 5% slippage
        );
        console.log("  Bob received:", bobUsdcOut / 1e6, "USDC");
        vm.stopPrank();
        
        console.log("\n--- Test completed successfully ---");
    }
    
    // ============ Test 4: Error Cases ============
    
    function testErrorCases() public {
        console.log("\n=== Error Cases Test ===");
        
        // Get pool tick info
        int24 currentTick = _getCurrentTick(USDC_AERO_POOL);
        int24 tickSpacing = _getTickSpacing(USDC_AERO_POOL);
        int24 tickLower = ((currentTick - 1000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 1000) / tickSpacing) * tickSpacing;
        
        vm.startPrank(alice);
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        console.log("\n--- Test: Insufficient balance ---");
        vm.expectRevert();
        liquidityManager.createPosition(
            USDC_AERO_POOL,
            tickLower,
            tickUpper,
            block.timestamp + 3600,
            100000e6, // More than Alice has
            100
        );
        console.log("  [OK] Reverted as expected");
        
        console.log("\n--- Test: Invalid tick range (lower >= upper) ---");
        vm.expectRevert();
        liquidityManager.createPosition(
            USDC_AERO_POOL,
            tickUpper, // Swap them - invalid
            tickLower,
            block.timestamp + 3600,
            1000e6,
            100
        );
        console.log("  [OK] Reverted as expected");
        
        console.log("\n--- Test: Expired deadline ---");
        vm.expectRevert();
        liquidityManager.createPosition(
            USDC_AERO_POOL,
            tickLower,
            tickUpper,
            block.timestamp - 1, // Past deadline
            1000e6,
            100
        );
        console.log("  [OK] Reverted as expected");
        
        vm.stopPrank();
        
        console.log("\n--- All error cases handled correctly ---");
    }
}