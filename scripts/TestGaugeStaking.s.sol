// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "@interfaces/IGauge.sol";
import "@interfaces/INonfungiblePositionManager.sol";

contract TestGaugeStaking is Script {
    address constant GAUGE = 0xaDEfE661847835C6566b1caAbECfcF09C586F300;
    address constant POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    address constant TEST_ADDRESS = address(0x1337); // Test address
    
    function run() public {
        console.log("Testing gauge at:", GAUGE);
        
        // Check if gauge has code
        if (GAUGE.code.length == 0) {
            console.log("[ERROR] No contract at gauge address");
            return;
        }
        
        console.log("[OK] Gauge contract exists");
        
        // Try to check if a position can be staked
        IGauge gauge = IGauge(GAUGE);
        
        // Check if we can call basic functions
        try gauge.rewardToken() returns (address reward) {
            console.log("Reward token:", reward);
        } catch {
            console.log("[ERROR] Failed to get reward token");
        }
        
        // The issue might be that the position needs to be approved first
        // or the caller needs to be the owner of the NFT
        console.log("\nNote: To stake a position:");
        console.log("1. The NFT owner must approve the gauge contract");
        console.log("2. The caller must be the NFT owner");
        console.log("3. The position must exist and have liquidity");
    }
}