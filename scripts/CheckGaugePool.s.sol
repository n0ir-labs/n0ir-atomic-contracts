// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "@interfaces/IGauge.sol";

contract CheckGaugePool is Script {
    address constant GAUGE = 0xaDEfE661847835C6566b1caAbECfcF09C586F300;
    address constant POOL = 0x3f53f1Fd5b7723DDf38D93a584D280B9b94C3111;
    
    function run() public view {
        console.log("Checking gauge-pool relationship...");
        console.log("Gauge:", GAUGE);
        console.log("Pool:", POOL);
        
        IGauge gauge = IGauge(GAUGE);
        
        // Check if gauge is for this pool
        try gauge.pool() returns (address gaugePool) {
            console.log("Gauge's pool:", gaugePool);
            if (gaugePool == POOL) {
                console.log("[MATCH] Gauge is for the correct pool!");
            } else {
                console.log("[MISMATCH] Gauge is for a different pool!");
            }
        } catch {
            console.log("[ERROR] Could not get pool from gauge");
        }
        
        // Check reward token
        try gauge.rewardToken() returns (address reward) {
            console.log("Reward token:", reward);
        } catch {
            console.log("[ERROR] Could not get reward token");
        }
        
        // The gauge interface might not have isAlive
    }
}