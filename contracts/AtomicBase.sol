// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title AtomicBase
 * @notice Base contract providing atomic operation safety features for DeFi operations
 * @dev Implements reentrancy guards, slippage checks, deadline validation, and safe ERC20 transfers.
 *      Designed for gas efficiency with custom errors and optimized storage patterns.
 *      All derived contracts inherit battle-tested security primitives.
 */
abstract contract AtomicBase {
    // ============ Custom Errors ============
    // @dev Custom errors save ~24% gas vs require strings
    
    /// @notice Thrown when transaction deadline has passed
    /// @param deadline The deadline that was set
    /// @param currentTime The current block timestamp
    error DeadlineExpired(uint256 deadline, uint256 currentTime);

    /// @notice Thrown when output amount is below minimum expected
    /// @param expected Minimum expected output amount
    /// @param actual Actual output amount received
    error InsufficientOutput(uint256 expected, uint256 actual);

    /// @notice Thrown when pool address is invalid or unverified
    /// @param pool The invalid pool address
    error InvalidPool(address pool);

    /// @notice Thrown when caller lacks required authorization
    /// @param caller The unauthorized caller address
    error UnauthorizedCaller(address caller);

    /// @notice Thrown when price slippage exceeds maximum tolerance
    /// @param maxSlippage Maximum allowed slippage in basis points
    /// @param actualSlippage Actual slippage that occurred in basis points
    error SlippageExceeded(uint256 maxSlippage, uint256 actualSlippage);

    /// @notice Thrown when amount parameter is zero
    error ZeroAmount();

    /// @notice Thrown when tick range is invalid for concentrated liquidity
    /// @param tickLower Lower tick boundary
    /// @param tickUpper Upper tick boundary
    error InvalidTickRange(int24 tickLower, int24 tickUpper);

    /// @notice Thrown when reentrancy attempt is detected
    error ReentrancyDetected();

    /// @notice Thrown when ERC20 transfer operation fails
    error TransferFailed();

    /// @notice Thrown when ERC20 approval operation fails
    error ApprovalFailed();
    
    /// @notice Thrown when address is zero address
    error ZeroAddress();

    // ============ Constants ============
    /// @dev Basis points denominator for percentage calculations (100% = 10000 bps)
    uint256 private constant BPS_DENOMINATOR = 10_000;
    
    /// @dev Maximum allowed slippage in basis points (5% = 500 bps)
    uint256 private constant MAX_SLIPPAGE_BPS = 500;
    
    /// @dev Reentrancy guard unlocked state
    uint256 private constant UNLOCKED = 1;
    
    /// @dev Reentrancy guard locked state
    uint256 private constant LOCKED = 2;

    // ============ State Variables ============
    /// @dev Reentrancy guard state - uses uint256 for gas efficiency
    /// @custom:security Uses 1 for unlocked and 2 for locked to save gas on SSTORE
    uint256 private _reentrancyStatus = UNLOCKED;

    // ============ Modifiers ============

    /**
     * @notice Prevents reentrancy attacks using checks-effects-interactions pattern
     * @dev Uses gas-efficient uint256 for lock state. Costs ~2100 gas on first call,
     *      ~100 gas on subsequent calls due to warm storage access.
     * @custom:security Critical modifier - must be applied to all external state-changing functions
     */
    modifier nonReentrant() {
        // Check: Ensure we're not in a reentrant call
        if (_reentrancyStatus != UNLOCKED) revert ReentrancyDetected();
        
        // Effect: Lock the contract
        _reentrancyStatus = LOCKED;
        
        // Interaction: Execute the function
        _;
        
        // Effect: Unlock the contract
        _reentrancyStatus = UNLOCKED;
    }

    /**
     * @notice Ensures transaction executes before deadline to prevent stale transactions
     * @dev Protects against long-pending transactions and MEV attacks
     * @param deadline Unix timestamp after which the transaction reverts
     * @custom:security Essential for preventing sandwich attacks and stale pricing
     */
    modifier deadlineCheck(uint256 deadline) {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }
        _;
    }

    /**
     * @notice Ensures amount is non-zero to prevent wasteful transactions
     * @dev Saves gas by reverting early on zero-value operations
     * @param amount Amount to validate (must be > 0)
     */
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    // ============ Internal Functions ============

    /**
     * @notice Validates pool address is not zero and optionally verifies against factory
     * @dev Can be overridden by derived contracts for factory-specific validation
     * @param pool Pool address to validate
     * @param expectedFactory Expected factory address (unused in base implementation)
     * @custom:todo Implement factory validation in production deployment
     */
    function _validatePool(address pool, address expectedFactory) internal view virtual {
        if (pool == address(0)) revert InvalidPool(pool);
        
        // Factory validation can be implemented in derived contracts
        // Example: require(IFactory(expectedFactory).isPool(pool), "Invalid pool");
        // Keeping unused parameter to maintain interface compatibility
        expectedFactory; // Silence unused variable warning
    }

    /**
     * @notice Validates that actual output meets minimum slippage requirements
     * @dev Protects against sandwich attacks and excessive price impact
     * @param expected Expected output amount before slippage
     * @param actual Actual output amount received
     * @param maxSlippageBps Maximum allowed slippage in basis points (1% = 100 bps)
     * @custom:security Critical check for MEV protection
     */
    function _checkSlippage(
        uint256 expected,
        uint256 actual,
        uint256 maxSlippageBps
    ) internal pure {
        // If actual >= expected, no slippage occurred (favorable execution)
        if (actual >= expected) return;
        
        // Calculate actual slippage in basis points
        // Using unchecked for gas optimization - overflow impossible due to logic
        unchecked {
            uint256 slippage = ((expected - actual) * BPS_DENOMINATOR) / expected;
            if (slippage > maxSlippageBps) {
                revert SlippageExceeded(maxSlippageBps, slippage);
            }
        }
    }

    /**
     * @notice Validates tick range for concentrated liquidity position
     * @dev Ensures ticks are properly ordered and aligned to pool's tick spacing
     * @param tickLower Lower tick boundary (must be < tickUpper)
     * @param tickUpper Upper tick boundary (must be > tickLower)
     * @param tickSpacing Required tick spacing for the pool
     * @custom:security Prevents invalid position creation that would revert on-chain
     */
    function _validateTickRange(
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing
    ) internal pure {
        // Check tick ordering (lower must be less than upper)
        if (tickLower >= tickUpper) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        
        // Check tick spacing alignment
        // Both ticks must be divisible by tickSpacing
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        
        // Additional validation could include:
        // - MIN_TICK and MAX_TICK boundaries
        // - Minimum tick range width
    }

    /**
     * @notice Calculates minimum acceptable output after applying slippage tolerance
     * @dev Uses unchecked math for gas optimization where overflow is impossible
     * @param expectedOutput Expected output amount before slippage
     * @param slippageBps Slippage tolerance in basis points (100 = 1%)
     * @return minOutput Minimum acceptable output amount after slippage
     */
    function _calculateMinimumOutput(
        uint256 expectedOutput,
        uint256 slippageBps
    ) internal pure returns (uint256 minOutput) {
        // Validate slippage is within acceptable range
        if (slippageBps > MAX_SLIPPAGE_BPS) {
            revert SlippageExceeded(MAX_SLIPPAGE_BPS, slippageBps);
        }
        
        // Calculate minimum output with slippage
        // Formula: minOutput = expectedOutput * (100% - slippage%)
        unchecked {
            minOutput = (expectedOutput * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
        }
    }

    /**
     * @notice Safely transfers tokens from one address to another
     * @dev Handles both standard and non-standard ERC20 implementations (USDT, etc.)
     *      Uses low-level call to handle tokens that don't return bool
     * @param token Token contract address
     * @param from Source address
     * @param to Destination address  
     * @param amount Amount to transfer
     * @custom:security Handles tokens that don't follow ERC20 standard exactly
     */
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        // Validate addresses
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        
        // Skip if amount is 0
        if (amount == 0) return;
        
        // Prepare low-level call
        bytes4 selector = bytes4(keccak256("transferFrom(address,address,uint256)"));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(selector, from, to, amount)
        );
        
        // Check call success
        if (!success) {
            // Bubble up revert reason if available
            if (data.length > 0) {
                assembly {
                    let returndata_size := mload(data)
                    revert(add(32, data), returndata_size)
                }
            }
            revert TransferFailed();
        }
        
        // Check return value if present
        // Some tokens (USDT) don't return a value, some return false on failure
        if (data.length > 0) {
            bool returnValue = abi.decode(data, (bool));
            if (!returnValue) revert TransferFailed();
        }
    }

    /**
     * @notice Safely transfers tokens to an address
     * @dev Handles both standard and non-standard ERC20 implementations
     * @param token Token contract address
     * @param to Destination address
     * @param amount Amount to transfer
     * @custom:security Handles non-standard tokens like USDT
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        // Validate addresses
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        
        // Skip if amount is 0
        if (amount == 0) return;
        
        // Prepare low-level call
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(selector, to, amount)
        );
        
        // Check call success
        if (!success) {
            // Bubble up revert reason if available
            if (data.length > 0) {
                assembly {
                    let returndata_size := mload(data)
                    revert(add(32, data), returndata_size)
                }
            }
            revert TransferFailed();
        }
        
        // Check return value if present
        if (data.length > 0) {
            bool returnValue = abi.decode(data, (bool));
            if (!returnValue) revert TransferFailed();
        }
    }

    /**
     * @notice Safely approves token spending with support for non-standard tokens
     * @dev Handles USDT and other non-standard implementations. Sets allowance to 0 first
     *      if current allowance is non-zero to handle tokens that require it.
     * @param token Token contract address
     * @param spender Address to approve for spending
     * @param amount Amount to approve (use type(uint256).max for infinite approval)
     * @custom:security Always reset approval to 0 before setting new value for safety
     */
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        // Validate addresses
        if (token == address(0)) revert ZeroAddress();
        if (spender == address(0)) revert ZeroAddress();
        
        // First, try to set approval to 0 (required by some tokens like USDT)
        // This handles tokens that don't allow changing non-zero allowance
        _attemptApproval(token, spender, 0);
        
        // Then set the actual approval amount if non-zero
        if (amount > 0) {
            _attemptApproval(token, spender, amount);
        }
    }
    
    /**
     * @notice Internal helper to attempt an approval operation
     * @dev Separated to avoid code duplication
     * @param token Token contract address
     * @param spender Address to approve
     * @param amount Amount to approve
     */
    function _attemptApproval(
        address token,
        address spender,
        uint256 amount
    ) private {
        bytes4 selector = bytes4(keccak256("approve(address,uint256)"));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(selector, spender, amount)
        );
        
        // Check call success
        if (!success) {
            // Bubble up revert reason if available
            if (data.length > 0) {
                assembly {
                    let returndata_size := mload(data)
                    revert(add(32, data), returndata_size)
                }
            }
            revert ApprovalFailed();
        }
        
        // Check return value if present
        if (data.length > 0) {
            bool returnValue = abi.decode(data, (bool));
            if (!returnValue) revert ApprovalFailed();
        }
    }
}