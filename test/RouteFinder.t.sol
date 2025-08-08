// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/RouteFinder.sol";
import "../contracts/libraries/RouteFinderLib.sol";
import "../interfaces/ICLFactory.sol";
import "../interfaces/ICLPool.sol";

contract RouteFinderTest is Test {
    RouteFinder public routeFinder;
    
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    
    // CL Factory address
    address constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    
    // Fork URL from environment
    string BASE_RPC_URL = vm.envString("BASE_RPC_URL");
    
    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork(BASE_RPC_URL);
        
        // Deploy RouteFinder
        routeFinder = new RouteFinder();
    }
    
    // ============ Pool Discovery Tests ============
    
    function testFindPool_USDC_WETH() public view {
        RouteFinderLib.PoolInfo memory poolInfo = routeFinder.findPool(USDC, WETH);
        
        assertTrue(poolInfo.exists, "USDC/WETH pool should exist");
        assertNotEq(poolInfo.pool, address(0), "Pool address should not be zero");
        assertTrue(poolInfo.tickSpacing > 0, "Tick spacing should be positive");
        
        // Verify the pool is valid
        ICLPool pool = ICLPool(poolInfo.pool);
        assertEq(pool.token0(), USDC < WETH ? USDC : WETH, "Token0 mismatch");
        assertEq(pool.token1(), USDC < WETH ? WETH : USDC, "Token1 mismatch");
    }
    
    function testFindPool_NonExistent() public view {
        // Use two random addresses that likely don't have a pool
        address randomToken1 = address(0x1234567890123456789012345678901234567890);
        address randomToken2 = address(0x0987654321098765432109876543210987654321);
        
        RouteFinderLib.PoolInfo memory poolInfo = routeFinder.findPool(randomToken1, randomToken2);
        
        assertFalse(poolInfo.exists, "Random pool should not exist");
        assertEq(poolInfo.pool, address(0), "Pool address should be zero");
    }
    
    function testFindPool_TokenOrder() public view {
        // Test that token order doesn't matter
        RouteFinderLib.PoolInfo memory poolInfo1 = routeFinder.findPool(USDC, WETH);
        RouteFinderLib.PoolInfo memory poolInfo2 = routeFinder.findPool(WETH, USDC);
        
        assertEq(poolInfo1.pool, poolInfo2.pool, "Pool should be same regardless of token order");
        assertEq(poolInfo1.tickSpacing, poolInfo2.tickSpacing, "Tick spacing should match");
    }
    
    // ============ Position Opening Route Tests ============
    
    function testFindRoutesForPositionOpen_OneTokenIsUSDC() public view {
        // Find the USDC/WETH pool first
        RouteFinderLib.PoolInfo memory poolInfo = routeFinder.findPool(USDC, WETH);
        require(poolInfo.exists, "USDC/WETH pool must exist for this test");
        
        (
            RouteFinderLib.SwapRoute memory token0Route,
            RouteFinderLib.SwapRoute memory token1Route,
            RouteFinderLib.RouteStatus status
        ) = routeFinder.findRoutesForPositionOpen(
            USDC,
            WETH,
            poolInfo.pool,
            poolInfo.tickSpacing
        );
        
        // Since USDC is token0, we only need route for WETH
        assertEq(token0Route.pools.length, 0, "USDC route should be empty");
        assertEq(token1Route.pools.length, 1, "WETH route should have one pool");
        assertEq(uint256(status), uint256(RouteFinderLib.RouteStatus.PARTIAL_SUCCESS), "Should be partial success");
    }
    
    function testFindRoutesForPositionOpen_BothNeedSwap() public view {
        // Test with WETH and AERO (neither is USDC)
        RouteFinderLib.PoolInfo memory poolInfo = routeFinder.findPool(WETH, AERO);
        
        (
            RouteFinderLib.SwapRoute memory token0Route,
            RouteFinderLib.SwapRoute memory token1Route,
            RouteFinderLib.RouteStatus status
        ) = routeFinder.findRoutesForPositionOpen(
            WETH,
            AERO,
            poolInfo.pool,
            poolInfo.tickSpacing
        );
        
        // Both should have routes from USDC
        assertTrue(
            token0Route.pools.length > 0 || token1Route.pools.length > 0,
            "At least one route should be found"
        );
        assertTrue(
            status != RouteFinderLib.RouteStatus.NO_ROUTE,
            "Should find at least partial routes"
        );
    }
    
    // ============ Position Closing Route Tests ============
    
    function testFindRoutesForPositionClose_OneTokenIsUSDC() public view {
        (
            RouteFinderLib.SwapRoute memory token0Route,
            RouteFinderLib.SwapRoute memory token1Route,
            RouteFinderLib.RouteStatus status
        ) = routeFinder.findRoutesForPositionClose(USDC, WETH);
        
        // USDC doesn't need a route, WETH needs route to USDC
        assertEq(token0Route.pools.length, 0, "USDC route should be empty");
        assertTrue(token1Route.pools.length > 0, "WETH should have route to USDC");
        assertTrue(
            status == RouteFinderLib.RouteStatus.SUCCESS || 
            status == RouteFinderLib.RouteStatus.PARTIAL_SUCCESS,
            "Should find routes"
        );
    }
    
    function testFindRoutesForPositionClose_BothNeedSwap() public view {
        (
            RouteFinderLib.SwapRoute memory token0Route,
            RouteFinderLib.SwapRoute memory token1Route,
            RouteFinderLib.RouteStatus status
        ) = routeFinder.findRoutesForPositionClose(WETH, AERO);
        
        // Both should have routes to USDC
        assertTrue(
            token0Route.pools.length > 0 || token1Route.pools.length > 0,
            "At least one route should be found"
        );
        assertTrue(
            status != RouteFinderLib.RouteStatus.NO_ROUTE,
            "Should find at least partial routes"
        );
    }
    
    // ============ Cache Management Tests ============
    
    function testCaching() public {
        // First call should query factory
        routeFinder.findPoolCached(USDC, WETH);
        
        // Second call should use cache (can't directly test this without events)
        RouteFinderLib.PoolInfo memory poolInfo = routeFinder.findPoolCached(USDC, WETH);
        
        assertTrue(poolInfo.exists, "Cached pool should exist");
        assertNotEq(poolInfo.pool, address(0), "Cached pool address should not be zero");
    }
    
    function testWarmCache() public {
        address[] memory token0s = new address[](2);
        address[] memory token1s = new address[](2);
        
        token0s[0] = USDC;
        token0s[1] = WETH;
        token1s[0] = WETH;
        token1s[1] = AERO;
        
        // Should not revert
        routeFinder.warmCache(token0s, token1s);
    }
    
    // ============ Configuration Tests ============
    
    function testUpdateTickSpacings() public {
        int24[] memory newSpacings = new int24[](3);
        newSpacings[0] = 1;
        newSpacings[1] = 10;
        newSpacings[2] = 100;
        
        routeFinder.updateTickSpacings(newSpacings);
        
        int24[] memory spacings = routeFinder.getTickSpacings();
        assertEq(spacings.length, 3, "Should have 3 tick spacings");
        assertEq(spacings[0], int24(1), "First spacing should be 1");
        assertEq(spacings[1], int24(10), "Second spacing should be 10");
        assertEq(spacings[2], int24(100), "Third spacing should be 100");
    }
    
    function testUpdateConnectorTokens() public {
        address[] memory newConnectors = new address[](1);
        newConnectors[0] = WETH;
        
        routeFinder.updateConnectorTokens(newConnectors);
        
        address[] memory connectors = routeFinder.getConnectorTokens();
        assertEq(connectors.length, 1, "Should have 1 connector");
        assertEq(connectors[0], WETH, "Connector should be WETH");
    }
    
    function testUpdateCacheDuration() public {
        uint256 newDuration = 30 minutes;
        routeFinder.updateCacheDuration(newDuration);
        assertEq(routeFinder.cacheDuration(), newDuration, "Cache duration should be updated");
    }
    
    // ============ Access Control Tests ============
    
    function testOnlyOwnerCanUpdateConfig() public {
        address notOwner = address(0x1234);
        
        vm.startPrank(notOwner);
        
        int24[] memory newSpacings = new int24[](1);
        newSpacings[0] = 1;
        
        vm.expectRevert();
        routeFinder.updateTickSpacings(newSpacings);
        
        vm.expectRevert();
        routeFinder.clearCache();
        
        vm.stopPrank();
    }
    
    // ============ Multiple Routes Tests ============
    
    function testFindMultipleRoutes() public view {
        RouteFinder.RouteRequest[] memory requests = new RouteFinder.RouteRequest[](2);
        
        requests[0] = RouteFinder.RouteRequest({
            token0: USDC,
            token1: WETH,
            isPositionOpen: true
        });
        
        requests[1] = RouteFinder.RouteRequest({
            token0: WETH,
            token1: AERO,
            isPositionOpen: false
        });
        
        RouteFinder.RouteResponse[] memory responses = routeFinder.findMultipleRoutes(requests);
        
        assertEq(responses.length, 2, "Should have 2 responses");
        assertTrue(
            responses[0].status != RouteFinderLib.RouteStatus.NO_ROUTE,
            "First request should find routes"
        );
    }
    
    // ============ Edge Cases ============
    
    function testInvalidTokenOrder() public {
        // Test with same token (should be handled gracefully)
        vm.expectRevert();
        routeFinder.findPool(USDC, USDC);
    }
    
    function testZeroAddress() public {
        // Test with zero address
        vm.expectRevert();
        routeFinder.findPool(address(0), USDC);
    }
}