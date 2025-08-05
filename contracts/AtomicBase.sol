// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

abstract contract AtomicBase {
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
    
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }
    
    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }
    
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Approve failed");
    }
}