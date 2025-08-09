# RouteFinder Solidity Implementation Guide

## Overview
This document outlines how to implement the Python RouteFinder logic as a Solidity smart contract for on-chain route discovery.

## Core Contract Structure

```solidity
pragma solidity ^0.8.19;

interface ICLFactory {
    function getPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) external view returns (address pool);
}

contract RouteFinder {
    // Constants
    ICLFactory constant FACTORY = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    
    // Common tick spacings to check
    int24[] public tickSpacings = [int24(1), 10, 50, 100, 200, 500];
    
    // Route structure
    struct SwapRoute {
        address[] pools;
        address[] tokens;
        int24[] tickSpacings;
    }
    
    struct PoolInfo {
        address pool;
        address token0;
        address token1;
        int24 tickSpacing;
        bool exists;
    }
}
```

## Core Functions Implementation

### 1. Find Pool Between Two Tokens

```solidity
function findPool(
    address tokenA,
    address tokenB
) public view returns (PoolInfo memory) {
    // Order tokens (smaller address first)
    (address token0, address token1) = tokenA < tokenB ? 
        (tokenA, tokenB) : (tokenB, tokenA);
    
    // Try each tick spacing
    for (uint i = 0; i < tickSpacings.length; i++) {
        address pool = FACTORY.getPool(token0, token1, tickSpacings[i]);
        
        if (pool != address(0)) {
            return PoolInfo({
                pool: pool,
                token0: token0,
                token1: token1,
                tickSpacing: tickSpacings[i],
                exists: true
            });
        }
    }
    
    return PoolInfo({
        pool: address(0),
        token0: address(0),
        token1: address(0),
        tickSpacing: int24(0),
        exists: false
    });
}
```

### 2. Find Routes for Position Opening (USDC → Pool Tokens)

```solidity
function findRoutesForPositionOpen(
    address poolToken0,
    address poolToken1,
    address targetPool,
    int24 targetTickSpacing
) public view returns (
    SwapRoute memory token0Route,
    SwapRoute memory token1Route,
    bool token0RouteExists,
    bool token1RouteExists
) {
    // Case 1: One token is USDC
    if (poolToken0 == USDC) {
        // Only need route for token1 via target pool
        if (targetPool != address(0)) {
            token1Route = SwapRoute({
                pools: new address[](1),
                tokens: new address[](2),
                tickSpacings: new int24[](1)
            });
            token1Route.pools[0] = targetPool;
            token1Route.tokens[0] = USDC;
            token1Route.tokens[1] = poolToken1;
            token1Route.tickSpacings[0] = targetTickSpacing;
            return (token0Route, token1Route, false, true);
        }
    }
    
    if (poolToken1 == USDC) {
        // Only need route for token0 via target pool
        if (targetPool != address(0)) {
            token0Route = SwapRoute({
                pools: new address[](1),
                tokens: new address[](2),
                tickSpacings: new int24[](1)
            });
            token0Route.pools[0] = targetPool;
            token0Route.tokens[0] = USDC;
            token0Route.tokens[1] = poolToken0;
            token0Route.tickSpacings[0] = targetTickSpacing;
            return (token0Route, token1Route, true, false);
        }
    }
    
    // Case 2: Check for direct USDC pools
    PoolInfo memory token0Direct = findPool(USDC, poolToken0);
    PoolInfo memory token1Direct = findPool(USDC, poolToken1);
    
    if (token0Direct.exists && token1Direct.exists) {
        // Both have direct routes
        token0Route = _createSingleHopRoute(USDC, poolToken0, token0Direct);
        token1Route = _createSingleHopRoute(USDC, poolToken1, token1Direct);
        return (token0Route, token1Route, true, true);
    }
    
    // Case 3: Use connector tokens for missing direct routes
    if (!token0Direct.exists) {
        (token0Route, token0RouteExists) = _findRouteWithConnectors(USDC, poolToken0, true);
    } else {
        token0Route = _createSingleHopRoute(USDC, poolToken0, token0Direct);
        token0RouteExists = true;
    }
    
    if (!token1Direct.exists) {
        (token1Route, token1RouteExists) = _findRouteWithConnectors(USDC, poolToken1, true);
    } else {
        token1Route = _createSingleHopRoute(USDC, poolToken1, token1Direct);
        token1RouteExists = true;
    }
    
    return (token0Route, token1Route, token0RouteExists, token1RouteExists);
}
```

### 3. Find Routes Using Connector Tokens

```solidity
function _findRouteWithConnectors(
    address fromToken,
    address toToken,
    bool fromUSDC
) private view returns (SwapRoute memory route, bool exists) {
    // Try WETH as connector
    if (toToken != WETH && fromToken != WETH) {
        PoolInfo memory firstHop = findPool(fromToken, WETH);
        PoolInfo memory secondHop = findPool(WETH, toToken);
        
        if (firstHop.exists && secondHop.exists) {
            route = SwapRoute({
                pools: new address[](2),
                tokens: new address[](3),
                tickSpacings: new int24[](2)
            });
            
            route.pools[0] = firstHop.pool;
            route.pools[1] = secondHop.pool;
            route.tokens[0] = fromToken;
            route.tokens[1] = WETH;
            route.tokens[2] = toToken;
            route.tickSpacings[0] = firstHop.tickSpacing;
            route.tickSpacings[1] = secondHop.tickSpacing;
            
            return (route, true);
        }
    }
    
    // Try cbBTC as connector
    if (toToken != CBBTC && fromToken != CBBTC) {
        PoolInfo memory firstHop = findPool(fromToken, CBBTC);
        PoolInfo memory secondHop = findPool(CBBTC, toToken);
        
        if (firstHop.exists && secondHop.exists) {
            route = SwapRoute({
                pools: new address[](2),
                tokens: new address[](3),
                tickSpacings: new int24[](2)
            });
            
            route.pools[0] = firstHop.pool;
            route.pools[1] = secondHop.pool;
            route.tokens[0] = fromToken;
            route.tokens[1] = CBBTC;
            route.tokens[2] = toToken;
            route.tickSpacings[0] = firstHop.tickSpacing;
            route.tickSpacings[1] = secondHop.tickSpacing;
            
            return (route, true);
        }
    }
    
    return (route, false);
}
```

