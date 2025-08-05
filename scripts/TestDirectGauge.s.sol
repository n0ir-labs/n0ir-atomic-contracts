// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

interface IGauge {
    function stakedContains(address user, uint256 tokenId) external view returns (bool);
    function stake(uint256 tokenId) external;
}

contract TestDirectGauge is Script {
    // Known gauge addresses from other pools
    address constant GAUGE_1 = 0xd961c5E0Eb87DeCBE2eA97FfF1F6Fa0f5f0d623e; // Example gauge
    address constant TEST_POOL = 0x3f53f1Fd5b7723DDf38D93a584D280B9b94C3111;
    
    function run() public view {
        console.log("Testing if known gauge addresses exist...");
        
        // Check if the gauge contract exists
        if (GAUGE_1.code.length > 0) {
            console.log("Gauge at", GAUGE_1, "exists");
        }
        
        // The ZORA/USDC pool gauge might follow a deterministic address pattern
        // Let's check the CREATE2 pattern for gauge addresses
        
        // Gauge Factory uses CREATE2 with pool address as salt
        bytes32 salt = bytes32(uint256(uint160(TEST_POOL)));
        console.log("Expected salt for pool:", vm.toString(salt));
    }
}