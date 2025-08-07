// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LiquidityManager} from "../contracts/LiquidityManager.sol";
import {WalletRegistry} from "../contracts/WalletRegistry.sol";

/**
 * @title Deploy
 * @notice Deployment script for LiquidityManager and WalletRegistry contracts
 * @dev Deploy with: forge script scripts/Deploy.s.sol:Deploy --rpc-url $BASE_RPC_URL --broadcast --verify
 */
contract Deploy is Script {
    // ============ Deployment Configuration ============
    
    // Set to true if you want to deploy with a WalletRegistry
    // Set to false for permissionless deployment (anyone can use)
    bool constant USE_WALLET_REGISTRY = true;
    
    // Initial authorized wallets (only used if USE_WALLET_REGISTRY is true)
    address[] initialWallets;
    
    // Initial operators (only used if USE_WALLET_REGISTRY is true)
    address[] initialOperators;
    
    function setUp() public {
        // Add initial authorized wallets here if using WalletRegistry
        if (USE_WALLET_REGISTRY) {
            // Example: initialWallets.push(0x...);
            // Example: initialOperators.push(0x...);
        }
    }
    
    function run() public returns (address liquidityManager, address walletRegistry) {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("========================================");
        console.log("Deploying contracts on Base");
        console.log("Deployer:", deployer);
        console.log("========================================");
        
        vm.startBroadcast(deployerPrivateKey);
        
        if (USE_WALLET_REGISTRY) {
            // Deploy WalletRegistry first
            walletRegistry = address(new WalletRegistry());
            console.log("WalletRegistry deployed at:", walletRegistry);
            
            // Add initial operators if any (must be done before adding wallets)
            if (initialOperators.length > 0) {
                WalletRegistry(walletRegistry).setOperatorsBatch(initialOperators, true);
                console.log("Added", initialOperators.length, "operators");
            }
            
            // Add initial wallets if any (requires operator privileges)
            if (initialWallets.length > 0) {
                WalletRegistry(walletRegistry).registerWalletsBatch(initialWallets);
                console.log("Added", initialWallets.length, "authorized wallets");
            }
            
            // Deploy LiquidityManager with WalletRegistry
            liquidityManager = address(new LiquidityManager(walletRegistry));
            console.log("LiquidityManager deployed at:", liquidityManager);
            console.log("Access control: ENABLED via WalletRegistry");
        } else {
            // Deploy LiquidityManager without access control (permissionless)
            liquidityManager = address(new LiquidityManager(address(0)));
            console.log("LiquidityManager deployed at:", liquidityManager);
            console.log("Access control: DISABLED (permissionless)");
            walletRegistry = address(0);
        }
        
        vm.stopBroadcast();
        
        console.log("========================================");
        console.log("Deployment complete!");
        console.log("========================================");
        
        // Print deployment summary
        _printDeploymentSummary(liquidityManager, walletRegistry);
        
        return (liquidityManager, walletRegistry);
    }
    
    function _printDeploymentSummary(address liquidityManager, address walletRegistry) internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("LiquidityManager:", liquidityManager);
        
        if (walletRegistry != address(0)) {
            console.log("WalletRegistry:", walletRegistry);
            console.log("Registry Owner:", WalletRegistry(walletRegistry).owner());
        } else {
            console.log("WalletRegistry: Not deployed (permissionless mode)");
        }
        
        console.log("\n=== PROTOCOL ADDRESSES ===");
        console.log("Universal Router: 0x01D40099fCD87C018969B0e8D4aB1633Fb34763C");
        console.log("Swap Router: 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5");
        console.log("Position Manager: 0x827922686190790b37229fd06084350E74485b72");
        console.log("Quoter: 0x254cF9E1E6e233aa1AC962CB9B05b2cfeAaE15b0");
        console.log("Sugar Helper: 0x0AD09A66af0154a84e86F761313d02d0abB6edd5");
        console.log("Oracle: 0x43B36A7E6a4cdFe7de5Bd2Aa1FCcddf6a366dAA2");
        
        console.log("\n=== TOKEN ADDRESSES ===");
        console.log("USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
        console.log("WETH: 0x4200000000000000000000000000000000000006");
        console.log("AERO: 0x940181a94A35A4569E4529A3CDfB74e38FD98631");
        
        console.log("\n=== NEXT STEPS ===");
        if (walletRegistry != address(0)) {
            console.log("1. Set operators: cast send", walletRegistry, "setOperator(address,bool) <operator> true");
            console.log("2. Register wallets: cast send", walletRegistry, "registerWallet(address) <wallet>");
            console.log("3. Transfer ownership if needed: cast send", walletRegistry, "transferOwnership(address) <newOwner>");
        } else {
            console.log("1. Contract is ready to use (no access control)");
        }
        console.log("2. Approve USDC: cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 approve(address,uint256)", liquidityManager, "<amount>");
        console.log("3. Create positions via LiquidityManager.createPosition()");
    }
}