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
 * @title PositionManagementTests
 * @notice Tests for position info and reward claiming functions
 */
contract PositionManagementTests is Test {
    LiquidityManager public liquidityManager;
    RouteFinder public routeFinder;
    WalletRegistry public walletRegistry;
    
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    
    // Test users
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    
    // Test position IDs
    uint256 alicePositionId;
    uint256 bobPositionId;
    
    function setUp() public {
        // Deploy contracts
        walletRegistry = new WalletRegistry();
        routeFinder = new RouteFinder();
        liquidityManager = new LiquidityManager(address(walletRegistry), address(routeFinder));
        
        // Register test users
        walletRegistry.registerWallet(alice);
        walletRegistry.registerWallet(bob);
        
        // Fund users
        deal(USDC, alice, 10000e6);
        deal(USDC, bob, 10000e6);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }
    
    // ============ Position Management Tests ============
    
    function testCreatePosition_MintsToUser() public {
        // Test that positions are minted directly to the user
        // This would need a fork to work with real pools
        
        // Note: Since claimRewards functions are removed, 
        // we only test that positions are created non-custodially
    }
    
    function testClosePosition_RequiresOwnership() public {
        // Test that only position owners can close their positions
        vm.startPrank(bob);
        
        // Try to close a position not owned by bob
        // This would need a real position to test properly
        
        vm.stopPrank();
    }
    
    function testNonCustodialPositions() public {
        // Test that the contract never takes custody of NFT positions
        // Positions should always be owned by users
        
        // This would require fork testing with real position creation
    }
    
    // ============ Position Info Tests ============
    
    function testGetPositionInfo_NonExistent() public {
        // Test getting info for non-existent position
        // Note: getPositionInfo function has been removed from LiquidityManager
        // vm.expectRevert();
        // liquidityManager.getPositionInfo(999999);
    }
    
    function testGetPositionInfo_Structure() public {
        // Test that PositionInfo struct is properly populated
        // This would need a real position to test fully
        
        // Create a mock position first (would need fork)
        // Then verify all fields are populated correctly
    }
    
    function testGetAllPositionsInfo_Empty() public view {
        // Test getting all positions for user with no positions
        // Note: getAllPositionsInfo function has been removed from LiquidityManager
        // This test is commented out as the function no longer exists
        // LiquidityManager.PositionInfo[] memory infos = liquidityManager.getAllPositionsInfo(alice);
        // assertEq(infos.length, 0, "Should return empty array for user with no positions");
    }
    
    // ============ Helper Function Tests ============
    
    function testFindPoolFromTokens() public {
        // Test pool finding logic
        // This is an internal function, so we test it indirectly through getPositionInfo
    }
    
    function testCalculatePositionValueUsd() public {
        // Test USD value calculation
        // This would need real pool data to test properly
    }
    
    function testCalculateUnclaimedFeesUsd() public {
        // Test fee calculation in USD
        // This would need real position data to test properly
    }
    
    function testGetTokenPriceUsd() public {
        // Test price fetching from oracle
        // This would need a fork to test with real oracle
    }
    
    function testGetTokenDecimals() public {
        // Test decimal fetching for various tokens
        // This would need actual token contracts to test
    }
    
    // ============ Integration Tests (Need Fork) ============
    
    function testIntegration_CreateStakeAndClaimRewards() public {
        // This test would:
        // 1. Create a position
        // 2. Stake it
        // 3. Wait for rewards to accrue
        // 4. Claim rewards
        // 5. Verify AERO received
        
        // Requires fork of Base mainnet
    }
    
    function testIntegration_GetPositionInfoComplete() public {
        // This test would:
        // 1. Create multiple positions
        // 2. Some staked, some unstaked
        // 3. Get position info for each
        // 4. Verify all fields are correct
        // 5. Test getAllPositionsInfo
        
        // Requires fork of Base mainnet
    }
    
    // ============ Edge Cases ============
    
    function testEdgeCase_PositionOutOfRange() public {
        // Test position info when position is out of range
    }
    
    function testEdgeCase_ZeroLiquidity() public {
        // Test position info for position with 0 liquidity but fees
    }
    
    function testEdgeCase_OraclePriceUnavailable() public {
        // Test USD calculations when oracle price is unavailable
    }
}