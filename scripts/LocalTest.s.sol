// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../contracts/N0irProtocol.sol";
import "../contracts/CDPWalletRegistry.sol";
import "@interfaces/IERC20.sol";

/**
 * @title LocalTest
 * @notice Deployment and testing script for local Anvil fork
 * @dev Use this for local testing with forked Base mainnet
 */
contract LocalTest is Script {
    // Contracts
    CDPWalletRegistry public registry;
    N0irProtocol public n0irProtocol;
    
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    // Test wallets (Anvil default accounts)
    address constant TEST_WALLET_1 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant TEST_WALLET_2 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant TEST_WALLET_3 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    
    function run() external {
        console.log("\n========================================");
        console.log("n0ir Protocol - Local Fork Deployment");
        console.log("========================================\n");
        
        // Use first Anvil account as deployer
        vm.startBroadcast(TEST_WALLET_1);
        
        // Deploy contracts
        _deployContracts();
        
        // Setup test environment
        _setupTestEnvironment();
        
        // Fund test wallets
        _fundTestWallets();
        
        // Run test transactions
        _runTestTransactions();
        
        vm.stopBroadcast();
        
        console.log("\n========================================");
        console.log("Local deployment complete!");
        console.log("========================================\n");
    }
    
    function _deployContracts() private {
        console.log("Deploying contracts...");
        
        // Deploy CDPWalletRegistry (will be owned by msg.sender = TEST_WALLET_1)
        registry = new CDPWalletRegistry();
        console.log("  CDPWalletRegistry:", address(registry));
        
        // Deploy n0ir Protocol
        n0irProtocol = new N0irProtocol(address(registry));
        console.log("  n0ir Protocol:", address(n0irProtocol));
        
        console.log("");
    }
    
    function _setupTestEnvironment() private {
        console.log("Setting up test environment...");
        
        // Register test wallets
        registry.registerWallet(TEST_WALLET_1);
        registry.registerWallet(TEST_WALLET_2);
        registry.registerWallet(TEST_WALLET_3);
        console.log("  Registered 3 test wallets");
        
        console.log("");
    }
    
    function _fundTestWallets() private {
        console.log("Funding test wallets with USDC...");
        
        vm.stopBroadcast();
        
        // Fund each test wallet with 10,000 USDC
        uint256 fundAmount = 10_000 * 1e6; // 10,000 USDC (6 decimals)
        
        // Find a real USDC whale on Base
        address usdcWhale = 0x20FE51A9229EEf2cF8Ad9E89d91CAb9312cF3b7A; // Large USDC holder
        
        // Impersonate the whale and transfer USDC
        vm.startPrank(usdcWhale);
        
        // Check whale balance first
        uint256 whaleBalance = IERC20(USDC).balanceOf(usdcWhale);
        console.log("  Whale USDC balance:", whaleBalance / 1e6);
        
        if (whaleBalance >= fundAmount * 3) {
            IERC20(USDC).transfer(TEST_WALLET_1, fundAmount);
            IERC20(USDC).transfer(TEST_WALLET_2, fundAmount);
            IERC20(USDC).transfer(TEST_WALLET_3, fundAmount);
            console.log("  Funded each wallet with 10,000 USDC");
        } else {
            console.log("  Warning: Whale doesn't have enough USDC, using storage manipulation");
            // Fallback: directly manipulate storage (USDC uses slot 9 for balances)
            vm.store(USDC, keccak256(abi.encode(TEST_WALLET_1, uint256(9))), bytes32(fundAmount));
            vm.store(USDC, keccak256(abi.encode(TEST_WALLET_2, uint256(9))), bytes32(fundAmount));
            vm.store(USDC, keccak256(abi.encode(TEST_WALLET_3, uint256(9))), bytes32(fundAmount));
        }
        
        vm.stopPrank();
        vm.startBroadcast(TEST_WALLET_1);
        
        // Check balances
        uint256 balance1 = IERC20(USDC).balanceOf(TEST_WALLET_1);
        uint256 balance2 = IERC20(USDC).balanceOf(TEST_WALLET_2);
        uint256 balance3 = IERC20(USDC).balanceOf(TEST_WALLET_3);
        
        console.log("  Wallet 1 USDC:", balance1 / 1e6);
        console.log("  Wallet 2 USDC:", balance2 / 1e6);
        console.log("  Wallet 3 USDC:", balance3 / 1e6);
        
        console.log("");
    }
    
    function _runTestTransactions() private {
        console.log("Running test transactions...");
        
        // Approve n0ir Protocol to spend USDC
        IERC20(USDC).approve(address(n0irProtocol), type(uint256).max);
        console.log("  Approved n0ir Protocol for USDC");
        
        // Get a sample pool (WETH/USDC)
        address wethUsdcPool = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
        
        console.log("\nTest Setup Complete!");
        console.log("You can now interact with:");
        console.log("  n0ir Protocol:", address(n0irProtocol));
        console.log("  Registry:", address(registry));
        console.log("\nExample test command:");
        console.log("  cast call", address(n0irProtocol), "\"USDC()\" --rpc-url http://localhost:8545");
        
        console.log("");
    }
}