// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/LiquidityManager.sol";
import "../contracts/RouteFinder.sol";
import "../contracts/WalletRegistry.sol";
import "../interfaces/ICLPool.sol";
import "../interfaces/IERC20.sol";

/**
 * @title RefactoredTickTests
 * @notice Tests for the refactored tick-based position creation
 * @dev Validates the new direct tick input approach
 */
contract RefactoredTickTests is Test {
    LiquidityManager public liquidityManager;
    RouteFinder public routeFinder;
    WalletRegistry public walletRegistry;
    
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    // Test pools (Base mainnet)
    address constant USDC_WETH_POOL_005 = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // 0.05% fee
    address constant USDC_WETH_POOL_03 = 0xB4885Bc63399BF5518b994c1d0C153334Ee579D0; // 0.3% fee
    
    // Test user
    address alice = makeAddr("alice");
    
    // Fork setup
    uint256 baseFork;
    
    function setUp() public {
        // Fork Base mainnet
        baseFork = vm.createFork(vm.envString("BASE_RPC_URL"));
        vm.selectFork(baseFork);
        
        // Deploy contracts
        walletRegistry = new WalletRegistry();
        routeFinder = new RouteFinder();
        liquidityManager = new LiquidityManager(address(walletRegistry), address(routeFinder));
        
        // Register test user
        walletRegistry.registerWallet(alice);
        
        // Fund user
        deal(USDC, alice, 100000e6);
        vm.deal(alice, 10 ether);
        
        // Approve liquidityManager for USDC
        vm.prank(alice);
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
    }
    
    // ============ Direct Tick Input Tests ============
    
    function testCreatePosition_WithValidTicks() public {
        vm.startPrank(alice);
        
        // Get current tick from pool
        ICLPool pool = ICLPool(USDC_WETH_POOL_005);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        // Calculate valid ticks around current price
        int24 tickLower = ((currentTick - 1000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 1000) / tickSpacing) * tickSpacing;
        
        // Create position
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            USDC_WETH_POOL_005,
            tickLower,
            tickUpper,
            block.timestamp + 300,
            1000e6, // 1000 USDC
            100 // 1% slippage
        );
        
        // Verify position was created
        assertTrue(tokenId > 0, "Token ID should be valid");
        assertTrue(liquidity > 0, "Liquidity should be minted");
        
        vm.stopPrank();
    }
    
    function testCreatePosition_InvalidTickAlignment() public {
        vm.startPrank(alice);
        
        ICLPool pool = ICLPool(USDC_WETH_POOL_005);
        int24 tickSpacing = pool.tickSpacing();
        
        // Use ticks that are NOT aligned to tick spacing
        int24 tickLower = -1000 + 1; // Not aligned
        int24 tickUpper = 1000;
        
        // Should revert with InvalidTickAlignment
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityManager.InvalidTickAlignment.selector,
                tickLower,
                tickSpacing
            )
        );
        
        liquidityManager.createPosition(
            USDC_WETH_POOL_005,
            tickLower,
            tickUpper,
            block.timestamp + 300,
            1000e6,
            100
        );
        
        vm.stopPrank();
    }
    
    function testCreatePosition_InvalidTickOrder() public {
        vm.startPrank(alice);
        
        ICLPool pool = ICLPool(USDC_WETH_POOL_005);
        int24 tickSpacing = pool.tickSpacing();
        
        // Use inverted ticks (upper < lower)
        int24 tickLower = ((1000 / tickSpacing) * tickSpacing);
        int24 tickUpper = ((-1000 / tickSpacing) * tickSpacing);
        
        // Should revert with InvalidTickRange
        vm.expectRevert(
            abi.encodeWithSelector(
                AtomicBase.InvalidTickRange.selector,
                tickLower,
                tickUpper
            )
        );
        
        liquidityManager.createPosition(
            USDC_WETH_POOL_005,
            tickLower,
            tickUpper,
            block.timestamp + 300,
            1000e6,
            100
        );
        
        vm.stopPrank();
    }
    
    function testCreatePosition_TickRangeTooNarrow() public {
        vm.startPrank(alice);
        
        ICLPool pool = ICLPool(USDC_WETH_POOL_03);
        int24 tickSpacing = pool.tickSpacing();
        
        // Use same tick for both (zero width range)
        int24 tick = ((0 / tickSpacing) * tickSpacing);
        
        // Should revert with TickRangeTooNarrow
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityManager.TickRangeTooNarrow.selector,
                tick,
                tick,
                tickSpacing
            )
        );
        
        liquidityManager.createPosition(
            USDC_WETH_POOL_03,
            tick,
            tick,
            block.timestamp + 300,
            1000e6,
            100
        );
        
        vm.stopPrank();
    }
    
    function testCreatePosition_ExtremeTickBounds() public {
        vm.startPrank(alice);
        
        ICLPool pool = ICLPool(USDC_WETH_POOL_005);
        int24 tickSpacing = pool.tickSpacing();
        
        // Use ticks at extreme bounds
        int24 MIN_TICK = -887272;
        int24 MAX_TICK = 887272;
        
        // Align to tick spacing
        int24 tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;
        
        // This should succeed (valid but extreme range)
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            USDC_WETH_POOL_005,
            tickLower,
            tickUpper,
            block.timestamp + 300,
            100e6, // Small amount due to extreme range
            500 // 5% slippage for extreme range
        );
        
        // Verify position was created
        assertTrue(tokenId > 0, "Token ID should be valid");
        
        vm.stopPrank();
    }
    
    function testCreatePosition_OutOfRangePosition() public {
        vm.startPrank(alice);
        
        // Get current tick from pool
        ICLPool pool = ICLPool(USDC_WETH_POOL_005);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        // Create position entirely below current price (100% token0)
        int24 tickLower = ((currentTick - 10000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick - 5000) / tickSpacing) * tickSpacing;
        
        // Should succeed but will be entirely in token0
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            USDC_WETH_POOL_005,
            tickLower,
            tickUpper,
            block.timestamp + 300,
            1000e6,
            100
        );
        
        assertTrue(tokenId > 0, "Token ID should be valid");
        
        // Now test position entirely above current price (100% token1)
        tickLower = ((currentTick + 5000) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + 10000) / tickSpacing) * tickSpacing;
        
        (tokenId, liquidity) = liquidityManager.createPosition(
            USDC_WETH_POOL_005,
            tickLower,
            tickUpper,
            block.timestamp + 300,
            1000e6,
            100
        );
        
        assertTrue(tokenId > 0, "Token ID should be valid");
        
        vm.stopPrank();
    }
    
    function testCreatePosition_VariousTickSpacings() public {
        vm.startPrank(alice);
        
        // Test with different tick spacing pools
        address[2] memory pools = [USDC_WETH_POOL_005, USDC_WETH_POOL_03];
        
        for (uint i = 0; i < pools.length; i++) {
            ICLPool pool = ICLPool(pools[i]);
            (, int24 currentTick,,,,) = pool.slot0();
            int24 tickSpacing = pool.tickSpacing();
            
            // Create properly aligned ticks
            int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
            int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
            
            (uint256 tokenId,) = liquidityManager.createPosition(
                pools[i],
                tickLower,
                tickUpper,
                block.timestamp + 300,
                100e6, // 100 USDC
                100
            );
            
            assertTrue(tokenId > 0, "Token ID should be valid for each pool");
        }
        
        vm.stopPrank();
    }
    
    // ============ Fuzz Testing ============
    
    function testFuzz_CreatePosition_ValidTicks(
        int24 tickOffset1,
        int24 tickOffset2,
        uint256 usdcAmount
    ) public {
        // Bound inputs
        tickOffset1 = int24(bound(int256(tickOffset1), -100000, 100000));
        tickOffset2 = int24(bound(int256(tickOffset2), -100000, 100000));
        usdcAmount = bound(usdcAmount, 10e6, 10000e6); // 10 to 10,000 USDC
        
        vm.startPrank(alice);
        
        ICLPool pool = ICLPool(USDC_WETH_POOL_005);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        // Calculate aligned ticks
        int24 rawLower = currentTick + tickOffset1;
        int24 rawUpper = currentTick + tickOffset2;
        
        // Ensure proper ordering
        if (rawLower > rawUpper) {
            (rawLower, rawUpper) = (rawUpper, rawLower);
        }
        
        // Align to tick spacing
        int24 tickLower = (rawLower / tickSpacing) * tickSpacing;
        int24 tickUpper = ((rawUpper / tickSpacing) + 1) * tickSpacing;
        
        // Ensure minimum width
        if (tickUpper <= tickLower) {
            tickUpper = tickLower + tickSpacing;
        }
        
        // Bound to valid tick range
        int24 MIN_TICK = -887272;
        int24 MAX_TICK = 887272;
        tickLower = tickLower < MIN_TICK ? (MIN_TICK / tickSpacing) * tickSpacing : tickLower;
        tickUpper = tickUpper > MAX_TICK ? (MAX_TICK / tickSpacing) * tickSpacing : tickUpper;
        
        // Create position
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            USDC_WETH_POOL_005,
            tickLower,
            tickUpper,
            block.timestamp + 300,
            usdcAmount,
            200 // 2% slippage for fuzz tests
        );
        
        // Verify invariants
        assertTrue(tokenId > 0, "Token ID should always be valid");
        assertTrue(liquidity >= 0, "Liquidity should be non-negative");
        
        vm.stopPrank();
    }
}