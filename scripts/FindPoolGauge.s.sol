// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

interface IGaugeFactory {
    function gauges(address pool) external view returns (address);
}

contract FindPoolGauge is Script {
    address constant TEST_POOL = 0x3f53f1Fd5b7723DDf38D93a584D280B9b94C3111;
    
    function run() public view {
        console.log("Finding gauge for ZORA/USDC pool:", TEST_POOL);
        console.log("");
        
        // Try different gauge factory addresses
        address[3] memory gaugeFactories = [
            0xD30677bd8dd15132F251Cb54CbDA552d2A05Fb08, // Current in atomic contract
            0xC84C99FaAF8fB71f8dF9F6a87f06af0FD0EdDa6B, // Alternative from bot
            0x35f35cA5B132CaDf2916BaB57639128eAC5bbcb5  // CL Gauge Factory from docs
        ];
        
        for (uint i = 0; i < gaugeFactories.length; i++) {
            address factory = gaugeFactories[i];
            console.log("Checking gauge factory:", factory);
            
            // Check if factory has code
            if (factory.code.length == 0) {
                console.log("  [SKIP] No contract at this address");
                continue;
            }
            
            try IGaugeFactory(factory).gauges(TEST_POOL) returns (address gauge) {
                if (gauge != address(0)) {
                    console.log("  [FOUND] GAUGE:", gauge);
                } else {
                    console.log("  [EMPTY] No gauge mapping");
                }
            } catch {
                console.log("  [ERROR] Call reverted");
            }
        }
        
        // Direct check if pool has code (exists)
        console.log("\nPool contract check:");
        if (TEST_POOL.code.length > 0) {
            console.log("  [EXISTS] Pool contract exists");
        } else {
            console.log("  [MISSING] No contract at pool address");
        }
    }
}