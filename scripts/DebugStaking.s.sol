// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

contract DebugStaking is Script {
    address constant GAUGE = 0xaDEfE661847835C6566b1caAbECfcF09C586F300;
    
    function run() public {
        console.log("Analyzing gauge staking function...");
        
        // Get the bytecode at gauge address
        bytes memory code = GAUGE.code;
        console.log("Gauge bytecode length:", code.length);
        
        // Try to simulate a stake call
        bytes memory stakeCalldata = abi.encodeWithSignature("stake(uint256)", 12345);
        (bool success, bytes memory data) = GAUGE.call(stakeCalldata);
        
        if (!success) {
            console.log("Stake call failed");
            console.log("Return data length:", data.length);
            
            if (data.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(data, 0x20))
                }
                console.log("Error selector:");
                console.logBytes4(selector);
                
                // Common error selectors
                if (selector == 0x08c379a0) {
                    console.log("This is a standard Error(string) revert");
                    // Try to decode the error message
                    if (data.length >= 68) {
                        string memory reason;
                        assembly {
                            reason := add(data, 0x44)
                        }
                        console.log("Error might be related to token ownership or approval");
                    }
                }
            } else if (data.length == 0) {
                console.log("Empty revert - likely require() without message");
            }
        } else {
            console.log("Stake call succeeded (unexpected for non-existent token)");
        }
    }
}