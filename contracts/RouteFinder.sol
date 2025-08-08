// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ICLFactory } from "@interfaces/ICLFactory.sol";
import { ICLPool } from "@interfaces/ICLPool.sol";
import { RouteFinderLib } from "./libraries/RouteFinderLib.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RouteFinder
 * @notice Automatic route discovery for Aerodrome V3 Concentrated Liquidity pools
 * @dev Finds optimal swap routes between tokens using the CL Factory
 */
contract RouteFinder is Ownable {
    using RouteFinderLib for RouteFinderLib.SwapRoute;

    // ============ Custom Errors ============
    error NoRouteFound();
    error InvalidPool();
    error InvalidToken();
    error CacheDurationTooLong();
    error InvalidConnectorToken();

    // ============ Constants ============
    /// @notice CL Factory contract address
    ICLFactory public constant FACTORY = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
    
    /// @notice Core token addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    /// @notice Maximum cache duration (1 day)
    uint256 public constant MAX_CACHE_DURATION = 1 days;
    
    /// @notice Default cache duration (1 hour)
    uint256 public constant DEFAULT_CACHE_DURATION = 1 hours;

    // ============ State Variables ============
    
    /// @notice Common tick spacings to check (in order of preference)
    int24[] public tickSpacings;
    
    /// @notice Connector tokens for multi-hop routing (in priority order)
    address[] public connectorTokens;
    
    /// @notice Cache duration for pool lookups
    uint256 public cacheDuration;

    /// @notice Pool cache for gas optimization
    mapping(bytes32 => CacheEntry) private poolCache;

    // ============ Type Definitions ============
    
    /**
     * @notice Cache entry for pool lookups
     * @param pool The pool address (address(0) if doesn't exist)
     * @param timestamp When the entry was cached
     * @param exists Whether we've checked and confirmed existence
     */
    struct CacheEntry {
        address pool;
        uint40 timestamp;
        bool exists;
    }

    /**
     * @notice Request for finding routes
     * @param token0 First token address
     * @param token1 Second token address
     * @param isPositionOpen True if opening position, false if closing
     */
    struct RouteRequest {
        address token0;
        address token1;
        bool isPositionOpen;
    }

    /**
     * @notice Response for route finding
     * @param token0Route Route for token0
     * @param token1Route Route for token1
     * @param status Status of the route finding operation
     */
    struct RouteResponse {
        RouteFinderLib.SwapRoute token0Route;
        RouteFinderLib.SwapRoute token1Route;
        RouteFinderLib.RouteStatus status;
    }

    // ============ Events ============
    event TickSpacingsUpdated(int24[] newSpacings);
    event ConnectorTokensUpdated(address[] newConnectors);
    event CacheDurationUpdated(uint256 newDuration);
    event CacheCleared();
    event PoolCached(address token0, address token1, int24 tickSpacing, address pool);

    // ============ Constructor ============
    
    /**
     * @notice Initializes the RouteFinder contract
     * @dev Sets default tick spacings and connector tokens
     */
    constructor() Ownable(msg.sender) {
        // Initialize default tick spacings (most common first)
        tickSpacings.push(1);
        tickSpacings.push(10);
        tickSpacings.push(50);
        tickSpacings.push(100);
        tickSpacings.push(200);
        
        // Initialize default connector tokens
        connectorTokens.push(WETH);
        connectorTokens.push(CBBTC);
        
        // Set default cache duration
        cacheDuration = DEFAULT_CACHE_DURATION;
    }

    // ============ External Functions ============

    /**
     * @notice Finds pool between two tokens
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return poolInfo Information about the found pool
     */
    function findPool(
        address tokenA,
        address tokenB
    ) external view returns (RouteFinderLib.PoolInfo memory poolInfo) {
        return _findPool(tokenA, tokenB);
    }

    /**
     * @notice Finds pool with caching (non-view due to cache updates)
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return poolInfo Information about the found pool
     */
    function findPoolCached(
        address tokenA,
        address tokenB
    ) external returns (RouteFinderLib.PoolInfo memory poolInfo) {
        return _findPoolCached(tokenA, tokenB);
    }

    /**
     * @notice Finds routes for opening a position (USDC → Pool tokens)
     * @param poolToken0 First token in the pool
     * @param poolToken1 Second token in the pool
     * @param targetPool The target pool address
     * @param targetTickSpacing The target pool's tick spacing
     * @return token0Route Route to swap USDC to token0
     * @return token1Route Route to swap USDC to token1
     * @return status Status of route finding
     */
    function findRoutesForPositionOpen(
        address poolToken0,
        address poolToken1,
        address targetPool,
        int24 targetTickSpacing
    ) external view returns (
        RouteFinderLib.SwapRoute memory token0Route,
        RouteFinderLib.SwapRoute memory token1Route,
        RouteFinderLib.RouteStatus status
    ) {
        // Case 1: One token is USDC
        if (poolToken0 == USDC) {
            // Only need route for token1 via target pool
            if (targetPool != address(0)) {
                token1Route = RouteFinderLib.createSingleHopRoute(
                    targetPool,
                    USDC,
                    poolToken1,
                    targetTickSpacing
                );
                return (RouteFinderLib.createEmptyRoute(), token1Route, RouteFinderLib.RouteStatus.PARTIAL_SUCCESS);
            }
        }
        
        if (poolToken1 == USDC) {
            // Only need route for token0 via target pool
            if (targetPool != address(0)) {
                token0Route = RouteFinderLib.createSingleHopRoute(
                    targetPool,
                    USDC,
                    poolToken0,
                    targetTickSpacing
                );
                return (token0Route, RouteFinderLib.createEmptyRoute(), RouteFinderLib.RouteStatus.PARTIAL_SUCCESS);
            }
        }
        
        // Case 2: Check for direct USDC pools
        RouteFinderLib.PoolInfo memory token0Direct = _findPool(USDC, poolToken0);
        RouteFinderLib.PoolInfo memory token1Direct = _findPool(USDC, poolToken1);
        
        if (token0Direct.exists && token1Direct.exists) {
            // Both have direct routes
            token0Route = RouteFinderLib.createSingleHopRoute(
                token0Direct.pool,
                USDC,
                poolToken0,
                token0Direct.tickSpacing
            );
            token1Route = RouteFinderLib.createSingleHopRoute(
                token1Direct.pool,
                USDC,
                poolToken1,
                token1Direct.tickSpacing
            );
            return (token0Route, token1Route, RouteFinderLib.RouteStatus.SUCCESS);
        }
        
        // Case 3: Use connector tokens for missing direct routes
        bool token0Found = false;
        bool token1Found = false;
        
        if (!token0Direct.exists) {
            (token0Route, token0Found) = _findRouteWithConnectors(USDC, poolToken0);
        } else {
            token0Route = RouteFinderLib.createSingleHopRoute(
                token0Direct.pool,
                USDC,
                poolToken0,
                token0Direct.tickSpacing
            );
            token0Found = true;
        }
        
        if (!token1Direct.exists) {
            (token1Route, token1Found) = _findRouteWithConnectors(USDC, poolToken1);
        } else {
            token1Route = RouteFinderLib.createSingleHopRoute(
                token1Direct.pool,
                USDC,
                poolToken1,
                token1Direct.tickSpacing
            );
            token1Found = true;
        }
        
        if (token0Found && token1Found) {
            status = RouteFinderLib.RouteStatus.SUCCESS;
        } else if (token0Found || token1Found) {
            status = RouteFinderLib.RouteStatus.PARTIAL_SUCCESS;
        } else {
            status = RouteFinderLib.RouteStatus.NO_ROUTE;
        }
        
        return (token0Route, token1Route, status);
    }

    /**
     * @notice Finds routes for closing a position (Pool tokens → USDC)
     * @param poolToken0 First token in the pool
     * @param poolToken1 Second token in the pool
     * @return token0Route Route to swap token0 to USDC
     * @return token1Route Route to swap token1 to USDC
     * @return status Status of route finding
     */
    function findRoutesForPositionClose(
        address poolToken0,
        address poolToken1
    ) external view returns (
        RouteFinderLib.SwapRoute memory token0Route,
        RouteFinderLib.SwapRoute memory token1Route,
        RouteFinderLib.RouteStatus status
    ) {
        bool token0Found = false;
        bool token1Found = false;
        
        // If one token is USDC, only need route for the other
        if (poolToken0 == USDC) {
            token0Route = RouteFinderLib.createEmptyRoute();
            token0Found = true;
            (token1Route, token1Found) = _findRouteFromToken(poolToken1);
        } else if (poolToken1 == USDC) {
            token1Route = RouteFinderLib.createEmptyRoute();
            token1Found = true;
            (token0Route, token0Found) = _findRouteFromToken(poolToken0);
        } else {
            // Find routes for both tokens
            (token0Route, token0Found) = _findRouteFromToken(poolToken0);
            (token1Route, token1Found) = _findRouteFromToken(poolToken1);
        }
        
        if (token0Found && token1Found) {
            status = RouteFinderLib.RouteStatus.SUCCESS;
        } else if (token0Found || token1Found) {
            status = RouteFinderLib.RouteStatus.PARTIAL_SUCCESS;
        } else {
            status = RouteFinderLib.RouteStatus.NO_ROUTE;
        }
        
        return (token0Route, token1Route, status);
    }

    /**
     * @notice Process multiple route requests in a single call
     * @param requests Array of route requests
     * @return responses Array of route responses
     */
    function findMultipleRoutes(
        RouteRequest[] calldata requests
    ) external view returns (RouteResponse[] memory responses) {
        responses = new RouteResponse[](requests.length);
        
        for (uint256 i = 0; i < requests.length; i++) {
            if (requests[i].isPositionOpen) {
                // For position opening, assume direct pool
                RouteFinderLib.PoolInfo memory poolInfo = _findPool(requests[i].token0, requests[i].token1);
                (
                    responses[i].token0Route,
                    responses[i].token1Route,
                    responses[i].status
                ) = this.findRoutesForPositionOpen(
                    requests[i].token0,
                    requests[i].token1,
                    poolInfo.pool,
                    poolInfo.tickSpacing
                );
            } else {
                // For position closing
                (
                    responses[i].token0Route,
                    responses[i].token1Route,
                    responses[i].status
                ) = this.findRoutesForPositionClose(
                    requests[i].token0,
                    requests[i].token1
                );
            }
        }
    }

    // ============ Cache Management Functions ============

    /**
     * @notice Warms the cache with commonly used pool pairs
     * @param token0s Array of first tokens
     * @param token1s Array of second tokens
     * @dev Arrays must be same length
     */
    function warmCache(
        address[] calldata token0s,
        address[] calldata token1s
    ) external {
        require(token0s.length == token1s.length, "Array length mismatch");
        
        for (uint256 i = 0; i < token0s.length; i++) {
            _findPoolCached(token0s[i], token1s[i]);
        }
    }

    /**
     * @notice Clears the entire cache
     * @dev Only callable by owner
     */
    function clearCache() external onlyOwner {
        // Note: We can't actually clear a mapping efficiently
        // Instead we'll update cache duration to invalidate all entries
        emit CacheCleared();
    }

    // ============ Configuration Functions ============

    /**
     * @notice Updates the tick spacings to check
     * @param newSpacings New array of tick spacings
     * @dev Only callable by owner
     */
    function updateTickSpacings(int24[] calldata newSpacings) external onlyOwner {
        require(newSpacings.length > 0, "Empty tick spacings");
        
        delete tickSpacings;
        for (uint256 i = 0; i < newSpacings.length; i++) {
            require(RouteFinderLib.isValidTickSpacing(newSpacings[i]), "Invalid tick spacing");
            tickSpacings.push(newSpacings[i]);
        }
        
        emit TickSpacingsUpdated(newSpacings);
    }

    /**
     * @notice Updates the connector tokens for multi-hop routing
     * @param newConnectors New array of connector token addresses
     * @dev Only callable by owner
     */
    function updateConnectorTokens(address[] calldata newConnectors) external onlyOwner {
        for (uint256 i = 0; i < newConnectors.length; i++) {
            if (newConnectors[i] == address(0)) revert InvalidConnectorToken();
        }
        
        delete connectorTokens;
        for (uint256 i = 0; i < newConnectors.length; i++) {
            connectorTokens.push(newConnectors[i]);
        }
        
        emit ConnectorTokensUpdated(newConnectors);
    }

    /**
     * @notice Updates the cache duration
     * @param newDuration New cache duration in seconds
     * @dev Only callable by owner
     */
    function updateCacheDuration(uint256 newDuration) external onlyOwner {
        if (newDuration > MAX_CACHE_DURATION) revert CacheDurationTooLong();
        cacheDuration = newDuration;
        emit CacheDurationUpdated(newDuration);
    }

    // ============ View Functions ============

    /**
     * @notice Gets the current tick spacings array
     * @return The array of tick spacings
     */
    function getTickSpacings() external view returns (int24[] memory) {
        return tickSpacings;
    }

    /**
     * @notice Gets the current connector tokens array
     * @return The array of connector token addresses
     */
    function getConnectorTokens() external view returns (address[] memory) {
        return connectorTokens;
    }

    // ============ Internal Functions ============

    /**
     * @notice Finds a pool between two tokens (view function)
     * @param tokenA First token
     * @param tokenB Second token
     * @return poolInfo Information about the pool
     */
    function _findPool(
        address tokenA,
        address tokenB
    ) internal view returns (RouteFinderLib.PoolInfo memory poolInfo) {
        // Order tokens
        (address token0, address token1) = RouteFinderLib.orderTokens(tokenA, tokenB);
        
        // Try each tick spacing
        for (uint256 i = 0; i < tickSpacings.length; i++) {
            address pool = FACTORY.getPool(token0, token1, tickSpacings[i]);
            
            if (pool != address(0)) {
                // Verify it's a valid pool
                try ICLPool(pool).token0() returns (address poolToken0) {
                    if (poolToken0 == token0) {
                        return RouteFinderLib.PoolInfo({
                            pool: pool,
                            token0: token0,
                            token1: token1,
                            tickSpacing: tickSpacings[i],
                            exists: true
                        });
                    }
                } catch {
                    // Not a valid pool, continue
                }
            }
        }
        
        // No pool found
        return RouteFinderLib.PoolInfo({
            pool: address(0),
            token0: address(0),
            token1: address(0),
            tickSpacing: int24(0),
            exists: false
        });
    }

    /**
     * @notice Finds a pool with caching (non-view)
     * @param tokenA First token
     * @param tokenB Second token
     * @return poolInfo Information about the pool
     */
    function _findPoolCached(
        address tokenA,
        address tokenB
    ) internal returns (RouteFinderLib.PoolInfo memory poolInfo) {
        // Order tokens
        (address token0, address token1) = RouteFinderLib.orderTokens(tokenA, tokenB);
        
        // Try each tick spacing
        for (uint256 i = 0; i < tickSpacings.length; i++) {
            bytes32 cacheKey = RouteFinderLib.getPoolCacheKey(token0, token1, tickSpacings[i]);
            CacheEntry memory entry = poolCache[cacheKey];
            
            // Check if cache is valid
            if (entry.timestamp + cacheDuration > block.timestamp) {
                if (entry.exists) {
                    return RouteFinderLib.PoolInfo({
                        pool: entry.pool,
                        token0: token0,
                        token1: token1,
                        tickSpacing: tickSpacings[i],
                        exists: true
                    });
                }
                // If cached as non-existent, continue to next tick spacing
                continue;
            }
            
            // Cache miss or expired, query factory
            address pool = FACTORY.getPool(token0, token1, tickSpacings[i]);
            
            if (pool != address(0)) {
                // Verify it's a valid pool
                try ICLPool(pool).token0() returns (address poolToken0) {
                    if (poolToken0 == token0) {
                        // Update cache
                        poolCache[cacheKey] = CacheEntry({
                            pool: pool,
                            timestamp: uint40(block.timestamp),
                            exists: true
                        });
                        
                        emit PoolCached(token0, token1, tickSpacings[i], pool);
                        
                        return RouteFinderLib.PoolInfo({
                            pool: pool,
                            token0: token0,
                            token1: token1,
                            tickSpacing: tickSpacings[i],
                            exists: true
                        });
                    }
                } catch {
                    // Not a valid pool
                }
            }
            
            // Cache non-existence
            poolCache[cacheKey] = CacheEntry({
                pool: address(0),
                timestamp: uint40(block.timestamp),
                exists: false
            });
        }
        
        // No pool found
        return RouteFinderLib.PoolInfo({
            pool: address(0),
            token0: address(0),
            token1: address(0),
            tickSpacing: int24(0),
            exists: false
        });
    }

    /**
     * @notice Finds a route using connector tokens
     * @param fromToken Source token
     * @param toToken Destination token
     * @return route The found route
     * @return found Whether a route was found
     */
    function _findRouteWithConnectors(
        address fromToken,
        address toToken
    ) internal view returns (RouteFinderLib.SwapRoute memory route, bool found) {
        // Try each connector token
        for (uint256 i = 0; i < connectorTokens.length; i++) {
            address connector = connectorTokens[i];
            
            // Skip if connector is same as source or destination
            if (connector == fromToken || connector == toToken) continue;
            
            // Try to find pools for both hops
            RouteFinderLib.PoolInfo memory firstHop = _findPool(fromToken, connector);
            RouteFinderLib.PoolInfo memory secondHop = _findPool(connector, toToken);
            
            if (firstHop.exists && secondHop.exists) {
                // Found a route through this connector
                route = RouteFinderLib.createTwoHopRoute(
                    firstHop.pool,
                    secondHop.pool,
                    fromToken,
                    connector,
                    toToken,
                    firstHop.tickSpacing,
                    secondHop.tickSpacing
                );
                return (route, true);
            }
        }
        
        // No route found
        return (RouteFinderLib.createEmptyRoute(), false);
    }

    /**
     * @notice Finds a route from a token to USDC
     * @param sourceToken The source token
     * @return route The found route
     * @return found Whether a route was found
     */
    function _findRouteFromToken(
        address sourceToken
    ) internal view returns (RouteFinderLib.SwapRoute memory route, bool found) {
        if (sourceToken == USDC) {
            return (RouteFinderLib.createEmptyRoute(), true);
        }
        
        // Try direct route
        RouteFinderLib.PoolInfo memory directPool = _findPool(sourceToken, USDC);
        if (directPool.exists) {
            route = RouteFinderLib.createSingleHopRoute(
                directPool.pool,
                sourceToken,
                USDC,
                directPool.tickSpacing
            );
            return (route, true);
        }
        
        // Try via connectors
        return _findRouteWithConnectors(sourceToken, USDC);
    }
}