### 4. Find Routes for Position Closing (Pool Tokens → USDC)

```solidity
function findRoutesForPositionClose(
    address poolToken0,
    address poolToken1
) public view returns (
    SwapRoute memory token0Route,
    SwapRoute memory token1Route,
    bool token0RouteExists,
    bool token1RouteExists
) {
    // If one token is USDC, only need route for the other
    if (poolToken0 == USDC) {
        (token1Route, token1RouteExists) = _findRouteFromToken(poolToken1);
        return (token0Route, token1Route, false, token1RouteExists);
    }
    
    if (poolToken1 == USDC) {
        (token0Route, token0RouteExists) = _findRouteFromToken(poolToken0);
        return (token0Route, token1Route, token0RouteExists, false);
    }
    
    // Find routes for both tokens
    (token0Route, token0RouteExists) = _findRouteFromToken(poolToken0);
    (token1Route, token1RouteExists) = _findRouteFromToken(poolToken1);
    
    return (token0Route, token1Route, token0RouteExists, token1RouteExists);
}

function _findRouteFromToken(
    address sourceToken
) private view returns (SwapRoute memory route, bool exists) {
    if (sourceToken == USDC) {
        return (route, false);
    }
    
    // Try direct route
    PoolInfo memory directPool = findPool(sourceToken, USDC);
    if (directPool.exists) {
        route = _createSingleHopRoute(sourceToken, USDC, directPool);
        return (route, true);
    }
    
    // Try via connectors (reverse direction)
    return _findRouteWithConnectors(sourceToken, USDC, false);
}
```

### 5. Helper Functions

```solidity
function _createSingleHopRoute(
    address fromToken,
    address toToken,
    PoolInfo memory poolInfo
) private pure returns (SwapRoute memory) {
    SwapRoute memory route = SwapRoute({
        pools: new address[](1),
        tokens: new address[](2),
        tickSpacings: new int24[](1)
    });
    
    route.pools[0] = poolInfo.pool;
    route.tokens[0] = fromToken;
    route.tokens[1] = toToken;
    route.tickSpacings[0] = poolInfo.tickSpacing;
    
    return route;
}
```

## Gas Optimization Considerations

### 1. Cache Pool Lookups
```solidity
mapping(bytes32 => address) private poolCache;

function _getCachedPool(
    address token0,
    address token1,
    int24 tickSpacing
) private view returns (address) {
    bytes32 key = keccak256(abi.encodePacked(token0, token1, tickSpacing));
    address cached = poolCache[key];
    
    if (cached != address(0)) {
        return cached;
    }
    
    return FACTORY.getPool(token0, token1, tickSpacing);
}
```

### 2. Batch Pool Queries
For multiple route findings, consider implementing multicall:

```solidity
function findMultipleRoutes(
    address[] calldata token0s,
    address[] calldata token1s
) external view returns (SwapRoute[] memory routes) {
    routes = new SwapRoute[](token0s.length);
    
    for (uint i = 0; i < token0s.length; i++) {
        (routes[i],) = _findRouteWithConnectors(USDC, token0s[i], true);
    }
}
```

### 3. Static Analysis for Common Pairs
Pre-compute and store routes for frequently used pairs:

```solidity
mapping(address => mapping(address => SwapRoute)) private commonRoutes;

constructor() {
    // Pre-compute common routes
    _storeCommonRoute(USDC, WETH);
    _storeCommonRoute(USDC, CBBTC);
    // ... more pairs
}
```

## Integration with Existing Contracts

### 1. Use with Atomic Contract
```solidity
interface IAtomicContract {
    function createPosition(
        address pool,
        SwapRoute calldata token0Route,
        SwapRoute calldata token1Route,
        uint256 usdcAmount
    ) external;
}

contract PositionCreator {
    IAtomicContract atomic = IAtomicContract(0x74102dfD347931F0E6B3C27157e97f4f6F167542);
    RouteFinder routeFinder = RouteFinder(ROUTE_FINDER_ADDRESS);
    
    function createPositionWithRouting(
        address poolToken0,
        address poolToken1,
        address targetPool,
        int24 tickSpacing,
        uint256 usdcAmount
    ) external {
        (
            RouteFinder.SwapRoute memory route0,
            RouteFinder.SwapRoute memory route1,
            bool exists0,
            bool exists1
        ) = routeFinder.findRoutesForPositionOpen(
            poolToken0,
            poolToken1,
            targetPool,
            tickSpacing
        );
        
        require(exists0 || poolToken0 == USDC, "No route for token0");
        require(exists1 || poolToken1 == USDC, "No route for token1");
        
        atomic.createPosition(targetPool, route0, route1, usdcAmount);
    }
}
```

### 2. View-Only Route Helper
For off-chain route calculation before transaction:

```solidity
contract RouteHelper {
    RouteFinder routeFinder;
    
    function getOptimalRoute(
        address fromToken,
        address toToken
    ) external view returns (
        address[] memory pools,
        uint256 estimatedGas,
        bool isMultiHop
    ) {
        // Implementation for optimal route calculation
    }
}
```