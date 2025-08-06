// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@interfaces/IERC20.sol";

/**
 * @title DiagnoseTransfer
 * @notice Diagnostic test to identify why USDC transferFrom is failing on Base mainnet
 */
contract DiagnoseTransfer is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USER = 0x27f4f543c35ee533A7566663C0207Eb179FbA656;
    address constant CONTRACT = 0xE227D6F50dbeFf4CD4135ac0A034b201410cd098;
    
    function setUp() public {
        // Fork Base mainnet at a recent block
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }
    
    function testDirectTransferFrom() public {
        // Test 1: Direct transferFrom call
        console.log("=== Test 1: Direct transferFrom ===");
        
        uint256 amount = 3_000_000; // 3 USDC
        
        // Check initial state
        uint256 userBalance = IERC20(USDC).balanceOf(USER);
        uint256 allowance = IERC20(USDC).allowance(USER, CONTRACT);
        
        console.log("User balance:", userBalance);
        console.log("Allowance:", allowance);
        
        // Impersonate the contract
        vm.startPrank(CONTRACT);
        
        // Try direct transferFrom
        try IERC20(USDC).transferFrom(USER, CONTRACT, amount) returns (bool success) {
            console.log("Direct transferFrom succeeded:", success);
        } catch Error(string memory reason) {
            console.log("Direct transferFrom failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Direct transferFrom failed with low-level error");
            console.logBytes(lowLevelData);
        }
        
        vm.stopPrank();
    }
    
    function testLowLevelTransferFrom() public {
        // Test 2: Low-level call (mimicking _safeTransferFrom)
        console.log("\n=== Test 2: Low-level transferFrom call ===");
        
        uint256 amount = 3_000_000;
        
        // Method 1: Using abi.encodeWithSignature (original implementation)
        (bool success1, bytes memory data1) = USDC.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", USER, CONTRACT, amount)
        );
        
        console.log("abi.encodeWithSignature success:", success1);
        console.log("Return data length:", data1.length);
        if (data1.length > 0) {
            console.log("Return value:", abi.decode(data1, (bool)));
        }
        
        // Method 2: Using abi.encodeWithSelector
        bytes4 selector = bytes4(keccak256("transferFrom(address,address,uint256)"));
        (bool success2, bytes memory data2) = USDC.call(
            abi.encodeWithSelector(selector, USER, CONTRACT, amount)
        );
        
        console.log("\nabi.encodeWithSelector success:", success2);
        console.log("Return data length:", data2.length);
        if (data2.length > 0) {
            console.log("Return value:", abi.decode(data2, (bool)));
        }
        
        // Method 3: Manual selector construction
        bytes4 manualSelector = 0x23b872dd; // transferFrom selector
        (bool success3, bytes memory data3) = USDC.call(
            abi.encodeWithSelector(manualSelector, USER, CONTRACT, amount)
        );
        
        console.log("\nManual selector success:", success3);
        console.log("Return data length:", data3.length);
        if (data3.length > 0) {
            console.log("Return value:", abi.decode(data3, (bool)));
        }
    }
    
    function testWithImpersonation() public {
        // Test 3: Test with user impersonation and manual approval
        console.log("\n=== Test 3: With user impersonation ===");
        
        uint256 amount = 3_000_000;
        
        // Impersonate user and set fresh approval
        vm.startPrank(USER);
        
        // Reset approval to 0 first (some tokens require this)
        IERC20(USDC).approve(CONTRACT, 0);
        console.log("Reset approval to 0");
        
        // Set new approval
        IERC20(USDC).approve(CONTRACT, amount);
        console.log("Set approval to", amount);
        
        // Check the approval was set
        uint256 newAllowance = IERC20(USDC).allowance(USER, CONTRACT);
        console.log("New allowance:", newAllowance);
        
        vm.stopPrank();
        
        // Now try transfer as contract
        vm.startPrank(CONTRACT);
        
        try IERC20(USDC).transferFrom(USER, CONTRACT, amount) returns (bool success) {
            console.log("TransferFrom after fresh approval succeeded:", success);
            
            // Check final balances
            uint256 contractBalance = IERC20(USDC).balanceOf(CONTRACT);
            console.log("Contract USDC balance after transfer:", contractBalance);
        } catch Error(string memory reason) {
            console.log("TransferFrom failed with reason:", reason);
        } catch {
            console.log("TransferFrom failed with unknown error");
        }
        
        vm.stopPrank();
    }
    
    function testUSDCSpecifics() public {
        // Test 4: Check USDC-specific behaviors
        console.log("\n=== Test 4: USDC contract specifics ===");
        
        // Check if USDC is a proxy
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 implAddress = vm.load(USDC, implSlot);
        console.log("Implementation slot value:");
        console.logBytes32(implAddress);
        
        // Check USDC code size
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(USDC)
        }
        console.log("USDC code size:", codeSize);
        
        // Try to get USDC metadata
        try IERC20(USDC).name() returns (string memory name) {
            console.log("Token name:", name);
        } catch {
            console.log("Could not get token name");
        }
        
        try IERC20(USDC).symbol() returns (string memory symbol) {
            console.log("Token symbol:", symbol);
        } catch {
            console.log("Could not get token symbol");
        }
        
        try IERC20(USDC).decimals() returns (uint8 decimals) {
            console.log("Token decimals:", decimals);
        } catch {
            console.log("Could not get token decimals");
        }
    }
    
    function testAssemblyTransfer() public {
        // Test 5: Assembly implementation
        console.log("\n=== Test 5: Assembly transferFrom ===");
        
        uint256 amount = 3_000_000;
        
        // Setup fresh approval
        vm.prank(USER);
        IERC20(USDC).approve(CONTRACT, amount);
        
        // Try assembly version
        vm.startPrank(CONTRACT);
        
        bool success;
        assembly {
            // Allocate memory for the call data
            let data := mload(0x40)
            
            // Store the function selector for transferFrom(address,address,uint256)
            mstore(data, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(data, 0x04), USER)
            mstore(add(data, 0x24), CONTRACT)
            mstore(add(data, 0x44), amount)
            
            // Make the call with value = 0
            success := call(gas(), USDC, 0, data, 0x64, 0, 0x20)
            
            // Log success
            if success {
                // Check return value if any
                if returndatasize() {
                    // Copy the return data
                    let retval := mload(0x00)
                    returndatacopy(0x00, 0, 0x20)
                    retval := mload(0x00)
                    
                    // Log the return value
                    success := retval
                }
            }
        }
        
        console.log("Assembly transferFrom success:", success);
        
        vm.stopPrank();
    }
    
    function testMinimalCase() public {
        // Test 6: Absolute minimal test case
        console.log("\n=== Test 6: Minimal test case ===");
        
        // Give the user some USDC if they don't have enough
        uint256 userBalance = IERC20(USDC).balanceOf(USER);
        if (userBalance < 3_000_000) {
            // Find a whale to transfer from
            address whale = 0x20FE51A9229EEf2cF8Ad9E89d91CAb9312cF3b7A; // Large USDC holder on Base
            vm.prank(whale);
            IERC20(USDC).transfer(USER, 10_000_000); // Give user 10 USDC
            console.log("Funded user with USDC from whale");
        }
        
        // Setup
        vm.startPrank(USER);
        IERC20(USDC).approve(CONTRACT, type(uint256).max);
        vm.stopPrank();
        
        // Try transfer
        vm.prank(CONTRACT);
        bool success = IERC20(USDC).transferFrom(USER, CONTRACT, 1); // Just 1 wei of USDC
        
        console.log("Minimal transferFrom (1 wei) success:", success);
    }
}