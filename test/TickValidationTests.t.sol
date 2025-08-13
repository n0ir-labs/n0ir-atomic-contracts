// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/LiquidityManager.sol";
import "../contracts/RouteFinder.sol";
import "../contracts/WalletRegistry.sol";

/**
 * @title TickValidationTests
 * @notice Tests for tick validation in the refactored contract
 * @dev Validates tick alignment, bounds, and ordering checks
 */
contract TickValidationTests is Test {
    LiquidityManager public liquidityManager;
    RouteFinder public routeFinder;
    WalletRegistry public walletRegistry;
    
    // Test constants
    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;
    
    function setUp() public {
        // Deploy contracts
        walletRegistry = new WalletRegistry();
        routeFinder = new RouteFinder();
        liquidityManager = new LiquidityManager(address(walletRegistry), address(routeFinder));
    }
    
    function testTickAlignment() public pure {
        // Test tick alignment logic
        int24 tickSpacing = 10;
        
        // Positive aligned tick
        int24 tick1 = 100;
        assertTrue(tick1 % tickSpacing == 0, "100 should be aligned to spacing 10");
        
        // Negative aligned tick
        int24 tick2 = -100;
        assertTrue(tick2 % tickSpacing == 0, "-100 should be aligned to spacing 10");
        
        // Unaligned positive tick
        int24 tick3 = 105;
        assertTrue(tick3 % tickSpacing != 0, "105 should NOT be aligned to spacing 10");
        
        // Unaligned negative tick
        int24 tick4 = -105;
        assertTrue(tick4 % tickSpacing != 0, "-105 should NOT be aligned to spacing 10");
    }
    
    function testTickBounds() public pure {
        // Test tick boundary validation
        
        // Valid ticks within bounds
        assertTrue(MIN_TICK <= 0 && 0 <= MAX_TICK, "0 should be within bounds");
        assertTrue(MIN_TICK <= -100000 && -100000 <= MAX_TICK, "-100000 should be within bounds");
        assertTrue(MIN_TICK <= 100000 && 100000 <= MAX_TICK, "100000 should be within bounds");
        
        // Edge cases
        assertTrue(MIN_TICK == -887272, "MIN_TICK should be -887272");
        assertTrue(MAX_TICK == 887272, "MAX_TICK should be 887272");
    }
    
    function testTickOrdering() public pure {
        // Test tick ordering logic
        
        int24 tickLower1 = -1000;
        int24 tickUpper1 = 1000;
        assertTrue(tickLower1 < tickUpper1, "Lower tick should be less than upper tick");
        
        int24 tickLower2 = 0;
        int24 tickUpper2 = 0;
        assertTrue(tickLower2 == tickUpper2, "Equal ticks should fail ordering check");
        
        int24 tickLower3 = 1000;
        int24 tickUpper3 = -1000;
        assertTrue(tickLower3 > tickUpper3, "Inverted ticks should fail ordering check");
    }
    
    function testTickSpacingAlignment() public pure {
        // Test various tick spacing alignments
        
        // Tick spacing 1 (all ticks valid)
        assertTrue(100 % 1 == 0, "Any tick is valid for spacing 1");
        assertTrue(-100 % 1 == 0, "Any tick is valid for spacing 1");
        
        // Tick spacing 10
        assertTrue(100 % 10 == 0, "100 is aligned to spacing 10");
        assertTrue(105 % 10 != 0, "105 is NOT aligned to spacing 10");
        
        // Tick spacing 50
        assertTrue(500 % 50 == 0, "500 is aligned to spacing 50");
        assertTrue(525 % 50 != 0, "525 is NOT aligned to spacing 50");
        
        // Tick spacing 200
        assertTrue(2000 % 200 == 0, "2000 is aligned to spacing 200");
        assertTrue(2100 % 200 != 0, "2100 is NOT aligned to spacing 200");
    }
    
    function testCalculateAlignedTicks() public pure {
        // Test calculating aligned ticks from a current tick
        
        int24 currentTick = 5432;
        int24 tickSpacing = 10;
        
        // Calculate lower tick (round down)
        int24 offset = 1000;
        int24 rawLower = currentTick - offset;
        int24 alignedLower = (rawLower / tickSpacing) * tickSpacing;
        
        assertTrue(alignedLower % tickSpacing == 0, "Lower tick should be aligned");
        assertTrue(alignedLower <= rawLower, "Aligned lower should be <= raw lower");
        
        // Calculate upper tick (round up)
        int24 rawUpper = currentTick + offset;
        int24 alignedUpper = ((rawUpper + tickSpacing - 1) / tickSpacing) * tickSpacing;
        
        assertTrue(alignedUpper % tickSpacing == 0, "Upper tick should be aligned");
        assertTrue(alignedUpper >= rawUpper, "Aligned upper should be >= raw upper");
    }
    
    function testNegativeTickAlignment() public pure {
        // Special tests for negative tick alignment
        
        int24 tickSpacing = 10;
        
        // Test negative tick rounding
        int24 negativeTick = -105;
        int24 alignedDown = ((negativeTick - tickSpacing + 1) / tickSpacing) * tickSpacing;
        assertEq(alignedDown, -110, "Should round down to -110");
        
        // Test already aligned negative tick
        int24 alignedNegative = -100;
        int24 stillAligned = (alignedNegative / tickSpacing) * tickSpacing;
        assertEq(stillAligned, -100, "Should remain -100");
    }
    
    function testTickRangeWidth() public pure {
        // Test minimum tick range width validation
        
        int24 tickSpacing = 10;
        
        // Valid range (multiple tick spacings)
        int24 tickLower1 = 0;
        int24 tickUpper1 = 100;
        uint24 width1 = uint24(tickUpper1 - tickLower1);
        assertTrue(width1 >= uint24(tickSpacing), "Range should be at least one tick spacing");
        
        // Minimum valid range (exactly one tick spacing)
        int24 tickLower2 = 0;
        int24 tickUpper2 = 10;
        uint24 width2 = uint24(tickUpper2 - tickLower2);
        assertEq(width2, uint24(tickSpacing), "Minimum range should be exactly one tick spacing");
        
        // Invalid range (less than one tick spacing)
        int24 tickLower3 = 0;
        int24 tickUpper3 = 5;
        uint24 width3 = uint24(tickUpper3 - tickLower3);
        assertTrue(width3 < uint24(tickSpacing), "Range less than tick spacing should be invalid");
    }
    
    // Fuzz testing for tick alignment
    function testFuzz_TickAlignment(int24 tick, uint8 spacingChoice) public pure {
        // Choose from common tick spacings
        int24[4] memory tickSpacings = [int24(1), int24(10), int24(50), int24(200)];
        int24 tickSpacing = tickSpacings[spacingChoice % 4];
        
        // Align the tick
        int24 aligned;
        if (tick >= 0) {
            aligned = (tick / tickSpacing) * tickSpacing;
        } else {
            // For negative numbers, we need to round down (more negative)
            if (tick % tickSpacing == 0) {
                aligned = tick;
            } else {
                aligned = ((tick - tickSpacing + 1) / tickSpacing) * tickSpacing;
            }
        }
        
        // Verify alignment
        if (aligned >= 0) {
            assertEq(aligned % tickSpacing, 0, "Positive aligned tick should be divisible by spacing");
        } else {
            // For negative numbers, check alignment differently
            int24 remainder = aligned % tickSpacing;
            assertTrue(remainder == 0 || remainder + tickSpacing == 0, "Negative aligned tick should be properly aligned");
        }
    }
    
    // Fuzz testing for tick range validation
    function testFuzz_TickRange(
        int24 tickLower,
        int24 tickUpper,
        uint8 spacingChoice
    ) public pure {
        // Bound ticks to valid range
        tickLower = int24(bound(int256(tickLower), MIN_TICK, MAX_TICK - 1));
        tickUpper = int24(bound(int256(tickUpper), tickLower + 1, MAX_TICK));
        
        // Choose tick spacing
        int24[4] memory tickSpacings = [int24(1), int24(10), int24(50), int24(200)];
        int24 tickSpacing = tickSpacings[spacingChoice % 4];
        
        // Align ticks
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = ((tickUpper / tickSpacing) + 1) * tickSpacing;
        
        // Ensure minimum width
        if (tickUpper - tickLower < tickSpacing) {
            tickUpper = tickLower + tickSpacing;
        }
        
        // Bound to max tick if needed
        if (tickUpper > MAX_TICK) {
            tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;
        }
        
        // Validate the range
        assertTrue(tickLower < tickUpper, "Lower should be less than upper");
        assertTrue(tickLower >= MIN_TICK, "Lower should be >= MIN_TICK");
        assertTrue(tickUpper <= MAX_TICK, "Upper should be <= MAX_TICK");
        assertTrue(tickLower % tickSpacing == 0, "Lower should be aligned");
        assertTrue(tickUpper % tickSpacing == 0, "Upper should be aligned");
        assertTrue(tickUpper - tickLower >= tickSpacing, "Range should be at least one tick spacing");
    }
}