// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title WalletRegistry
 * @notice Registry for managing authorized wallets
 * @dev Controls access to protocol functions
 */
contract WalletRegistry is Ownable {
    mapping(address => bool) public isWallet;
    mapping(address => bool) public isOperator;
    uint256 public totalWallets;
    
    event WalletRegistered(address indexed wallet, address indexed registeredBy);
    event WalletRemoved(address indexed wallet, address indexed removedBy);
    event OperatorSet(address indexed operator, bool status);
    
    modifier onlyOperator() {
        require(isOperator[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    constructor() Ownable(msg.sender) {
        isOperator[msg.sender] = true;
    }
    
    function registerWallet(address wallet) external onlyOperator {
        require(wallet != address(0), "Invalid wallet");
        require(!isWallet[wallet], "Already registered");
        
        isWallet[wallet] = true;
        totalWallets++;
        
        emit WalletRegistered(wallet, msg.sender);
    }
    
    function registerWalletsBatch(address[] calldata wallets) external onlyOperator {
        uint256 length = wallets.length;
        require(length > 0, "Empty array");
        require(length <= 100, "Too large");
        
        for (uint256 i = 0; i < length; i++) {
            address wallet = wallets[i];
            require(wallet != address(0), "Invalid wallet");
            
            if (!isWallet[wallet]) {
                isWallet[wallet] = true;
                totalWallets++;
                emit WalletRegistered(wallet, msg.sender);
            }
        }
    }
    
    function removeWallet(address wallet) external onlyOwner {
        require(isWallet[wallet], "Not registered");
        
        isWallet[wallet] = false;
        totalWallets--;
        
        emit WalletRemoved(wallet, msg.sender);
    }
    
    function removeWalletsBatch(address[] calldata wallets) external onlyOwner {
        uint256 length = wallets.length;
        require(length > 0, "Empty array");
        require(length <= 100, "Too large");
        
        for (uint256 i = 0; i < length; i++) {
            address wallet = wallets[i];
            
            if (isWallet[wallet]) {
                isWallet[wallet] = false;
                totalWallets--;
                emit WalletRemoved(wallet, msg.sender);
            }
        }
    }
    
    function setOperator(address operator, bool status) external onlyOwner {
        require(operator != address(0), "Invalid operator");
        isOperator[operator] = status;
        emit OperatorSet(operator, status);
    }
    
    function setOperatorsBatch(address[] calldata operators, bool status) external onlyOwner {
        uint256 length = operators.length;
        require(length > 0, "Empty array");
        require(length <= 50, "Too large");
        
        for (uint256 i = 0; i < length; i++) {
            require(operators[i] != address(0), "Invalid operator");
            isOperator[operators[i]] = status;
            emit OperatorSet(operators[i], status);
        }
    }
    
    function isRegisteredWallet(address wallet) external view returns (bool) {
        return isWallet[wallet];
    }
    
    function areWalletsRegistered(address[] calldata wallets) external view returns (bool[] memory statuses) {
        uint256 length = wallets.length;
        statuses = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            statuses[i] = isWallet[wallets[i]];
        }
    }
}