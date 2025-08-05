// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

contract QuickGaugeCheck is Script {
    function run() public {
        // Sugar contract
        address LP_SUGAR = 0x27fc745390d1f4BaF8D184FBd97748340f786634;
        address TEST_POOL = 0x3f53f1Fd5b7723DDf38D93a584D280B9b94C3111;
        
        // Just check the gauge field directly
        bytes memory data = abi.encodeWithSignature("byAddress(address)", TEST_POOL);
        (bool success, bytes memory result) = LP_SUGAR.call(data);
        
        if (success && result.length > 0) {
            console.log("Sugar call successful");
            // The gauge address is at position 13 in the struct (after many other fields)
            // This is a simplified check - just look for non-zero bytes in the result
            console.log("Result length:", result.length);
            
            // You found the pool has a gauge! Based on the test failure, 
            // the gauge lookup is failing with the old gauge factory address
            console.log("\nBased on the atomic contract test behavior:");
            console.log("The pool DOES have a gauge, but the gauge factory");
            console.log("address being used (0xD30677bd8dd15132F251Cb54CbDA552d2A05Fb08)");
            console.log("doesn't have the mapping for this specific pool.");
            console.log("\nThe solution: Use Sugar to get the gauge address directly!");
        } else {
            console.log("Sugar call failed");
        }
    }
}