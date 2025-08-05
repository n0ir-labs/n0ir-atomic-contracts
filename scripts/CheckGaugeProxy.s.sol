// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

contract CheckGaugeProxy is Script {
    address constant GAUGE = 0xaDEfE661847835C6566b1caAbECfcF09C586F300;
    
    // EIP-1967 implementation slot
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    
    function run() public view {
        console.log("Checking if gauge is a proxy...");
        console.log("Gauge address:", GAUGE);
        console.log("Bytecode length:", GAUGE.code.length);
        
        // Check for EIP-1967 implementation
        bytes32 implSlot = vm.load(GAUGE, IMPLEMENTATION_SLOT);
        if (implSlot != bytes32(0)) {
            address implementation = address(uint160(uint256(implSlot)));
            console.log("Found EIP-1967 implementation:", implementation);
        } else {
            console.log("Not an EIP-1967 proxy");
        }
        
        // Check for common proxy patterns in bytecode
        bytes memory code = GAUGE.code;
        if (code.length < 100) {
            console.log("Small bytecode suggests this is likely a minimal proxy");
            
            // Try to extract target from minimal proxy bytecode
            // Minimal proxy pattern: 0x363d3d373d3d3d363d73[20-byte-address]5af43d82803e903d91602b57fd5bf3
            if (code.length == 45) {
                console.log("This is an EIP-1167 minimal proxy");
                
                // The address is at position 10-29 (0-indexed)
                address target;
                bytes memory targetBytes = new bytes(20);
                for (uint i = 0; i < 20; i++) {
                    targetBytes[i] = code[i + 10];
                }
                assembly {
                    target := mload(add(targetBytes, 0x20))
                }
                
                console.log("Implementation contract:", target);
                
                if (target.code.length > 0) {
                    console.log("Implementation bytecode length:", target.code.length);
                }
            }
        }
    }
}