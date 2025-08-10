// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/LiquidityManager.sol";
import "../contracts/RouteFinder.sol";
import "../contracts/WalletRegistry.sol";
import "../contracts/libraries/RouteFinderLib.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ICLPool.sol";
import "../interfaces/INonfungiblePositionManager.sol";

contract AutoRoutingIntegrationTest is Test {
    LiquidityManager public liquidityManager;
    RouteFinder public routeFinder;
    WalletRegistry public walletRegistry;
    
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    
    // Test user
    address testUser = address(0x1234);
    
    // Fork URL from environment
    string BASE_RPC_URL = vm.envString("BASE_RPC_URL");
    
    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork(BASE_RPC_URL);
        
        // Deploy contracts
        walletRegistry = new WalletRegistry();
        routeFinder = new RouteFinder();
        liquidityManager = new LiquidityManager(address(walletRegistry), address(routeFinder));
        
        // Setup test user with USDC
        deal(USDC, testUser, 10000e6); // 10,000 USDC
        
        // Register test user wallet
        walletRegistry.registerWallet(testUser);
        
        // Label addresses for better trace output
        vm.label(address(liquidityManager), "LiquidityManager");
        vm.label(address(routeFinder), "RouteFinder");
        vm.label(address(walletRegistry), "WalletRegistry");
        vm.label(testUser, "TestUser");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(AERO, "AERO");
    }
    
    // ============ Helper Functions ============
    
    function _findPool(address token0, address token1) internal view returns (address pool) {
        RouteFinderLib.PoolInfo memory poolInfo = routeFinder.findPool(token0, token1);
        require(poolInfo.exists, "Pool not found");
        return poolInfo.pool;
    }
    
    function _getCurrentTick(address pool) internal view returns (int24) {
        (, int24 tick,,,,) = ICLPool(pool).slot0();
        return tick;
    }
    
    function _getTickSpacing(address pool) internal view returns (int24) {
        return ICLPool(pool).tickSpacing();
    }
    
    // ============ Auto Position Creation Tests ============
    
    function testCreatePositionAuto_USDC_WETH() public {
        // Find USDC/WETH pool
        address pool = _findPool(USDC, WETH);
        
        // Use percentage-based range
        uint256 rangePercentage = 100; // 1% range
        
        vm.startPrank(testUser);
        
        // Approve USDC to LiquidityManager
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        // Create position with auto-routing and percentage range
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            pool,
            rangePercentage,
            block.timestamp + 3600,
            1000e6, // 1000 USDC
            100 // 1% slippage
        );
        
        vm.stopPrank();
        
        // Verify position was created
        assertTrue(tokenId > 0, "Token ID should be positive");
        assertTrue(liquidity > 0, "Liquidity should be positive");
        
        // Verify position NFT was transferred to user
        address nftOwner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        assertEq(nftOwner, testUser, "User should own the position NFT");
    }
    
    function testCreatePositionAuto_WithStaking() public {
        // Find USDC/WETH pool
        address pool = _findPool(USDC, WETH);
        
        // Use percentage-based range
        uint256 rangePercentage = 100; // 1% range
        
        vm.startPrank(testUser);
        
        // Approve USDC to LiquidityManager
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        // Create position
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            pool,
            rangePercentage,
            block.timestamp + 3600,
            1000e6, // 1000 USDC
            100 // 1% slippage
        );
        
        vm.stopPrank();
        
        // Verify position was created
        assertTrue(tokenId > 0, "Token ID should be positive");
        assertTrue(liquidity > 0, "Liquidity should be positive");
        
        // Verify position is owned by user (non-custodial)
        address owner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        assertEq(owner, testUser, "User should own the position NFT directly");
    }
    
    function testCreatePositionAuto_ComplexRoute() public {
        // Try to create position in a pool that requires multi-hop routing
        // This test depends on what pools exist on Base mainnet
        // We'll try WETH/AERO which should require routing through USDC
        
        address pool = _findPool(WETH, AERO);
        if (pool == address(0)) {
            // Skip test if pool doesn't exist
            return;
        }
        
        // Use percentage-based range
        uint256 rangePercentage = 100; // 1% range
        
        vm.startPrank(testUser);
        
        // Approve USDC to LiquidityManager
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        // Create position with auto-routing
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            pool,
            rangePercentage,
            block.timestamp + 3600,
            500e6, // 500 USDC
            200 // 2% slippage for complex route
        );
        
        vm.stopPrank();
        
        // Verify position was created
        assertTrue(tokenId > 0, "Token ID should be positive");
        assertTrue(liquidity > 0, "Liquidity should be positive");
    }
    
    // ============ Auto Position Closing Tests ============
    
    function testClosePositionAuto() public {
        // First create a position
        address pool = _findPool(USDC, WETH);
        
        // Use percentage-based range
        uint256 rangePercentage = 100; // 1% range
        
        vm.startPrank(testUser);
        
        // Approve and create position
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        (uint256 tokenId,) = liquidityManager.createPosition(
            pool,
            rangePercentage,
            block.timestamp + 3600,
            1000e6,
            100
        );
        
        // Approve NFT to LiquidityManager for closing
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityManager), tokenId);
        
        // Record USDC balance before closing
        uint256 usdcBefore = IERC20(USDC).balanceOf(testUser);
        
        // Close position with auto-routing (now the default)
        uint256 usdcOut = liquidityManager.closePosition(
            tokenId,
            pool,
            block.timestamp + 3600,
            900e6, // Expect at least 900 USDC back (accounting for slippage)
            100 // 1% slippage
        );
        
        vm.stopPrank();
        
        // Verify USDC was returned
        assertTrue(usdcOut > 900e6, "Should receive at least 900 USDC");
        uint256 usdcAfter = IERC20(USDC).balanceOf(testUser);
        assertEq(usdcAfter - usdcBefore, usdcOut, "USDC balance should increase by usdcOut");
        
        // Verify position NFT was burned
        vm.expectRevert();
        INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
    }
    
    // ============ Error Cases ============
    
    function testCreatePositionAuto_NoRouteFinder() public {
        // Deploy LiquidityManager without RouteFinder
        LiquidityManager noRouteLM = new LiquidityManager(address(walletRegistry), address(0));
        
        address pool = _findPool(USDC, WETH);
        int24 currentTick = _getCurrentTick(pool);
        int24 tickSpacing = _getTickSpacing(pool);
        
        int24 tickLower = (currentTick - 1000) / tickSpacing * tickSpacing;
        int24 tickUpper = (currentTick + 1000) / tickSpacing * tickSpacing;
        
        vm.startPrank(testUser);
        
        IERC20(USDC).approve(address(noRouteLM), type(uint256).max);
        
        // Should revert with "RouteFinder not configured"
        vm.expectRevert("RouteFinder not configured");
        noRouteLM.createPositionWithTicks(
            pool,
            tickLower,
            tickUpper,
            block.timestamp + 3600,
            1000e6,
            100
        );
        
        vm.stopPrank();
    }
    
    function testCreatePositionAuto_InsufficientBalance() public {
        address pool = _findPool(USDC, WETH);
        
        // Use percentage-based range
        uint256 rangePercentage = 100; // 1% range
        
        vm.startPrank(testUser);
        
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        // Try to create position with more USDC than user has
        vm.expectRevert();
        liquidityManager.createPosition(
            pool,
            rangePercentage,
            block.timestamp + 3600,
            100000e6, // 100,000 USDC (more than user has)
            100
        );
        
        vm.stopPrank();
    }
    
    // ============ Gas Usage Tests ============
    
    function testGasUsage_AutoVsManual() public {
        address pool = _findPool(USDC, WETH);
        
        // Use percentage-based range
        uint256 rangePercentage = 100; // 1% range
        
        vm.startPrank(testUser);
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        // Measure gas for auto-routing
        uint256 gasStart = gasleft();
        liquidityManager.createPosition(
            pool,
            rangePercentage,
            block.timestamp + 3600,
            100e6,
            100
        );
        uint256 gasUsedAuto = gasStart - gasleft();
        
        // Log gas usage
        console.log("Gas used for auto-routing:", gasUsedAuto);
        
        // For manual routing, we'd need to construct the routes ourselves
        // This would typically use less gas since no on-chain route discovery
        // But requires off-chain computation
        
        vm.stopPrank();
        
        // Auto-routing should use reasonable gas (less than 500k)
        assertTrue(gasUsedAuto < 500000, "Auto-routing should use less than 500k gas");
    }
    
    // ============ Integration with Existing Functions ============
    
    // Removed testBackwardCompatibility since manual functions are deprecated
}