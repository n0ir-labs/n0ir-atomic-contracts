// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../contracts/N0irProtocol.sol";
import "../contracts/CDPWalletRegistry.sol";

/**
 * @title Deploy
 * @notice Deployment script for n0ir Protocol contracts
 * @dev Deploy with: forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_RPC_URL --broadcast --verify
 */
contract Deploy is Script {
    // Contract instances
    CDPWalletRegistry public registry;
    N0irProtocol public n0irProtocol;
    
    // Deployment configuration
    address public deployer;
    address public owner;
    
    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        // Get owner address from environment (defaults to deployer if not set)
        owner = vm.envOr("OWNER_ADDRESS", deployer);
        
        console.log("========================================");
        console.log("n0ir Protocol Deployment");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("Chain:", block.chainid);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy CDP Wallet Registry
        console.log("Deploying CDPWalletRegistry...");
        registry = new CDPWalletRegistry();
        console.log("CDPWalletRegistry deployed at:", address(registry));
        
        // Transfer ownership if needed
        if (owner != deployer) {
            registry.transferOwnership(owner);
            console.log("Ownership transferred to:", owner);
        }
        
        // Deploy n0ir Protocol
        console.log("Deploying n0ir Protocol...");
        n0irProtocol = new N0irProtocol(address(registry));
        console.log("n0ir Protocol deployed at:", address(n0irProtocol));
        
        // Register initial CDP wallets if provided
        _registerInitialWallets();
        
        vm.stopBroadcast();
        
        // Print deployment summary
        _printDeploymentSummary();
        
        // Export deployment addresses
        _exportDeployment();
    }
    
    /**
     * @notice Register initial CDP wallets from environment
     */
    function _registerInitialWallets() private {
        string memory walletsEnv = vm.envOr("CDP_WALLETS", string(""));
        if (bytes(walletsEnv).length == 0) {
            console.log("No initial CDP wallets to register");
            return;
        }
        
        console.log("");
        console.log("Registering initial CDP wallets...");
        
        // Parse comma-separated wallet addresses
        // Note: In production, you'd want a more robust parsing mechanism
        address[] memory wallets = _parseAddresses(walletsEnv);
        
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] != address(0)) {
                registry.registerWallet(wallets[i]);
                console.log("  Registered:", wallets[i]);
            }
        }
    }
    
    /**
     * @notice Parse comma-separated addresses from string
     * @dev Simple implementation - enhance for production use
     */
    function _parseAddresses(string memory input) private pure returns (address[] memory) {
        // This is a simplified version - in production, use a proper CSV parser
        // For now, we'll support up to 10 addresses
        address[] memory addresses = new address[](10);
        uint256 count = 0;
        
        // Placeholder: In a real implementation, parse the CSV string
        // For demonstration, we'll just return an empty array
        
        assembly {
            mstore(addresses, count)
        }
        
        return addresses;
    }
    
    /**
     * @notice Print deployment summary
     */
    function _printDeploymentSummary() private view {
        console.log("");
        console.log("========================================");
        console.log("Deployment Summary");
        console.log("========================================");
        console.log("CDPWalletRegistry:", address(registry));
        console.log("n0ir Protocol:", address(n0irProtocol));
        console.log("");
        console.log("Configuration:");
        console.log("  Registry Owner:", registry.owner());
        console.log("  Total Registered Wallets:", registry.totalWallets());
        console.log("");
        console.log("External Contracts:");
        console.log("  Universal Router:", address(n0irProtocol.UNIVERSAL_ROUTER()));
        console.log("  Position Manager:", address(n0irProtocol.POSITION_MANAGER()));
        console.log("  USDC:", n0irProtocol.USDC());
        console.log("  WETH:", n0irProtocol.WETH());
        console.log("========================================");
    }
    
    /**
     * @notice Export deployment addresses to JSON file
     */
    function _exportDeployment() private {
        string memory json = "deployment";
        
        vm.serializeAddress(json, "CDPWalletRegistry", address(registry));
        vm.serializeAddress(json, "N0irProtocol", address(n0irProtocol));
        vm.serializeAddress(json, "owner", owner);
        vm.serializeUint(json, "chainId", block.chainid);
        string memory timestamp = vm.toString(block.timestamp);
        string memory output = vm.serializeString(json, "timestamp", timestamp);
        
        // Write to deployments directory
        string memory filename = string.concat(
            "deployments/",
            vm.toString(block.chainid),
            "-latest.json"
        );
        
        vm.writeJson(output, filename);
        console.log("");
        console.log("Deployment exported to:", filename);
    }
}