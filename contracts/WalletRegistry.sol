// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title WalletRegistry
 * @author Atomic Contract Protocol
 * @notice Registry for managing authorized wallets and operators with role-based access control
 * @dev Implements two-tier permission system: operators can manage wallets, owner manages operators.
 *      Optimized for gas efficiency with batch operations and unchecked arithmetic where safe.
 *      Uses mappings for O(1) access checks and separate counters for tracking.
 */
contract WalletRegistry is Ownable {
    // ============ Custom Errors ============
    // @dev Custom errors for gas efficiency (~24% savings vs require strings)
    
    /// @notice Thrown when provided address is zero address
    error InvalidAddress();
    
    /// @notice Thrown when attempting to register an already registered wallet
    error AlreadyRegistered();
    
    /// @notice Thrown when attempting to remove a non-registered wallet
    error NotRegistered();
    
    /// @notice Thrown when array parameter is empty
    error EmptyArray();
    
    /// @notice Thrown when array exceeds maximum allowed size
    /// @dev Prevents DoS via excessive gas consumption
    error ArrayTooLarge();
    
    /// @notice Thrown when caller lacks required permissions
    error Unauthorized();

    // ============ State Variables ============
    
    /// @notice Tracks registered wallets for protocol access
    /// @dev Mapping provides O(1) lookup for authorization checks
    mapping(address => bool) public isWallet;

    /// @notice Tracks authorized operators who can manage wallets
    /// @dev Operators can register/remove wallets but cannot manage other operators
    mapping(address => bool) public isOperator;

    /// @notice Total count of registered wallets
    /// @dev Used for analytics and monitoring
    uint256 public totalWallets;
    
    /// @notice Total count of active operators
    /// @dev Used for analytics and monitoring
    uint256 public totalOperators;

    // ============ Constants ============
    
    /// @notice Maximum wallets that can be processed in a single batch
    /// @dev Prevents DoS attacks via gas exhaustion
    uint256 private constant MAX_BATCH_SIZE = 100;
    
    /// @notice Maximum operators that can be modified in a single batch
    /// @dev Lower than wallet batch due to higher impact of operator changes
    uint256 private constant MAX_OPERATOR_BATCH = 50;

    // ============ Events ============
    
    /// @notice Emitted when a wallet is registered
    /// @param wallet The registered wallet address
    /// @param registeredBy The operator or owner who registered it
    event WalletRegistered(address indexed wallet, address indexed registeredBy);

    /// @notice Emitted when a wallet is removed
    /// @param wallet The removed wallet address
    /// @param removedBy The owner who removed it
    event WalletRemoved(address indexed wallet, address indexed removedBy);

    /// @notice Emitted when operator status changes
    /// @param operator The operator address
    /// @param status New operator status (true = active, false = inactive)
    event OperatorSet(address indexed operator, bool status);

    /// @notice Emitted when batch operation completes
    /// @param processed Number of items successfully processed
    /// @param skipped Number of items skipped (already registered/removed)
    event BatchOperationCompleted(uint256 processed, uint256 skipped);

    // ============ Modifiers ============
    
    /// @notice Restricts function access to operators or contract owner
    /// @dev Owner always has operator privileges
    modifier onlyOperator() {
        if (!isOperator[msg.sender] && msg.sender != owner()) {
            revert Unauthorized();
        }
        _;
    }

    // ============ Constructor ============
    
    /// @notice Initializes the registry with deployer as owner and first operator
    /// @dev Deployer receives both owner and operator roles for initial setup
    constructor() Ownable(msg.sender) {
        // Grant operator role to deployer
        isOperator[msg.sender] = true;
        totalOperators = 1;
        
        emit OperatorSet(msg.sender, true);
    }

    // ============ External Functions ============

    /**
     * @notice Registers a single wallet for protocol access
     * @dev Only callable by operators or owner. Reverts if wallet already registered.
     * @param wallet Address to register (must not be zero address)
     * @custom:security Operators can register wallets but cannot escalate to operator role
     */
    function registerWallet(address wallet) external onlyOperator {
        // Validate input
        if (wallet == address(0)) revert InvalidAddress();
        if (isWallet[wallet]) revert AlreadyRegistered();

        // Effect: Update state
        isWallet[wallet] = true;
        
        // Safe to use unchecked - overflow virtually impossible (would need 2^256 wallets)
        unchecked {
            ++totalWallets;
        }

        // Event emission
        emit WalletRegistered(wallet, msg.sender);
    }

    /**
     * @notice Registers multiple wallets in a single transaction
     * @dev Gas-efficient batch operation. Skips already registered wallets without reverting.
     * @param wallets Array of addresses to register (max 100 addresses)
     * @custom:gas Optimized with unchecked arithmetic and single SSTORE for total update
     */
    function registerWalletsBatch(address[] calldata wallets) external onlyOperator {
        uint256 length = wallets.length;
        
        // Input validation
        if (length == 0) revert EmptyArray();
        if (length > MAX_BATCH_SIZE) revert ArrayTooLarge();

        uint256 registered;
        uint256 skipped;

        // Process each wallet
        for (uint256 i; i < length;) {
            address wallet = wallets[i];
            
            // Validate address
            if (wallet == address(0)) revert InvalidAddress();

            // Skip if already registered
            if (!isWallet[wallet]) {
                isWallet[wallet] = true;
                emit WalletRegistered(wallet, msg.sender);
                
                // Safe unchecked increment
                unchecked {
                    ++registered;
                }
            } else {
                // Track skipped for reporting
                unchecked {
                    ++skipped;
                }
            }

            // Safe unchecked increment - bounded by length check
            unchecked {
                ++i;
            }
        }

        // Update total count once
        if (registered > 0) {
            unchecked {
                totalWallets += registered;
            }
        }

        emit BatchOperationCompleted(registered, skipped);
    }

    /**
     * @notice Removes a registered wallet from the registry
     * @dev Only callable by owner. Ensures proper access control hierarchy.
     * @param wallet Address to remove (must be currently registered)
     * @custom:security Only owner can remove wallets to prevent operator abuse
     */
    function removeWallet(address wallet) external onlyOwner {
        // Check wallet is registered
        if (!isWallet[wallet]) revert NotRegistered();

        // Effect: Update state
        isWallet[wallet] = false;
        
        // Safe unchecked decrement - underflow prevented by registration check
        unchecked {
            --totalWallets;
        }

        emit WalletRemoved(wallet, msg.sender);
    }

    /**
     * @notice Removes multiple wallets in a single transaction
     * @dev Gas-efficient batch operation. Skips non-registered wallets without reverting.
     * @param wallets Array of addresses to remove (max 100 addresses)
     * @custom:security Only owner can perform bulk removals
     */
    function removeWalletsBatch(address[] calldata wallets) external onlyOwner {
        uint256 length = wallets.length;
        
        // Input validation
        if (length == 0) revert EmptyArray();
        if (length > MAX_BATCH_SIZE) revert ArrayTooLarge();

        uint256 removed;
        uint256 skipped;

        // Process each wallet
        for (uint256 i; i < length;) {
            address wallet = wallets[i];

            // Skip if not registered
            if (isWallet[wallet]) {
                isWallet[wallet] = false;
                emit WalletRemoved(wallet, msg.sender);
                
                // Safe unchecked increment
                unchecked {
                    ++removed;
                }
            } else {
                // Track skipped for reporting
                unchecked {
                    ++skipped;
                }
            }

            // Safe unchecked increment - bounded by length check
            unchecked {
                ++i;
            }
        }

        // Update total count once
        if (removed > 0) {
            unchecked {
                totalWallets -= removed;
            }
        }

        emit BatchOperationCompleted(removed, skipped);
    }

    /**
     * @notice Sets operator status for an address
     * @dev Only owner can grant/revoke operator privileges
     * @param operator Address to modify (must not be zero address)
     * @param status New operator status (true = grant, false = revoke)
     * @custom:security Critical function - operators have wallet management privileges
     */
    function setOperator(address operator, bool status) external onlyOwner {
        // Validate input
        if (operator == address(0)) revert InvalidAddress();

        // Check if status is actually changing
        bool currentStatus = isOperator[operator];
        if (currentStatus == status) return;

        // Effect: Update state
        isOperator[operator] = status;
        
        // Update operator count
        if (status) {
            unchecked {
                ++totalOperators;
            }
        } else {
            unchecked {
                --totalOperators;
            }
        }
        
        emit OperatorSet(operator, status);
    }

    /**
     * @notice Sets operator status for multiple addresses in batch
     * @dev Gas-efficient bulk operator management
     * @param operators Array of addresses to modify (max 50 addresses)
     * @param status New operator status for all addresses
     * @custom:security Batch operator changes require extra caution
     */
    function setOperatorsBatch(
        address[] calldata operators,
        bool status
    ) external onlyOwner {
        uint256 length = operators.length;
        
        // Input validation
        if (length == 0) revert EmptyArray();
        if (length > MAX_OPERATOR_BATCH) revert ArrayTooLarge();

        uint256 statusChanged;
        
        // Process each operator
        for (uint256 i; i < length;) {
            address operator = operators[i];
            
            // Validate address
            if (operator == address(0)) revert InvalidAddress();

            // Only update if status actually changes
            bool currentStatus = isOperator[operator];
            if (currentStatus != status) {
                isOperator[operator] = status;
                emit OperatorSet(operator, status);
                
                unchecked {
                    ++statusChanged;
                }
            }

            // Safe unchecked increment - bounded by length check
            unchecked {
                ++i;
            }
        }
        
        // Update total operators count
        if (statusChanged > 0) {
            if (status) {
                unchecked {
                    totalOperators += statusChanged;
                }
            } else {
                unchecked {
                    totalOperators -= statusChanged;
                }
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Checks if a wallet is registered in the system
     * @dev Convenience function for external contracts
     * @param wallet Address to check
     * @return registered True if wallet is registered, false otherwise
     */
    function isRegisteredWallet(address wallet) external view returns (bool registered) {
        registered = isWallet[wallet];
    }

    /**
     * @notice Checks registration status of multiple wallets
     * @dev Gas-efficient batch query for wallet statuses
     * @param wallets Array of addresses to check
     * @return statuses Array of registration statuses in same order as input
     */
    function areWalletsRegistered(
        address[] calldata wallets
    ) external view returns (bool[] memory statuses) {
        uint256 length = wallets.length;
        statuses = new bool[](length);

        for (uint256 i; i < length;) {
            statuses[i] = isWallet[wallets[i]];
            
            // Safe unchecked increment - bounded by length
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Checks if an address has operator privileges
     * @dev Owner always has operator privileges
     * @param operator Address to check
     * @return authorized True if address is operator or owner
     */
    function isAuthorizedOperator(address operator) external view returns (bool authorized) {
        authorized = isOperator[operator] || operator == owner();
    }
    
    /**
     * @notice Returns registry statistics
     * @dev Useful for monitoring and analytics
     * @return walletCount Total number of registered wallets
     * @return operatorCount Total number of active operators
     */
    function getRegistryStats() external view returns (
        uint256 walletCount,
        uint256 operatorCount
    ) {
        walletCount = totalWallets;
        operatorCount = totalOperators;
    }
}
