// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title AtomicBase
 * @notice Base contract providing atomic operation safety features
 * @dev Implements reentrancy guards, slippage checks, and safe transfers
 */
abstract contract AtomicBase {
    // ============ Custom Errors ============
    /// @notice Thrown when transaction deadline has passed
    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    
    /// @notice Thrown when output is less than expected
    error InsufficientOutput(uint256 expected, uint256 actual);
    
    /// @notice Thrown when pool address is invalid
    error InvalidPool(address pool);
    
    /// @notice Thrown when caller is not authorized
    error UnauthorizedCaller(address caller);
    
    /// @notice Thrown when slippage exceeds tolerance
    error SlippageExceeded(uint256 maxSlippage, uint256 actualSlippage);
    
    /// @notice Thrown when amount is zero
    error ZeroAmount();
    
    /// @notice Thrown when tick range is invalid
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    
    /// @notice Thrown when reentrancy is detected
    error ReentrancyDetected();
    
    /// @notice Thrown when transfer fails
    error TransferFailed();
    
    /// @notice Thrown when approval fails
    error ApprovalFailed();
    
    // ============ Constants ============
    /// @dev Basis points denominator for slippage calculations
    uint256 private constant SLIPPAGE_DENOMINATOR = 10000;
    
    /// @dev Maximum allowed slippage in basis points (5%)
    uint256 private constant MAX_SLIPPAGE = 500;
    
    // ============ State Variables ============
    /// @dev Reentrancy guard state (1 = unlocked, 2 = locked)
    uint256 private locked = 1;
    
    // ============ Modifiers ============
    
    /**
     * @notice Prevents reentrancy attacks
     * @dev Uses gas-efficient uint256 for lock state
     */
    modifier nonReentrant() {
        if (locked != 1) revert ReentrancyDetected();
        locked = 2;
        _;
        locked = 1;
    }
    
    /**
     * @notice Ensures transaction executes before deadline
     * @param deadline Unix timestamp deadline
     */
    modifier deadlineCheck(uint256 deadline) {
        if (block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }
        _;
    }
    
    /**
     * @notice Ensures amount is non-zero
     * @param amount Amount to validate
     */
    modifier validAmount(uint256 amount) {
        if (amount == 0) {
            revert ZeroAmount();
        }
        _;
    }
    
    // ============ Internal Functions ============
    
    /**
     * @notice Validates pool address
     * @param pool Pool address to validate
     * @param expectedFactory Expected factory address (unused in current implementation)
     * @dev Can be extended to verify pool against factory
     */
    function _validatePool(address pool, address expectedFactory) internal pure {
        if (pool == address(0)) {
            revert InvalidPool(pool);
        }
        // Additional factory validation can be added here
        // For now, actual pool verification happens when deriving tokens
    }
    
    
    /**
     * @notice Checks if actual output meets slippage requirements
     * @param expected Expected output amount
     * @param actual Actual output amount
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
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
    
    /**
     * @notice Validates tick range for concentrated liquidity position
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param tickSpacing Required tick spacing for the pool
     */
    function _validateTickRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        // Check tick ordering
        if (tickLower >= tickUpper) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        
        // Check tick spacing alignment
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
    }
    
    /**
     * @notice Calculates minimum output with slippage tolerance
     * @param expectedOutput Expected output amount
     * @param slippageBps Slippage tolerance in basis points
     * @return Minimum acceptable output amount
     */
    function _calculateMinimumOutput(
        uint256 expectedOutput,
        uint256 slippageBps
    ) internal pure returns (uint256) {
        return (expectedOutput * (SLIPPAGE_DENOMINATOR - slippageBps)) / SLIPPAGE_DENOMINATOR;
    }
    
    /**
     * @notice Safely transfers tokens from one address to another
     * @param token Token contract address
     * @param from Source address
     * @param to Destination address
     * @param amount Amount to transfer
     * @dev Handles both standard and non-standard ERC20 implementations
     */
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        bytes4 selector = bytes4(keccak256("transferFrom(address,address,uint256)"));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(selector, from, to, amount)
        );
        
        if (!success) {
            // Bubble up revert reason if available
            if (data.length > 0) {
                assembly {
                    revert(add(32, data), mload(data))
                }
            }
            revert TransferFailed();
        }
        
        // Check return value for tokens that return bool
        if (data.length > 0) {
            if (!abi.decode(data, (bool))) {
                revert TransferFailed();
            }
        }
    }
    
    /**
     * @notice Safely transfers tokens to an address
     * @param token Token contract address
     * @param to Destination address
     * @param amount Amount to transfer
     * @dev Handles both standard and non-standard ERC20 implementations
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(selector, to, amount)
        );
        
        if (!success) {
            if (data.length > 0) {
                assembly {
                    revert(add(32, data), mload(data))
                }
            }
            revert TransferFailed();
        }
        
        if (data.length > 0) {
            if (!abi.decode(data, (bool))) {
                revert TransferFailed();
            }
        }
    }
    
    /**
     * @notice Safely approves token spending
     * @param token Token contract address
     * @param spender Address to approve
     * @param amount Amount to approve
     * @dev Handles both standard and non-standard ERC20 implementations
     */
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        bytes4 selector = bytes4(keccak256("approve(address,uint256)"));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(selector, spender, amount)
        );
        
        if (!success) {
            if (data.length > 0) {
                assembly {
                    revert(add(32, data), mload(data))
                }
            }
            revert ApprovalFailed();
        }
        
        if (data.length > 0) {
            if (!abi.decode(data, (bool))) {
                revert ApprovalFailed();
            }
        }
    }
}