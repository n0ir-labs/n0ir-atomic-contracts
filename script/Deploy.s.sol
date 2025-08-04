// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../contracts/AerodromeAtomicOperations.sol";

contract DeployScript is Script {
    function run() external {
        // Note: This deploy script is deprecated. Use DeployWithCDP.s.sol instead
        // which includes CDP wallet registry for access control
        revert("Use DeployWithCDP.s.sol instead for CDP access control");
    }
}