// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CDPWalletRegistry
 * @author N0IR
 * @notice Registry for managing wallets created through Coinbase Developer Platform
 * @dev Only the owner can add/remove wallets and set operators
 */
contract CDPWalletRegistry is Ownable {
    /// @notice Mapping of CDP wallet addresses to their registration status
    mapping(address => bool) public isCDPWallet;
    
    /// @notice Mapping of operator addresses that can register CDP wallets
    mapping(address => bool) public isOperator;
    
    /// @notice Total number of registered CDP wallets
    uint256 public totalWallets;
    
    /**
     * @notice Emitted when a CDP wallet is registered
     * @param wallet The registered wallet address
     * @param registeredBy The operator who registered the wallet
     */
    event WalletRegistered(address indexed wallet, address indexed registeredBy);
    
    /**
     * @notice Emitted when a CDP wallet is removed
     * @param wallet The removed wallet address
     * @param removedBy The address that removed the wallet
     */
    event WalletRemoved(address indexed wallet, address indexed removedBy);
    
    /**
     * @notice Emitted when an operator is added or removed
     * @param operator The operator address
     * @param status The new operator status
     */
    event OperatorSet(address indexed operator, bool status);
    
    /**
     * @notice Modifier to restrict access to operators only
     */
    modifier onlyOperator() {
        require(isOperator[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    /**
     * @notice Constructor sets the deployer as owner
     */
    constructor() Ownable(msg.sender) {
        isOperator[msg.sender] = true;
    }
    
    /**
     * @notice Register a new CDP wallet
     * @dev Can only be called by operators or owner
     * @param wallet The wallet address to register
     */
    function registerWallet(address wallet) external onlyOperator {
        require(wallet != address(0), "Invalid wallet address");
        require(!isCDPWallet[wallet], "Wallet already registered");
        
        isCDPWallet[wallet] = true;
        totalWallets++;
        
        emit WalletRegistered(wallet, msg.sender);
    }
    
    /**
     * @notice Register multiple CDP wallets in batch
     * @dev Can only be called by operators or owner
     * @param wallets Array of wallet addresses to register
     */
    function registerWalletsBatch(address[] calldata wallets) external onlyOperator {
        uint256 length = wallets.length;
        require(length > 0, "Empty array");
        require(length <= 100, "Batch too large");
        
        for (uint256 i = 0; i < length; i++) {
            address wallet = wallets[i];
            require(wallet != address(0), "Invalid wallet address");
            
            if (!isCDPWallet[wallet]) {
                isCDPWallet[wallet] = true;
                totalWallets++;
                emit WalletRegistered(wallet, msg.sender);
            }
        }
    }
    
    /**
     * @notice Remove a CDP wallet from the registry
     * @dev Can only be called by owner
     * @param wallet The wallet address to remove
     */
    function removeWallet(address wallet) external onlyOwner {
        require(isCDPWallet[wallet], "Wallet not registered");
        
        isCDPWallet[wallet] = false;
        totalWallets--;
        
        emit WalletRemoved(wallet, msg.sender);
    }
    
    /**
     * @notice Set operator status for an address
     * @dev Can only be called by owner
     * @param operator The address to set operator status for
     * @param status The operator status to set
     */
    function setOperator(address operator, bool status) external onlyOwner {
        require(operator != address(0), "Invalid operator address");
        isOperator[operator] = status;
        emit OperatorSet(operator, status);
    }
    
    /**
     * @notice Check if an address is a registered CDP wallet
     * @param wallet The address to check
     * @return bool True if the wallet is registered
     */
    function isRegisteredWallet(address wallet) external view returns (bool) {
        return isCDPWallet[wallet];
    }
}