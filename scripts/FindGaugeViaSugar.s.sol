// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

contract FindGaugeViaSugar is Script {
    address constant LP_SUGAR = 0x27fc745390d1f4BaF8D184FBd97748340f786634;
    address constant TEST_POOL = 0x3f53f1Fd5b7723DDf38D93a584D280B9b94C3111;
    
    function run() public {
        console.log("Checking ZORA/USDC pool gauge via Sugar...");
        console.log("Pool:", TEST_POOL);
        
        // Just make a low-level call and decode only what we need
        bytes memory data = abi.encodeWithSignature("byAddress(address)", TEST_POOL);
        (bool success, bytes memory result) = LP_SUGAR.call(data);
        
        if (!success) {
            console.log("Sugar call failed");
            return;
        }
        
        console.log("Sugar call successful, result length:", result.length);
        
        // The Lp struct has many fields before gauge:
        // address lp, string symbol, uint8 decimals, uint256 liquidity,
        // int24 type_, int24 tick, uint160 sqrt_ratio,
        // address token0, uint256 reserve0, uint256 staked0,
        // address token1, uint256 reserve1, uint256 staked1,
        // address gauge (this is what we want - position 13)
        
        if (result.length >= 32 * 14) { // Need at least 14 fields
            address gauge;
            assembly {
                // Skip past the offset to the struct data
                let offset := add(result, 0x20)
                // Gauge is the 14th field (13th index), each field is 32 bytes
                gauge := mload(add(offset, mul(13, 0x20)))
            }
            
            if (gauge != address(0)) {
                console.log("[SUCCESS] Found gauge:", gauge);
            } else {
                console.log("[INFO] Pool has no gauge");
            }
        } else {
            console.log("[ERROR] Unexpected result format");
        }
    }
}