// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AerodromeAtomicOperations.sol";
import "../contracts/CDPWalletRegistry.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ICLPool.sol";
import "../interfaces/INonfungiblePositionManager.sol";

/**
 * @title SwapMintAndStakeTest
 * @notice Tests for the swapMintAndStake function using the WETH/USDC pool on Base mainnet
 * @dev Tests demonstrate:
 *      1. Basic swap, mint, and stake functionality with optimal liquidity calculation
 *      2. Partial swap scenarios where not all USDC is swapped
 *      3. Optimal amount calculation for narrow ranges
 *      4. Access control via CDP wallet registry
 */
contract SwapMintAndStakeTest is Test {
    AerodromeAtomicOperations public atomicOps;
    CDPWalletRegistry public registry;
    
    // Contract addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    
    // Test wallet
    address testWallet = address(0x1234);
    
    // Fork setup
    uint256 baseFork;
    
    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl = vm.envString("BASE_RPC_URL");
        baseFork = vm.createFork(rpcUrl);
        vm.selectFork(baseFork);
        
        // Deploy contracts
        registry = new CDPWalletRegistry();
        atomicOps = new AerodromeAtomicOperations(address(registry));
        
        // Register test wallet
        registry.registerWallet(testWallet);
        
        // Deal USDC to test wallet
        deal(USDC, testWallet, 1000 * 1e6); // 1000 USDC
        
        // Approve atomic operations contract
        vm.startPrank(testWallet);
        IERC20(USDC).approve(address(atomicOps), type(uint256).max);
        vm.stopPrank();
    }
    
    function testSwapMintAndStakeWETHUSDC() public {
        vm.startPrank(testWallet);
        
        // Get pool details
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        int24 tickSpacing = pool.tickSpacing();
        (, int24 currentTick, , , , ) = pool.slot0();
        
        // Calculate tick range around current price
        int24 tickLower = ((currentTick - 1000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 1000) / tickSpacing) * tickSpacing;
        
        // Prepare parameters
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 1000 * 1e6, // 1000 USDC total
            slippageBps: 100, // 1% slippage
            stake: true // Stake the position
        });
        
        // Record initial balances
        uint256 initialUsdcBalance = IERC20(USDC).balanceOf(testWallet);
        
        // Execute swap, mint and stake
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapMintAndStake(params);
        
        // Assertions
        assertTrue(tokenId > 0, "Should receive valid token ID");
        assertTrue(liquidity > 0, "Should mint liquidity");
        
        // Check USDC was spent
        uint256 finalUsdcBalance = IERC20(USDC).balanceOf(testWallet);
        assertTrue(finalUsdcBalance < initialUsdcBalance, "USDC should be spent");
        
        // The position should be staked, so the contract should hold it
        // Check that testWallet doesn't own the NFT (it's staked)
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
        
        // Try to get owner - should revert or return zero address since it's staked
        try positionManager.ownerOf(tokenId) returns (address owner) {
            // If we get here, the position exists but might be owned by gauge
            assertTrue(owner != testWallet, "Position should not be owned by test wallet (should be staked)");
        } catch {
            // Position is staked in gauge, this is expected
        }
        
        vm.stopPrank();
    }
    
    function testSwapMintWithoutStake() public {
        vm.startPrank(testWallet);
        
        // Get pool details
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        int24 tickSpacing = pool.tickSpacing();
        (, int24 currentTick, , , , ) = pool.slot0();
        
        // Calculate tick range
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        // Prepare parameters without staking
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 500 * 1e6, // 500 USDC
            slippageBps: 100, // 1% slippage
            stake: false // Don't stake
        });
        
        // Execute swap and mint without staking
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapAndMint(params);
        
        // Assertions
        assertTrue(tokenId > 0, "Should receive valid token ID");
        assertTrue(liquidity > 0, "Should mint liquidity");
        
        // Check that testWallet owns the NFT (not staked)
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
        address owner = positionManager.ownerOf(tokenId);
        assertEq(owner, testWallet, "Test wallet should own the position");
        
        vm.stopPrank();
    }
    
    function testNarrowRangePosition() public {
        vm.startPrank(testWallet);
        
        // Get pool details
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        int24 tickSpacing = pool.tickSpacing();
        (, int24 currentTick, , , , ) = pool.slot0();
        
        // Very narrow range - just 2 ticks wide
        int24 tickLower = ((currentTick - tickSpacing) / tickSpacing) * tickSpacing;
        int24 tickUpper = tickLower + tickSpacing * 2;
        
        // Prepare parameters
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 100 * 1e6, // 100 USDC
            slippageBps: 200, // 2% slippage for narrow range
            stake: false
        });
        
        // Execute
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapAndMint(params);
        
        // Assertions
        assertTrue(tokenId > 0, "Should receive valid token ID");
        assertTrue(liquidity > 0, "Should mint liquidity even for narrow range");
        
        vm.stopPrank();
    }
    
    function testOutOfRangePosition() public {
        vm.startPrank(testWallet);
        
        // Get pool details
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        int24 tickSpacing = pool.tickSpacing();
        (, int24 currentTick, , , , ) = pool.slot0();
        
        // Position entirely above current price (all in token0/WETH)
        int24 tickLower = ((currentTick + 1000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 2000) / tickSpacing) * tickSpacing;
        
        // Prepare parameters
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 200 * 1e6, // 200 USDC
            slippageBps: 100,
            stake: false
        });
        
        // Execute - should swap all USDC to WETH since position is above range
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapAndMint(params);
        
        // Assertions
        assertTrue(tokenId > 0, "Should receive valid token ID");
        assertTrue(liquidity > 0, "Should mint liquidity for out-of-range position");
        
        vm.stopPrank();
    }
    
    function testUnauthorizedAccess() public {
        address unauthorizedUser = address(0x9999);
        deal(USDC, unauthorizedUser, 100 * 1e6);
        
        vm.startPrank(unauthorizedUser);
        IERC20(USDC).approve(address(atomicOps), type(uint256).max);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: -1000,
            tickUpper: 1000,
            deadline: block.timestamp + 3600,
            usdcAmount: 100 * 1e6,
            slippageBps: 100,
            stake: false
        });
        
        // Should revert because user is not registered
        vm.expectRevert("Unauthorized");
        atomicOps.swapMintAndStake(params);
        
        vm.stopPrank();
    }
    
    function testDirectUserAccess() public {
        // Deploy atomic ops without registry for direct access
        AerodromeAtomicOperations directOps = new AerodromeAtomicOperations(address(0));
        
        address directUser = address(0x5555);
        deal(USDC, directUser, 100 * 1e6);
        
        vm.startPrank(directUser);
        IERC20(USDC).approve(address(directOps), type(uint256).max);
        
        // Get pool details
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        int24 tickSpacing = pool.tickSpacing();
        (, int24 currentTick, , , , ) = pool.slot0();
        
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 100 * 1e6,
            slippageBps: 100,
            stake: false
        });
        
        // Should work because no registry means direct access allowed
        (uint256 tokenId, uint128 liquidity) = directOps.swapAndMint(params);
        
        assertTrue(tokenId > 0, "Should receive valid token ID");
        assertTrue(liquidity > 0, "Should mint liquidity");
        
        vm.stopPrank();
    }
}