// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../contracts/AerodromeAtomicOperations.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        AerodromeAtomicOperations atomic = new AerodromeAtomicOperations();
        
        console.log("AerodromeAtomicOperations deployed at:", address(atomic));
        console.log("USDC address:", atomic.USDC());
        console.log("AERO address:", atomic.AERO());
        console.log("Universal Router:", address(atomic.UNIVERSAL_ROUTER()));
        console.log("Position Manager:", address(atomic.POSITION_MANAGER()));
        
        vm.stopBroadcast();
    }
}