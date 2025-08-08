// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/LiquidityManager.sol";
import "../contracts/RouteFinder.sol";
import "../contracts/WalletRegistry.sol";

/**
 * @title TickCalculationTests
 * @notice Tests for percentage-based tick calculations
 * @dev Validates the calculateTicksFromPercentage function
 */
contract TickCalculationTests is Test {
    LiquidityManager public liquidityManager;
    RouteFinder public routeFinder;
    WalletRegistry public walletRegistry;
    
    function setUp() public {
        // Deploy contracts
        walletRegistry = new WalletRegistry();
        routeFinder = new RouteFinder();
        liquidityManager = new LiquidityManager(address(walletRegistry), address(routeFinder));
    }
    
    function testCalculateTicksFromPercentage_BasicRange() public view {
        // Test 1% range
        int24 currentTick = 0;
        uint256 rangePercentage = 100; // 1%
        int24 tickSpacing = 10;
        
        (int24 tickLower, int24 tickUpper) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            tickSpacing
        );
        
        // Expected: ±10000 ticks (1% ≈ 100 * 100 = 10000 ticks)
        // Aligned to tick spacing of 10
        assertEq(tickLower, -10000, "Lower tick should be -10000");
        assertEq(tickUpper, 10000, "Upper tick should be 10000");
    }
    
    function testCalculateTicksFromPercentage_WithPositiveTick() public view {
        // Test with positive current tick
        int24 currentTick = 5000;
        uint256 rangePercentage = 200; // 2%
        int24 tickSpacing = 50;
        
        (int24 tickLower, int24 tickUpper) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            tickSpacing
        );
        
        // Expected: 5000 ± 20000 = [-15000, 25000]
        // Aligned to tick spacing of 50
        assertEq(tickLower, -15000, "Lower tick should be -15000");
        assertEq(tickUpper, 25000, "Upper tick should be 25000");
    }
    
    function testCalculateTicksFromPercentage_WithNegativeTick() public view {
        // Test with negative current tick
        int24 currentTick = -3000;
        uint256 rangePercentage = 500; // 5%
        int24 tickSpacing = 100;
        
        (int24 tickLower, int24 tickUpper) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            tickSpacing
        );
        
        // Expected: -3000 ± 50000 = [-53000, 47000]
        // Aligned to tick spacing of 100
        assertEq(tickLower, -53000, "Lower tick should be -53000");
        assertEq(tickUpper, 47000, "Upper tick should be 47000");
    }
    
    function testCalculateTicksFromPercentage_SmallRange() public view {
        // Test very small range (0.1%)
        int24 currentTick = 1000;
        uint256 rangePercentage = 10; // 0.1%
        int24 tickSpacing = 1;
        
        (int24 tickLower, int24 tickUpper) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            tickSpacing
        );
        
        // Expected: 1000 ± 1000 = [0, 2000]
        assertEq(tickLower, 0, "Lower tick should be 0");
        assertEq(tickUpper, 2000, "Upper tick should be 2000");
    }
    
    function testCalculateTicksFromPercentage_LargeRange() public view {
        // Test large range (10%)
        int24 currentTick = 0;
        uint256 rangePercentage = 1000; // 10%
        int24 tickSpacing = 200;
        
        (int24 tickLower, int24 tickUpper) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            tickSpacing
        );
        
        // Expected: 0 ± 100000 = [-100000, 100000]
        // Aligned to tick spacing of 200
        assertEq(tickLower, -100000, "Lower tick should be -100000");
        assertEq(tickUpper, 100000, "Upper tick should be 100000");
    }
    
    function testCalculateTicksFromPercentage_BoundaryConditions() public view {
        // Test near max tick boundary
        int24 currentTick = 880000;
        uint256 rangePercentage = 100; // 1%
        int24 tickSpacing = 10;
        
        (int24 tickLower, int24 tickUpper) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            tickSpacing
        );
        
        // Upper tick should be capped at MAX_TICK aligned to tick spacing
        // MAX_TICK = 887272, aligned to tickSpacing=10 becomes 887270
        assertEq(tickLower, 870000, "Lower tick should be 870000");
        assertEq(tickUpper, 887270, "Upper tick should be capped at MAX_TICK aligned to tick spacing");
    }
    
    function testCalculateTicksFromPercentage_MinimumRange() public view {
        // Test that minimum range is enforced
        int24 currentTick = 0;
        uint256 rangePercentage = 1; // 0.01% - very small
        int24 tickSpacing = 100;
        
        (int24 tickLower, int24 tickUpper) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            tickSpacing
        );
        
        // Should ensure at least one tick spacing difference
        assertTrue(tickUpper > tickLower, "Upper tick should be greater than lower tick");
        assertTrue(tickUpper - tickLower >= tickSpacing, "Range should be at least one tick spacing");
    }
    
    function testCalculateTicksFromPercentage_VariousTickSpacings() public view {
        int24 currentTick = 10000;
        uint256 rangePercentage = 300; // 3%
        
        // Test with tick spacing = 1
        (int24 lower1, int24 upper1) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            1
        );
        
        // Test with tick spacing = 10
        (int24 lower10, int24 upper10) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            10
        );
        
        // Test with tick spacing = 50
        (int24 lower50, int24 upper50) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            50
        );
        
        // Test with tick spacing = 200
        (int24 lower200, int24 upper200) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            200
        );
        
        // Verify alignment
        assertEq(lower1 % 1, 0, "Should be aligned to tick spacing 1");
        assertEq(lower10 % 10, 0, "Should be aligned to tick spacing 10");
        assertEq(lower50 % 50, 0, "Should be aligned to tick spacing 50");
        assertEq(lower200 % 200, 0, "Should be aligned to tick spacing 200");
        
        // Upper ticks should also be aligned
        assertTrue(upper1 % 1 == 0, "Upper should be aligned to tick spacing 1");
        assertTrue(upper10 % 10 == 0, "Upper should be aligned to tick spacing 10");
        assertTrue(upper50 % 50 == 0, "Upper should be aligned to tick spacing 50");
        assertTrue(upper200 % 200 == 0, "Upper should be aligned to tick spacing 200");
    }
    
    function testCalculateTicksFromPercentage_FuzzTesting(
        int24 currentTick,
        uint16 rangePercentageBps,
        uint8 tickSpacingChoice
    ) public view {
        // Bound inputs to reasonable ranges
        currentTick = int24(bound(int256(currentTick), -500000, 500000));
        rangePercentageBps = uint16(bound(uint256(rangePercentageBps), 1, 10000)); // 0.01% to 100%
        
        // Choose from common tick spacings
        int24[4] memory tickSpacings = [int24(1), int24(10), int24(50), int24(200)];
        int24 tickSpacing = tickSpacings[tickSpacingChoice % 4];
        
        (int24 tickLower, int24 tickUpper) = liquidityManager.calculateTicksFromPercentage(
            currentTick,
            uint256(rangePercentageBps),
            tickSpacing
        );
        
        // Invariants that should always hold
        assertTrue(tickLower < tickUpper, "Lower tick should be less than upper tick");
        assertTrue(tickLower >= -887272, "Lower tick should be >= MIN_TICK");
        assertTrue(tickUpper <= 887272, "Upper tick should be <= MAX_TICK");
        
        // Check alignment (handle negative modulo correctly)
        int24 lowerMod = tickLower % tickSpacing;
        if (lowerMod < 0) lowerMod += tickSpacing;
        assertEq(lowerMod, 0, "Lower tick should be aligned to tick spacing");
        
        int24 upperMod = tickUpper % tickSpacing;
        if (upperMod < 0) upperMod += tickSpacing;
        assertEq(upperMod, 0, "Upper tick should be aligned to tick spacing");
    }
}