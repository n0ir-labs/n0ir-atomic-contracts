// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../contracts/mock/LiquidityManager.sol";
import "../contracts/mock/WalletRegistry.sol";

/**
 * @title DeployMock
 * @notice Deployment script for mock contracts
 * @dev Deploy with: forge script scripts/DeployMock.s.sol:DeployMock --rpc-url $RPC_URL --broadcast
 */
contract DeployMock is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying from:", deployer);
        console.log("Chain ID:", block.chainid);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy WalletRegistry first
        WalletRegistry registry = new WalletRegistry();
        console.log("WalletRegistry deployed at:", address(registry));
        
        // Deploy LiquidityManager with registry address
        LiquidityManager manager = new LiquidityManager(address(registry));
        console.log("LiquidityManager deployed at:", address(manager));
        
        // Register deployer as initial wallet (optional)
        registry.registerWallet(deployer);
        console.log("Deployer registered as authorized wallet");
        
        vm.stopBroadcast();
        
        console.log("\n=== Deployment Summary ===");
        console.log("WalletRegistry:", address(registry));
        console.log("LiquidityManager:", address(manager));
        console.log("Owner:", deployer);
        console.log("\n=== Configuration ===");
        console.log("Total Wallets:", registry.totalWallets());
        console.log("Deployer is Operator:", registry.isOperator(deployer));
        console.log("Deployer is Wallet:", registry.isWallet(deployer));
    }
}