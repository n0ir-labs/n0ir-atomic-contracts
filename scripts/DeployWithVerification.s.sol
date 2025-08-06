// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../contracts/N0irProtocol.sol";
import "../contracts/CDPWalletRegistry.sol";

/**
 * @title DeployWithVerification
 * @notice Enhanced deployment script with contract verification and advanced configuration
 * @dev Deploy with: forge script script/DeployWithVerification.s.sol:DeployWithVerification --rpc-url $BASE_RPC_URL --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
 */
contract DeployWithVerification is Script {
    // Contract instances
    CDPWalletRegistry public registry;
    N0irProtocol public n0irProtocol;
    
    // Configuration
    struct DeploymentConfig {
        address owner;
        address[] initialWallets;
        bool skipVerification;
        string verifierUrl;
    }
    
    DeploymentConfig public config;
    
    function run() external {
        // Load configuration
        _loadConfiguration();
        
        // Print deployment banner
        _printBanner();
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy contracts
        _deployContracts();
        
        // Configure contracts
        _configureContracts();
        
        vm.stopBroadcast();
        
        // Verify contracts if not skipped
        if (!config.skipVerification) {
            _verifyContracts();
        }
        
        // Print summary and export
        _printSummary();
        _exportDeployment();
    }
    
    /**
     * @notice Load deployment configuration from environment
     */
    function _loadConfiguration() private {
        config.owner = vm.envOr("OWNER_ADDRESS", msg.sender);
        config.skipVerification = vm.envOr("SKIP_VERIFICATION", false);
        config.verifierUrl = vm.envOr("VERIFIER_URL", string("https://api.basescan.org/api"));
        
        // Load initial wallets
        string memory walletsJson = vm.envOr("CDP_WALLETS_JSON", string("[]"));
        if (bytes(walletsJson).length > 2) {
            // Parse JSON array of addresses (simplified)
            // In production, use proper JSON parsing
            config.initialWallets = new address[](0);
        }
    }
    
    /**
     * @notice Print deployment banner
     */
    function _printBanner() private view {
        console.log("");
        console.log("    \u2588\u2588\u2588\u2557   \u2588\u2588\u2557 \u2588\u2588\u2588\u2588\u2588\u2588\u2557 \u2588\u2588\u2557\u2588\u2588\u2588\u2588\u2588\u2588\u2557");
        console.log("    \u2588\u2588\u2588\u2588\u2557  \u2588\u2588\u2551\u2588\u2588\u2554\u2550\u2588\u2588\u2588\u2588\u2557\u2588\u2588\u2551\u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557");
        console.log("    \u2588\u2588\u2554\u2588\u2588\u2557 \u2588\u2588\u2551\u2588\u2588\u2551\u2588\u2588\u2554\u2588\u2588\u2551\u2588\u2588\u2551\u2588\u2588\u2588\u2588\u2588\u2588\u2554\u255d");
        console.log("    \u2588\u2588\u2551\u255a\u2588\u2588\u2557\u2588\u2588\u2551\u2588\u2588\u2588\u2588\u2554\u255d\u2588\u2588\u2551\u2588\u2588\u2551\u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557");
        console.log("    \u2588\u2588\u2551 \u255a\u2588\u2588\u2588\u2588\u2551\u255a\u2588\u2588\u2588\u2588\u2588\u2588\u2554\u255d\u2588\u2588\u2551\u2588\u2588\u2551  \u2588\u2588\u2551");
        console.log("    \u255a\u2550\u255d  \u255a\u2550\u2550\u2550\u255d \u255a\u2550\u2550\u2550\u2550\u2550\u255d \u255a\u2550\u255d\u255a\u2550\u255d  \u255a\u2550\u255d");
        console.log("    PROTOCOL DEPLOYMENT");
        console.log("");
        console.log("========================================");
        console.log("Deployer:", msg.sender);
        console.log("Owner:", config.owner);
        console.log("Chain ID:", block.chainid);
        console.log("Block:", block.number);
        console.log("========================================");
        console.log("");
    }
    
    /**
     * @notice Deploy all contracts
     */
    function _deployContracts() private {
        console.log("[1/2] Deploying CDPWalletRegistry...");
        registry = new CDPWalletRegistry();
        console.log("      \u2713 Deployed at:", address(registry));
        
        // Transfer ownership if needed
        if (config.owner != msg.sender) {
            registry.transferOwnership(config.owner);
            console.log("      \u2713 Ownership transferred to:", config.owner);
        }
        
        console.log("[2/2] Deploying n0ir Protocol...");
        n0irProtocol = new N0irProtocol(address(registry));
        console.log("      \u2713 Deployed at:", address(n0irProtocol));
        console.log("");
    }
    
    /**
     * @notice Configure deployed contracts
     */
    function _configureContracts() private {
        console.log("Configuring contracts...");
        
        // Register initial wallets
        if (config.initialWallets.length > 0) {
            console.log("  Registering", config.initialWallets.length, "CDP wallets...");
            for (uint256 i = 0; i < config.initialWallets.length; i++) {
                registry.registerWallet(config.initialWallets[i]);
                console.log("    \u2713", config.initialWallets[i]);
            }
        }
        
        console.log("  \u2713 Configuration complete");
        console.log("");
    }
    
    /**
     * @notice Verify contracts on block explorer
     */
    function _verifyContracts() private view {
        console.log("Contract Verification:");
        console.log("  Run the following commands to verify:");
        console.log("");
        
        // CDPWalletRegistry verification
        console.log("  forge verify-contract \\");
        console.log("    --chain-id", vm.toString(block.chainid), "\\");
        console.log("    --constructor-args", vm.toString(abi.encode(config.owner)), "\\");
        console.log("    ", address(registry), "\\");
        console.log("    contracts/CDPWalletRegistry.sol:CDPWalletRegistry");
        console.log("");
        
        // N0irProtocol verification
        console.log("  forge verify-contract \\");
        console.log("    --chain-id", vm.toString(block.chainid), "\\");
        console.log("    --constructor-args", vm.toString(abi.encode(address(registry))), "\\");
        console.log("    ", address(n0irProtocol), "\\");
        console.log("    contracts/N0irProtocol.sol:N0irProtocol");
        console.log("");
    }
    
    /**
     * @notice Print deployment summary
     */
    function _printSummary() private view {
        console.log("========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("");
        console.log("Core Contracts:");
        console.log("  CDPWalletRegistry:", address(registry));
        console.log("  n0ir Protocol:", address(n0irProtocol));
        console.log("");
        console.log("Configuration:");
        console.log("  Owner:", config.owner);
        console.log("  Registered Wallets:", registry.totalWallets());
        console.log("");
        console.log("Integration Points:");
        console.log("  Universal Router:", address(n0irProtocol.UNIVERSAL_ROUTER()));
        console.log("  Position Manager:", address(n0irProtocol.POSITION_MANAGER()));
        console.log("  Gauge Factory:", address(n0irProtocol.GAUGE_FACTORY()));
        console.log("  Sugar Helper:", address(n0irProtocol.SUGAR_HELPER()));
        console.log("");
        console.log("Supported Assets:");
        console.log("  USDC:", n0irProtocol.USDC());
        console.log("  WETH:", n0irProtocol.WETH());
        console.log("");
        console.log("========================================");
    }
    
    /**
     * @notice Export deployment data
     */
    function _exportDeployment() private {
        string memory obj = "deployment";
        
        // Contract addresses
        vm.serializeAddress(obj, "cdpWalletRegistry", address(registry));
        vm.serializeAddress(obj, "n0irProtocol", address(n0irProtocol));
        
        // Configuration
        vm.serializeAddress(obj, "owner", config.owner);
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeUint(obj, "blockNumber", block.number);
        
        // Integration addresses
        vm.serializeAddress(obj, "universalRouter", address(n0irProtocol.UNIVERSAL_ROUTER()));
        vm.serializeAddress(obj, "positionManager", address(n0irProtocol.POSITION_MANAGER()));
        vm.serializeAddress(obj, "gaugeFactory", address(n0irProtocol.GAUGE_FACTORY()));
        
        string memory timestamp = vm.toString(block.timestamp);
        string memory finalJson = vm.serializeString(obj, "deployedAt", timestamp);
        
        // Create deployments directory if it doesn't exist
        vm.createDir("deployments", true);
        
        // Write deployment file
        string memory filename = string.concat(
            "deployments/n0ir-",
            vm.toString(block.chainid),
            "-",
            vm.toString(block.timestamp),
            ".json"
        );
        
        vm.writeJson(finalJson, filename);
        
        // Also write as latest
        string memory latestFilename = string.concat(
            "deployments/n0ir-",
            vm.toString(block.chainid),
            "-latest.json"
        );
        
        vm.writeJson(finalJson, latestFilename);
        
        console.log("");
        console.log("Deployment exported to:");
        console.log("  ", filename);
        console.log("  ", latestFilename);
    }
}