// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AtomicBase.sol";
import "@interfaces/IERC20.sol";

/**
 * @title VerifyTransferFix
 * @notice Verifies that the fix for USDC transferFrom works correctly
 */
contract TestContract is AtomicBase {
    function testTransfer(address token, address from, address to, uint256 amount) external {
        _safeTransferFrom(token, from, to, amount);
    }
}

contract VerifyTransferFix is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USER = 0x27f4f543c35ee533A7566663C0207Eb179FbA656;
    
    TestContract testContract;
    
    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        
        // Deploy test contract
        testContract = new TestContract();
    }
    
    function testFixedTransferFrom() public {
        console.log("=== Testing Fixed _safeTransferFrom ===");
        
        uint256 amount = 3_000_000; // 3 USDC
        
        // Check initial state
        uint256 userBalance = IERC20(USDC).balanceOf(USER);
        console.log("User balance:", userBalance);
        
        // Setup approval from user to test contract
        vm.prank(USER);
        IERC20(USDC).approve(address(testContract), amount);
        
        uint256 allowance = IERC20(USDC).allowance(USER, address(testContract));
        console.log("Allowance set:", allowance);
        
        // Get initial contract balance
        uint256 contractBalanceBefore = IERC20(USDC).balanceOf(address(testContract));
        console.log("Contract balance before:", contractBalanceBefore);
        
        // Execute transfer using the fixed _safeTransferFrom
        testContract.testTransfer(USDC, USER, address(testContract), amount);
        
        // Check final balance
        uint256 contractBalanceAfter = IERC20(USDC).balanceOf(address(testContract));
        console.log("Contract balance after:", contractBalanceAfter);
        
        // Verify transfer succeeded
        assertEq(contractBalanceAfter - contractBalanceBefore, amount, "Transfer amount mismatch");
        console.log("SUCCESS: Transfer successful!");
    }
    
    function testOriginalFailure() public {
        console.log("\n=== Demonstrating Original Failure ===");
        
        uint256 amount = 3_000_000;
        
        // Setup approval
        vm.prank(USER);
        IERC20(USDC).approve(address(this), amount);
        
        // Try with original abi.encodeWithSignature (should fail)
        (bool success, bytes memory data) = USDC.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", USER, address(this), amount)
        );
        
        console.log("Original method success:", success);
        console.log("Error data length:", data.length);
        
        if (!success && data.length > 0) {
            // Try to decode error message
            if (data.length >= 4) {
                bytes4 errorSelector = bytes4(data);
                console.log("Error selector:");
                console.logBytes4(errorSelector);
                
                // If it's a string revert, decode it
                if (data.length > 4) {
                    try this.decodeRevertString(data) returns (string memory reason) {
                        console.log("Revert reason:", reason);
                    } catch {
                        console.log("Could not decode revert reason");
                    }
                }
            }
        }
    }
    
    function decodeRevertString(bytes memory data) external pure returns (string memory) {
        // Skip the error selector (first 4 bytes)
        if (data.length < 68) revert("Data too short");
        
        assembly {
            // Skip selector (4 bytes) and offset (32 bytes)
            let offset := add(data, 0x24)
            let length := mload(offset)
            
            // Skip to the actual string data
            let strData := add(offset, 0x20)
            
            // Allocate memory for the string
            let str := mload(0x40)
            mstore(str, length)
            
            // Copy string data
            let dataPtr := add(str, 0x20)
            for { let i := 0 } lt(i, length) { i := add(i, 0x20) } {
                mstore(add(dataPtr, i), mload(add(strData, i)))
            }
            
            // Update free memory pointer
            mstore(0x40, add(dataPtr, length))
            
            return(str, add(length, 0x20))
        }
    }
}