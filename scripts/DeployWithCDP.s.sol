// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../contracts/CDPWalletRegistry.sol";
import "../contracts/AerodromeAtomicOperations.sol";

/**
 * @title DeployWithCDP
 * @notice Deployment script for CDP-restricted atomic operations
 * @dev Deploys both CDPWalletRegistry and AerodromeAtomicOperations
 */
contract DeployWithCDP is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying contracts with deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy CDP Wallet Registry
        CDPWalletRegistry registry = new CDPWalletRegistry();
        console.log("CDP Wallet Registry deployed at:", address(registry));
        
        // Deploy Aerodrome Atomic Operations with registry
        AerodromeAtomicOperations atomicOps = new AerodromeAtomicOperations(address(registry));
        console.log("Aerodrome Atomic Operations deployed at:", address(atomicOps));
        
        // Optional: Register initial CDP wallets if provided
        string memory walletsEnv = vm.envOr("INITIAL_CDP_WALLETS", string(""));
        if (bytes(walletsEnv).length > 0) {
            // Parse comma-separated addresses and register them
            // Note: This is a simplified example, you'd need a proper parser
            console.log("Initial CDP wallets configuration found");
        }
        
        vm.stopBroadcast();
        
        console.log("\nDeployment complete!");
        console.log("Registry:", address(registry));
        console.log("Atomic Operations:", address(atomicOps));
        console.log("\nNext steps:");
        console.log("1. Register CDP wallets using registry.registerWallet()");
        console.log("2. Set additional operators if needed using registry.setOperator()");
    }
}