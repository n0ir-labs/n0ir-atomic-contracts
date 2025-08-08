// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title WalletRegistry
 * @notice Registry for managing authorized wallets and operators
 * @dev Implements role-based access control for operations
 */
contract WalletRegistry is Ownable {
    // ============ Custom Errors ============
    error InvalidAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error EmptyArray();
    error ArrayTooLarge();
    error Unauthorized();

    // ============ State Variables ============
    /// @notice Tracks registered wallets
    mapping(address => bool) public isWallet;

    /// @notice Tracks authorized operators
    mapping(address => bool) public isOperator;

    /// @notice Total count of registered wallets
    uint256 public totalWallets;

    // ============ Constants ============
    uint256 private constant MAX_BATCH_SIZE = 100;
    uint256 private constant MAX_OPERATOR_BATCH = 50;

    // ============ Events ============
    /// @notice Emitted when a wallet is registered
    event WalletRegistered(address indexed wallet, address indexed registeredBy);

    /// @notice Emitted when a wallet is removed
    event WalletRemoved(address indexed wallet, address indexed removedBy);

    /// @notice Emitted when operator status changes
    event OperatorSet(address indexed operator, bool status);

    /// @notice Emitted when batch operation completes
    event BatchOperationCompleted(uint256 processed, uint256 skipped);

    // ============ Modifiers ============
    /// @notice Restricts access to operators or owner
    modifier onlyOperator() {
        if (!isOperator[msg.sender] && msg.sender != owner()) {
            revert Unauthorized();
        }
        _;
    }

    // ============ Constructor ============
    /// @notice Initializes the registry with deployer as owner and operator
    constructor() Ownable(msg.sender) {
        isOperator[msg.sender] = true;
        emit OperatorSet(msg.sender, true);
    }

    // ============ External Functions ============

    /**
     * @notice Registers a single wallet
     * @param wallet Address to register
     * @dev Only callable by operators or owner
     */
    function registerWallet(address wallet) external onlyOperator {
        if (wallet == address(0)) revert InvalidAddress();
        if (isWallet[wallet]) revert AlreadyRegistered();

        isWallet[wallet] = true;
        unchecked {
            totalWallets++;
        }

        emit WalletRegistered(wallet, msg.sender);
    }

    /**
     * @notice Registers multiple wallets in batch
     * @param wallets Array of addresses to register
     * @dev Skips already registered wallets
     */
    function registerWalletsBatch(address[] calldata wallets) external onlyOperator {
        uint256 length = wallets.length;
        if (length == 0) revert EmptyArray();
        if (length > MAX_BATCH_SIZE) revert ArrayTooLarge();

        uint256 registered;
        uint256 skipped;

        for (uint256 i = 0; i < length;) {
            address wallet = wallets[i];
            if (wallet == address(0)) revert InvalidAddress();

            if (!isWallet[wallet]) {
                isWallet[wallet] = true;
                emit WalletRegistered(wallet, msg.sender);
                unchecked {
                    registered++;
                }
            } else {
                unchecked {
                    skipped++;
                }
            }

            unchecked {
                i++;
            }
        }

        unchecked {
            totalWallets += registered;
        }

        emit BatchOperationCompleted(registered, skipped);
    }

    /**
     * @notice Removes a registered wallet
     * @param wallet Address to remove
     * @dev Only callable by owner
     */
    function removeWallet(address wallet) external onlyOwner {
        if (!isWallet[wallet]) revert NotRegistered();

        isWallet[wallet] = false;
        unchecked {
            totalWallets--;
        }

        emit WalletRemoved(wallet, msg.sender);
    }

    /**
     * @notice Removes multiple wallets in batch
     * @param wallets Array of addresses to remove
     * @dev Only callable by owner, skips non-registered wallets
     */
    function removeWalletsBatch(address[] calldata wallets) external onlyOwner {
        uint256 length = wallets.length;
        if (length == 0) revert EmptyArray();
        if (length > MAX_BATCH_SIZE) revert ArrayTooLarge();

        uint256 removed;
        uint256 skipped;

        for (uint256 i = 0; i < length;) {
            address wallet = wallets[i];

            if (isWallet[wallet]) {
                isWallet[wallet] = false;
                emit WalletRemoved(wallet, msg.sender);
                unchecked {
                    removed++;
                }
            } else {
                unchecked {
                    skipped++;
                }
            }

            unchecked {
                i++;
            }
        }

        unchecked {
            totalWallets -= removed;
        }

        emit BatchOperationCompleted(removed, skipped);
    }

    /**
     * @notice Sets operator status for an address
     * @param operator Address to modify
     * @param status New operator status
     * @dev Only callable by owner
     */
    function setOperator(address operator, bool status) external onlyOwner {
        if (operator == address(0)) revert InvalidAddress();

        // Skip if status unchanged
        if (isOperator[operator] == status) return;

        isOperator[operator] = status;
        emit OperatorSet(operator, status);
    }

    /**
     * @notice Sets operator status for multiple addresses
     * @param operators Array of addresses to modify
     * @param status New operator status for all addresses
     * @dev Only callable by owner
     */
    function setOperatorsBatch(address[] calldata operators, bool status) external onlyOwner {
        uint256 length = operators.length;
        if (length == 0) revert EmptyArray();
        if (length > MAX_OPERATOR_BATCH) revert ArrayTooLarge();

        for (uint256 i = 0; i < length;) {
            address operator = operators[i];
            if (operator == address(0)) revert InvalidAddress();

            // Only update if status changed
            if (isOperator[operator] != status) {
                isOperator[operator] = status;
                emit OperatorSet(operator, status);
            }

            unchecked {
                i++;
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Checks if a wallet is registered
     * @param wallet Address to check
     * @return Whether the wallet is registered
     */
    function isRegisteredWallet(address wallet) external view returns (bool) {
        return isWallet[wallet];
    }

    /**
     * @notice Checks registration status of multiple wallets
     * @param wallets Array of addresses to check
     * @return statuses Array of registration statuses
     */
    function areWalletsRegistered(address[] calldata wallets) external view returns (bool[] memory statuses) {
        uint256 length = wallets.length;
        statuses = new bool[](length);

        for (uint256 i = 0; i < length;) {
            statuses[i] = isWallet[wallets[i]];
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Checks if an address has operator privileges
     * @param operator Address to check
     * @return Whether the address is an operator
     */
    function isAuthorizedOperator(address operator) external view returns (bool) {
        return isOperator[operator] || operator == owner();
    }
}
