// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IUniversalRouter {
    struct SwapData {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes path;
    }
    
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
    
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs
    ) external payable;
}