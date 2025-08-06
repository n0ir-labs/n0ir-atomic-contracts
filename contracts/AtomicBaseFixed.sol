// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

abstract contract AtomicBaseFixed {
    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error InsufficientOutput(uint256 expected, uint256 actual);
    error InvalidPool(address pool);
    error UnauthorizedCaller(address caller);
    error SlippageExceeded(uint256 maxSlippage, uint256 actualSlippage);
    error ZeroAmount();
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    
    uint256 private constant SLIPPAGE_DENOMINATOR = 10000;
    uint256 private constant MAX_SLIPPAGE = 500; // 5%
    
    uint256 private locked = 1;
    
    modifier nonReentrant() {
        require(locked == 1, "ReentrancyGuard: reentrant call");
        locked = 2;
        _;
        locked = 1;
    }
    
    modifier deadlineCheck(uint256 deadline) {
        if (block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }
        _;
    }
    
    modifier validAmount(uint256 amount) {
        if (amount == 0) {
            revert ZeroAmount();
        }
        _;
    }
    
    function _validatePool(address pool, address) internal pure {
        if (pool == address(0)) {
            revert InvalidPool(pool);
        }
        
        // For existing pool validation - just check it's not zero address
        // The actual pool verification happens when we derive tokens from it
    }
    
    
    function _checkSlippage(
        uint256 expected,
        uint256 actual,
        uint256 maxSlippageBps
    ) internal pure {
        if (actual < expected) {
            uint256 slippage = ((expected - actual) * SLIPPAGE_DENOMINATOR) / expected;
            if (slippage > maxSlippageBps) {
                revert SlippageExceeded(maxSlippageBps, slippage);
            }
        }
    }
    
    function _validateTickRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        if (tickLower >= tickUpper) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
    }
    
    function _calculateMinimumOutput(
        uint256 expectedOutput,
        uint256 slippageBps
    ) internal pure returns (uint256) {
        return (expectedOutput * (SLIPPAGE_DENOMINATOR - slippageBps)) / SLIPPAGE_DENOMINATOR;
    }
    
    /**
     * @dev Fixed version of _safeTransferFrom that properly handles USDC on Base
     * Uses abi.encodeWithSelector for more reliable encoding
     */
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        // Use the exact selector for transferFrom
        bytes4 selector = bytes4(keccak256("transferFrom(address,address,uint256)"));
        
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(selector, from, to, amount)
        );
        
        // Check success first
        require(success, "Transfer call failed");
        
        // Then check return value - USDC returns true on success
        if (data.length > 0) {
            // Decode and check the boolean return value
            bool result = abi.decode(data, (bool));
            require(result, "Transfer returned false");
        }
        // If data.length == 0, some tokens don't return a value but the call succeeded
    }
    
    /**
     * @dev Alternative implementation using assembly for maximum compatibility
     */
    function _safeTransferFromAssembly(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        assembly {
            // Allocate memory for the call data
            let data := mload(0x40)
            
            // Store the function selector for transferFrom(address,address,uint256)
            mstore(data, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(data, 0x04), from)
            mstore(add(data, 0x24), to)
            mstore(add(data, 0x44), amount)
            
            // Make the call
            let success := call(gas(), token, 0, data, 0x64, 0, 0x20)
            
            // Check if the call was successful
            if iszero(success) {
                revert(0, 0)
            }
            
            // Check return value if any
            if returndatasize() {
                // Copy the return data
                returndatacopy(0, 0, returndatasize())
                
                // Check if transferFrom returned true
                if iszero(mload(0)) {
                    revert(0, 0)
                }
            }
        }
    }
    
    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));
        
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(selector, to, amount)
        );
        
        require(success, "Transfer call failed");
        
        if (data.length > 0) {
            bool result = abi.decode(data, (bool));
            require(result, "Transfer returned false");
        }
    }
    
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        bytes4 selector = bytes4(keccak256("approve(address,uint256)"));
        
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(selector, spender, amount)
        );
        
        require(success, "Approve call failed");
        
        if (data.length > 0) {
            bool result = abi.decode(data, (bool));
            require(result, "Approve returned false");
        }
    }
}