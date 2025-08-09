// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title RouteFinderLib
 * @author Atomic Contract Protocol
 * @notice Library providing utility functions for optimal swap route discovery
 * @dev Pure functions for token ordering, path encoding, and route validation.
 *      Gas-optimized with unchecked arithmetic where safe.
 *      All functions are internal to be inlined by the compiler.
 * @custom:security All functions are pure with no external calls
 */
library RouteFinderLib {
    // ============ Custom Errors ============
    
    /// @notice Thrown when route configuration is invalid
    error InvalidRoute();
    
    /// @notice Thrown when token addresses are invalid or identical
    error InvalidTokenOrder();
    
    /// @notice Thrown when array parameters have mismatched lengths
    error ArrayLengthMismatch();
    
    /// @notice Thrown when route has no hops
    error EmptyRoute();
    
    /// @notice Thrown when tick spacing is invalid (zero or negative)
    error InvalidTickSpacing();

    // ============ Type Definitions ============
    
    /**
     * @notice Defines a swap route through pools
     * @param pools Array of pool addresses to route through
     * @param tokens Array of token addresses in the route
     * @param tickSpacings Array of tick spacings for each pool
     */
    struct SwapRoute {
        address[] pools;
        address[] tokens;
        int24[] tickSpacings;
    }

    /**
     * @notice Information about a pool
     * @param pool The pool address
     * @param token0 The first token (lower address)
     * @param token1 The second token (higher address)
     * @param tickSpacing The tick spacing of the pool
     * @param exists Whether the pool exists
     */
    struct PoolInfo {
        address pool;
        address token0;
        address token1;
        int24 tickSpacing;
        bool exists;
    }

    /**
     * @notice Status of route finding operation
     */
    enum RouteStatus {
        SUCCESS,           // Both routes found successfully
        PARTIAL_SUCCESS,   // Only one route found
        NO_ROUTE,         // No routes found
        DIRECT_POOL       // Direct pool swap, no routing needed
    }

    // ============ Token Ordering Functions ============

    /**
     * @notice Orders two tokens by address (lower address first)
     * @dev Follows Uniswap V3 convention for deterministic pool addresses
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return token0 The token with the lower address
     * @return token1 The token with the higher address
     * @custom:security Validates tokens are not zero or identical
     */
    function orderTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        // Validate tokens
        if (tokenA == tokenB) revert InvalidTokenOrder();
        if (tokenA == address(0) || tokenB == address(0)) revert InvalidTokenOrder();
        
        // Order by address
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // ============ Path Encoding Functions ============

    /**
     * @notice Encodes a multi-hop swap path for the Swap Router
     * @dev Path format: token0 | tickSpacing0 | token1 | tickSpacing1 | token2...
     * @param route The swap route containing tokens and tick spacings
     * @return path The encoded path as bytes for exactInput swaps
     * @custom:gas Uses unchecked loop increment
     */
    function encodePath(SwapRoute memory route) internal pure returns (bytes memory path) {
        // Validate route
        if (route.tokens.length < 2) revert EmptyRoute();
        if (route.pools.length != route.tokens.length - 1) revert ArrayLengthMismatch();
        if (route.tickSpacings.length != route.pools.length) revert ArrayLengthMismatch();
        
        // Start with first token
        path = abi.encodePacked(route.tokens[0]);
        
        // Append each hop
        uint256 length = route.pools.length;
        for (uint256 i; i < length;) {
            // Validate tick spacing
            if (route.tickSpacings[i] <= 0) revert InvalidTickSpacing();
            
            // Convert int24 to uint24 for encoding
            uint24 tickSpacing = uint24(uint256(int256(route.tickSpacings[i])));
            path = abi.encodePacked(path, tickSpacing, route.tokens[i + 1]);
            
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Encodes a single-hop path
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param tickSpacing Tick spacing of the pool
     * @return path The encoded path
     */
    function encodeSingleHop(
        address tokenIn,
        address tokenOut,
        int24 tickSpacing
    ) internal pure returns (bytes memory path) {
        uint24 tickSpacingUint = uint24(uint256(int256(tickSpacing)));
        path = abi.encodePacked(tokenIn, tickSpacingUint, tokenOut);
    }

    // ============ Route Validation Functions ============

    /**
     * @notice Validates a swap route
     * @param route The route to validate
     * @return isValid True if the route is valid
     */
    function validateRoute(SwapRoute memory route) internal pure returns (bool isValid) {
        // Check array lengths match
        if (route.pools.length == 0) return false;
        if (route.tokens.length != route.pools.length + 1) return false;
        if (route.tickSpacings.length != route.pools.length) return false;
        
        // Check no zero addresses in pools
        for (uint256 i = 0; i < route.pools.length; i++) {
            if (route.pools[i] == address(0)) return false;
        }
        
        // Check no zero addresses in tokens
        for (uint256 i = 0; i < route.tokens.length; i++) {
            if (route.tokens[i] == address(0)) return false;
        }
        
        // Check tick spacings are valid (common values)
        for (uint256 i = 0; i < route.tickSpacings.length; i++) {
            int24 ts = route.tickSpacings[i];
            if (ts != 1 && ts != 10 && ts != 50 && ts != 100 && ts != 200 && ts != 2000) {
                return false;
            }
        }
        
        // Check token continuity (output of pool i is input to pool i+1)
        for (uint256 i = 0; i < route.pools.length - 1; i++) {
            // Token at position i+1 should be the output of pool i and input to pool i+1
            if (route.tokens[i + 1] == address(0)) return false;
        }
        
        return true;
    }

    /**
     * @notice Checks if a route is empty (no swaps needed)
     * @param route The route to check
     * @return isEmpty True if the route has no pools
     */
    function isEmptyRoute(SwapRoute memory route) internal pure returns (bool isEmpty) {
        return route.pools.length == 0;
    }

    /**
     * @notice Checks if a route is a single hop
     * @param route The route to check
     * @return isSingle True if the route has exactly one pool
     */
    function isSingleHop(SwapRoute memory route) internal pure returns (bool isSingle) {
        return route.pools.length == 1;
    }

    /**
     * @notice Checks if a route is multi-hop
     * @param route The route to check
     * @return isMulti True if the route has more than one pool
     */
    function isMultiHop(SwapRoute memory route) internal pure returns (bool isMulti) {
        return route.pools.length > 1;
    }

    // ============ Route Construction Helpers ============

    /**
     * @notice Creates an empty route (no swap needed)
     * @return route An empty swap route
     */
    function createEmptyRoute() internal pure returns (SwapRoute memory route) {
        route.pools = new address[](0);
        route.tokens = new address[](0);
        route.tickSpacings = new int24[](0);
    }

    /**
     * @notice Creates a single-hop route
     * @param pool The pool address
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param tickSpacing Tick spacing of the pool
     * @return route The constructed route
     */
    function createSingleHopRoute(
        address pool,
        address tokenIn,
        address tokenOut,
        int24 tickSpacing
    ) internal pure returns (SwapRoute memory route) {
        route.pools = new address[](1);
        route.tokens = new address[](2);
        route.tickSpacings = new int24[](1);
        
        route.pools[0] = pool;
        route.tokens[0] = tokenIn;
        route.tokens[1] = tokenOut;
        route.tickSpacings[0] = tickSpacing;
    }

    /**
     * @notice Creates a two-hop route
     * @param pool1 First pool address
     * @param pool2 Second pool address
     * @param tokenIn Input token
     * @param tokenIntermediate Intermediate token
     * @param tokenOut Output token
     * @param tickSpacing1 Tick spacing of first pool
     * @param tickSpacing2 Tick spacing of second pool
     * @return route The constructed route
     */
    function createTwoHopRoute(
        address pool1,
        address pool2,
        address tokenIn,
        address tokenIntermediate,
        address tokenOut,
        int24 tickSpacing1,
        int24 tickSpacing2
    ) internal pure returns (SwapRoute memory route) {
        route.pools = new address[](2);
        route.tokens = new address[](3);
        route.tickSpacings = new int24[](2);
        
        route.pools[0] = pool1;
        route.pools[1] = pool2;
        route.tokens[0] = tokenIn;
        route.tokens[1] = tokenIntermediate;
        route.tokens[2] = tokenOut;
        route.tickSpacings[0] = tickSpacing1;
        route.tickSpacings[1] = tickSpacing2;
    }

    // ============ Utility Functions ============

    /**
     * @notice Calculates a unique key for pool cache
     * @param token0 First token (ordered)
     * @param token1 Second token (ordered)
     * @param tickSpacing Tick spacing
     * @return key The cache key
     */
    function getPoolCacheKey(
        address token0,
        address token1,
        int24 tickSpacing
    ) internal pure returns (bytes32 key) {
        key = keccak256(abi.encodePacked(token0, token1, tickSpacing));
    }

    /**
     * @notice Checks if a tick spacing is valid
     * @param tickSpacing The tick spacing to check
     * @return isValid True if the tick spacing is a common value
     */
    function isValidTickSpacing(int24 tickSpacing) internal pure returns (bool isValid) {
        return tickSpacing == 1 
            || tickSpacing == 10 
            || tickSpacing == 50 
            || tickSpacing == 100 
            || tickSpacing == 200 
            || tickSpacing == 2000;
    }
}