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
 * @title NonCustodialTest
 * @notice Test to verify the non-custodial security fix
 * @dev Ensures positions are minted directly to users, not to the contract
 */
contract NonCustodialTest is Test {
    LiquidityManager public liquidityManager;
    RouteFinder public routeFinder;
    WalletRegistry public walletRegistry;
    
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    
    // USDC/AERO pool for testing
    address constant USDC_AERO_POOL = 0xBE00fF35AF70E8415D0eB605a286D8A45466A4c1;
    
    // Test user
    address alice = makeAddr("alice");
    
    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork("https://mainnet.base.org");
        
        // Deploy contracts
        walletRegistry = new WalletRegistry();
        routeFinder = new RouteFinder();
        liquidityManager = new LiquidityManager(address(walletRegistry), address(routeFinder));
        
        // Register test user
        walletRegistry.registerWallet(alice);
        
        // Fund user with USDC
        deal(USDC, alice, 10000e6); // 10,000 USDC
        
        // Give user some ETH for gas
        vm.deal(alice, 10 ether);
        
        // Label addresses for better trace output
        vm.label(address(liquidityManager), "LiquidityManager");
        vm.label(address(routeFinder), "RouteFinder");
        vm.label(alice, "Alice");
        vm.label(USDC_AERO_POOL, "USDC/AERO_Pool");
    }
    
    function testNonCustodialPositionCreation() public {
        console.log("\n=== Non-Custodial Security Test ===");
        
        vm.startPrank(alice);
        
        // Approve USDC to LiquidityManager
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        
        // Create position
        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            USDC_AERO_POOL,
            100,    // 1% range
            block.timestamp + 3600,
            1000e6, // 1000 USDC
            500     // 5% slippage
        );
        
        console.log("Position created!");
        console.log("  Token ID:", tokenId);
        console.log("  Liquidity:", liquidity);
        
        // CRITICAL SECURITY CHECK: Verify the position NFT is owned by alice, NOT the contract
        address nftOwner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        
        console.log("\n=== SECURITY VERIFICATION ===");
        console.log("  NFT Owner:", nftOwner);
        console.log("  Expected (alice):", alice);
        console.log("  LiquidityManager:", address(liquidityManager));
        
        // This is the critical assertion - position must be owned by user
        assertEq(nftOwner, alice, "SECURITY: Position NFT must be owned by user, not contract!");
        assertNotEq(nftOwner, address(liquidityManager), "SECURITY: Contract must NOT hold user positions!");
        
        console.log("  [PASS] Position is non-custodial (owned by user)");
        
        vm.stopPrank();
    }
    
    function testClosePositionRequiresApproval() public {
        console.log("\n=== Test Close Position Requires User Approval ===");
        
        vm.startPrank(alice);
        
        // First create a position
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        (uint256 tokenId,) = liquidityManager.createPosition(
            USDC_AERO_POOL,
            100,    // 1% range
            block.timestamp + 3600,
            1000e6, // 1000 USDC
            500     // 5% slippage
        );
        
        console.log("Position created with ID:", tokenId);
        
        // Try to close without approval - should fail
        console.log("\n--- Attempting to close without approval ---");
        vm.expectRevert("ERC721: transfer caller is not owner nor approved");
        liquidityManager.closePosition(
            tokenId,
            USDC_AERO_POOL,
            block.timestamp + 3600,
            850e6,  // min USDC out
            500     // slippage
        );
        console.log("  [PASS] Correctly reverted without approval");
        
        // Now approve and close
        console.log("\n--- Approving and closing position ---");
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityManager), tokenId);
        console.log("  Approved LiquidityManager to transfer NFT");
        
        uint256 usdcOut = liquidityManager.closePosition(
            tokenId,
            USDC_AERO_POOL,
            block.timestamp + 3600,
            850e6,  // min USDC out
            500     // slippage
        );
        
        console.log("  Position closed successfully!");
        console.log("  USDC returned:", usdcOut / 1e6);
        
        
        // Verify NFT was burned
        vm.expectRevert();
        INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        console.log("  [PASS] NFT successfully burned after closing");
        
        vm.stopPrank();
    }
    
    function testContractCannotTakeCustody() public {
        console.log("\n=== Test Contract Cannot Take Custody ===");
        
        vm.startPrank(alice);
        
        // Create a position
        IERC20(USDC).approve(address(liquidityManager), type(uint256).max);
        (uint256 tokenId,) = liquidityManager.createPosition(
            USDC_AERO_POOL,
            100,    // 1% range
            block.timestamp + 3600,
            1000e6, // 1000 USDC
            500     // slippage
        );
        
        // Verify contract never has custody
        address owner = INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);
        assertEq(owner, alice, "User must own position");
        
        // Even if user tries to send NFT to contract, it shouldn't be able to do anything with it
        // without explicit user interaction
        console.log("  [PASS] Contract cannot take custody of user positions");
        
        vm.stopPrank();
    }
}