// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IUniversalRouter {
    error BalanceTooLow();
    error ContractLocked();
    error DeltaNotNegative(address currency);
    error DeltaNotPositive(address currency);
    error ETHNotAccepted();
    error ExecutionFailed(uint256 commandIndex, bytes message);
    error FromAddressIsNotOwner();
    error InputLengthMismatch();
    error InsufficientBalance();
    error InsufficientETH();
    error InsufficientToken();
    error InvalidBips();
    error InvalidBridgeType(uint8 bridgeType);
    error InvalidCommandType(uint256 commandType);
    error InvalidEthSender();
    error InvalidPath();
    error InvalidRecipient();
    error InvalidReserves();
    error InvalidTokenAddress();
    error LengthMismatch();
    error NotPoolManager();
    error SliceOutOfBounds();
    error StableExactOutputUnsupported();
    error TransactionDeadlinePassed();
    error UnsafeCast();
    error UnsupportedAction(uint256 action);
    error V2InvalidPath();
    error V2TooLittleReceived();
    error V2TooMuchRequested();
    error V3InvalidAmountOut();
    error V3InvalidCaller();
    error V3InvalidSwap();
    error V3TooLittleReceived();
    error V3TooMuchRequested();
    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
    error V4TooMuchRequested(uint256 maxAmountInRequested, uint256 amountRequested);

    event CrossChainSwap(
        address indexed caller,
        address indexed localRouter,
        uint32 indexed destinationDomain,
        bytes32 commitment
    );
    
    event UniversalRouterBridge(
        address indexed sender,
        address indexed recipient,
        address indexed token,
        uint256 amount,
        uint32 domain
    );
    
    event UniversalRouterSwap(
        address indexed sender,
        address indexed recipient
    );

    function OPTIMISM_CHAIN_ID() external view returns (uint256);
    function PERMIT2() external view returns (address);
    function UNISWAP_V2_FACTORY() external view returns (address);
    function UNISWAP_V2_PAIR_INIT_CODE_HASH() external view returns (bytes32);
    function UNISWAP_V3_FACTORY() external view returns (address);
    function UNISWAP_V3_POOL_INIT_CODE_HASH() external view returns (bytes32);
    function VELODROME_CL_FACTORY() external view returns (address);
    function VELODROME_CL_POOL_INIT_CODE_HASH() external view returns (bytes32);
    function VELODROME_V2_FACTORY() external view returns (address);
    function VELODROME_V2_INIT_CODE_HASH() external view returns (bytes32);
    function WETH9() external view returns (address);

    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
    
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
    
    function msgSender() external view returns (address);
    
    function poolManager() external view returns (address);
    
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
    
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}