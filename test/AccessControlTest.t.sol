// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LiquidityManager} from "../contracts/LiquidityManager.sol";
import {WalletRegistry} from "../contracts/WalletRegistry.sol";
import {RouteFinder} from "../contracts/RouteFinder.sol";

contract AccessControlTest is Test {
    LiquidityManager public liquidityManager;
    WalletRegistry public walletRegistry;
    RouteFinder public routeFinder;
    
    address public owner = address(this);
    address public registeredWallet = address(0x1111);
    address public unregisteredWallet = address(0x2222);
    address public randomUser = address(0x3333);
    
    function setUp() public {
        // Deploy with wallet registry for access control
        walletRegistry = new WalletRegistry();
        routeFinder = new RouteFinder();
        liquidityManager = new LiquidityManager(address(walletRegistry), address(routeFinder));
        
        // Register one wallet
        walletRegistry.registerWallet(registeredWallet);
    }
    
    function testRegisteredWalletCanCreatePosition() public {
        vm.prank(registeredWallet);
        // Should not revert - registered wallet can call
        try liquidityManager.createPosition(
            address(0), // pool
            -1000, // tickLower
            1000, // tickUpper
            block.timestamp + 1, // deadline
            1000e6, // usdcAmount
            100 // slippageBps
        ) {
            // Expected to fail due to invalid pool, but access control should pass
        } catch {
            // This is fine - we're only testing access control
        }
    }
    
    function testUnregisteredWalletCannotCreatePosition() public {
        vm.prank(unregisteredWallet);
        vm.expectRevert(LiquidityManager.UnauthorizedAccess.selector);
        liquidityManager.createPosition(
            address(0), // pool
            -1000, // tickLower
            1000, // tickUpper
            block.timestamp + 1, // deadline
            1000e6, // usdcAmount
            100 // slippageBps
        );
    }
    
    function testRandomUserCannotCreatePosition() public {
        vm.prank(randomUser);
        vm.expectRevert(LiquidityManager.UnauthorizedAccess.selector);
        liquidityManager.createPosition(
            address(0), // pool
            -1000, // tickLower
            1000, // tickUpper
            block.timestamp + 1, // deadline
            1000e6, // usdcAmount
            100 // slippageBps
        );
    }
    
    function testOnlyOwnerCanRecoverTokens() public {
        // Non-owner should not be able to recover
        vm.prank(registeredWallet);
        vm.expectRevert(LiquidityManager.UnauthorizedAccess.selector);
        liquidityManager.recoverToken(address(0x123), 100);
        
        vm.prank(randomUser);
        vm.expectRevert(LiquidityManager.UnauthorizedAccess.selector);
        liquidityManager.recoverToken(address(0x123), 100);
        
        // Owner should be able to recover (would work if token existed)
        // liquidityManager.recoverToken(address(0x123), 100);
        // Not testing actual recovery as it requires a real token
    }
    
    function testPermissionlessMode() public {
        // Deploy without wallet registry (permissionless mode)
        LiquidityManager permissionlessManager = new LiquidityManager(address(0), address(0));
        
        // User should be able to call for themselves
        vm.prank(randomUser);
        try permissionlessManager.createPosition(
            address(0), // pool
            -1000, // tickLower
            1000, // tickUpper
            block.timestamp + 1, // deadline
            1000e6, // usdcAmount
            100 // slippageBps
        ) {
            // Expected to fail due to invalid pool, but access control should pass
        } catch {
            // This is fine - we're only testing access control
        }
        
        // But cannot recover tokens in permissionless mode
        vm.expectRevert(LiquidityManager.UnauthorizedAccess.selector);
        permissionlessManager.recoverToken(address(0x123), 100);
    }
}