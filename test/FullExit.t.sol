// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AerodromeAtomicOperations.sol";
import "../contracts/CDPWalletRegistry.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ICLPool.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IGauge.sol";

/**
 * @title FullExitTest
 * @notice Tests for the fullExit function using the WETH/USDC pool on Base mainnet
 * @dev Tests the complete lifecycle: mint a position, stake it, then fully exit back to USDC
 */
contract FullExitTest is Test {
    AerodromeAtomicOperations public atomicOps;
    CDPWalletRegistry public registry;
    
    // Contract addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    
    // Test wallet
    address testWallet = address(0x1234);
    
    // Fork setup
    uint256 baseFork;
    
    // Position tracking
    uint256 positionTokenId;
    uint128 positionLiquidity;
    
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
        deal(USDC, testWallet, 10000 * 1e6); // 10,000 USDC
        
        // Approve atomic operations contract
        vm.startPrank(testWallet);
        IERC20(USDC).approve(address(atomicOps), type(uint256).max);
        vm.stopPrank();
        
        // Create a position for testing
        _createTestPosition();
    }
    
    function _createTestPosition() internal {
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
            usdcAmount: 1000 * 1e6, // 1000 USDC
            slippageBps: 100, // 1% slippage
            stake: true // Stake the position
        });
        
        // Execute swap, mint and stake
        (positionTokenId, positionLiquidity) = atomicOps.swapMintAndStake(params);
        
        vm.stopPrank();
    }
    
    function testFullExitStakedPosition() public {
        vm.startPrank(testWallet);
        
        // Record balances before exit
        uint256 usdcBefore = IERC20(USDC).balanceOf(testWallet);
        uint256 aeroBefore = IERC20(AERO).balanceOf(testWallet);
        
        // Prepare exit parameters
        AerodromeAtomicOperations.FullExitParams memory exitParams = AerodromeAtomicOperations.FullExitParams({
            tokenId: positionTokenId,
            deadline: block.timestamp + 3600,
            minUsdcOut: 900 * 1e6, // Expect at least 900 USDC back (10% slippage max)
            slippageBps: 200 // 2% slippage
        });
        
        // Execute full exit
        (uint256 usdcOut, uint256 aeroRewards) = atomicOps.fullExit(exitParams);
        
        // Assertions
        assertTrue(usdcOut > 0, "Should receive USDC");
        assertTrue(usdcOut >= exitParams.minUsdcOut, "Should meet minimum USDC requirement");
        
        // Check balances after exit
        uint256 usdcAfter = IERC20(USDC).balanceOf(testWallet);
        uint256 aeroAfter = IERC20(AERO).balanceOf(testWallet);
        
        assertEq(usdcAfter - usdcBefore, usdcOut, "USDC balance should increase by usdcOut");
        
        // May or may not have AERO rewards depending on time staked
        if (aeroRewards > 0) {
            assertTrue(aeroAfter > aeroBefore, "Should have received AERO rewards");
        }
        
        vm.stopPrank();
    }
    
    function testUnstakeAndBurn() public {
        vm.startPrank(testWallet);
        
        // Record balances before
        uint256 wethBefore = IERC20(WETH).balanceOf(testWallet);
        uint256 usdcBefore = IERC20(USDC).balanceOf(testWallet);
        
        // Execute unstake and burn (returns tokens without swapping to USDC)
        (uint256 amount0, uint256 amount1, uint256 aeroRewards) = atomicOps.unstakeAndBurn(
            positionTokenId,
            block.timestamp + 3600,
            100 // 1% slippage
        );
        
        // Check we received tokens
        assertTrue(amount0 > 0 || amount1 > 0, "Should receive at least one token");
        
        // Verify balance changes
        uint256 wethAfter = IERC20(WETH).balanceOf(testWallet);
        uint256 usdcAfter = IERC20(USDC).balanceOf(testWallet);
        
        // WETH is token0, USDC is token1 in this pool
        assertEq(wethAfter - wethBefore, amount0, "WETH balance should increase by amount0");
        assertEq(usdcAfter - usdcBefore, amount1, "USDC balance should increase by amount1");
        
        vm.stopPrank();
    }
    
    function testFullExitUnstakedPosition() public {
        // First create an unstaked position
        vm.startPrank(testWallet);
        
        // Get pool details
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        int24 tickSpacing = pool.tickSpacing();
        (, int24 currentTick, , , , ) = pool.slot0();
        
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        // Create position without staking
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 500 * 1e6,
            slippageBps: 100,
            stake: false // Don't stake
        });
        
        (uint256 unstakedTokenId, ) = atomicOps.swapAndMint(params);
        
        // Now exit the unstaked position
        AerodromeAtomicOperations.FullExitParams memory exitParams = AerodromeAtomicOperations.FullExitParams({
            tokenId: unstakedTokenId,
            deadline: block.timestamp + 3600,
            minUsdcOut: 450 * 1e6, // Expect at least 450 USDC back
            slippageBps: 100
        });
        
        (uint256 usdcOut, uint256 aeroRewards) = atomicOps.fullExit(exitParams);
        
        // Assertions
        assertTrue(usdcOut > 0, "Should receive USDC");
        assertTrue(usdcOut >= exitParams.minUsdcOut, "Should meet minimum USDC requirement");
        assertEq(aeroRewards, 0, "Unstaked position should have no AERO rewards");
        
        vm.stopPrank();
    }
    
    function testClaimAndSwapRewards() public {
        // Fast forward to accumulate some rewards
        vm.warp(block.timestamp + 7 days);
        
        vm.startPrank(testWallet);
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(testWallet);
        uint256 aeroBefore = IERC20(AERO).balanceOf(testWallet);
        
        // Claim rewards and swap to USDC
        (uint256 aeroAmount, uint256 usdcReceived) = atomicOps.claimAndSwap(
            positionTokenId,
            0 // Min USDC out - 0 means keep as AERO
        );
        
        if (aeroAmount > 0) {
            uint256 aeroAfter = IERC20(AERO).balanceOf(testWallet);
            assertEq(aeroAfter - aeroBefore, aeroAmount, "Should receive AERO rewards");
        }
        
        vm.stopPrank();
    }
    
    function testFullExitWithMinUsdcRequirement() public {
        vm.startPrank(testWallet);
        
        // Try to exit with very high minimum USDC requirement
        AerodromeAtomicOperations.FullExitParams memory exitParams = AerodromeAtomicOperations.FullExitParams({
            tokenId: positionTokenId,
            deadline: block.timestamp + 3600,
            minUsdcOut: 2000 * 1e6, // Impossible minimum (we only put in 1000)
            slippageBps: 100
        });
        
        // Should revert due to insufficient output
        vm.expectRevert("Insufficient USDC output");
        atomicOps.fullExit(exitParams);
        
        vm.stopPrank();
    }
    
    function testUnauthorizedFullExit() public {
        address unauthorizedUser = address(0x9999);
        
        vm.startPrank(unauthorizedUser);
        
        AerodromeAtomicOperations.FullExitParams memory exitParams = AerodromeAtomicOperations.FullExitParams({
            tokenId: positionTokenId,
            deadline: block.timestamp + 3600,
            minUsdcOut: 0,
            slippageBps: 100
        });
        
        // Should revert because user is not authorized
        vm.expectRevert("Unauthorized");
        atomicOps.fullExit(exitParams);
        
        vm.stopPrank();
    }
}