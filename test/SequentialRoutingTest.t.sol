// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/mock/LiquidityManager.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/ICLPool.sol";

contract SequentialRoutingTest is Test {
    LiquidityManager liquidityManager;
    
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant LBTC = 0xecAc9C5F704e954931349Da37F60E39f515c11c1;
    
    // Pool addresses
    address constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address constant CBBTC_USDC_POOL = 0x4e962BB3889Bf030368F56810A9c96B83CB3E778;
    address constant CBBTC_LBTC_POOL = 0xA44D3Bb767d953711EA4Bce8C0F01f4d7D299aF6;
    
    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        // Deploy new instance of LiquidityManager with zero address for wallet registry (testing)
        liquidityManager = new LiquidityManager(address(0));
        // Make the contract persistent across pranks
        vm.makePersistent(address(liquidityManager));
    }
    
    function testSimpleWETHUSDC() public {
        console.log("=== Test 1: Simple WETH/USDC Pool ===");
        
        address user = makeAddr("user");
        deal(USDC, user, 100e6);
        vm.deal(user, 1 ether);
        
        vm.startPrank(user);
        IERC20(USDC).approve(address(liquidityManager), 10e6);
        
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        // Empty routes - should use target pool for WETH swap
        LiquidityManager.SwapRoute memory emptyRoute = LiquidityManager.SwapRoute({
            pools: new address[](0),
            tokens: new address[](0),
            tickSpacings: new int24[](0)
        });
        
        LiquidityManager.PositionParams memory params = LiquidityManager.PositionParams({
            pool: WETH_USDC_POOL,
            tickLower: ((currentTick - 500) / tickSpacing) * tickSpacing,
            tickUpper: ((currentTick + 500) / tickSpacing) * tickSpacing,
            deadline: block.timestamp + 300,
            usdcAmount: 10e6,
            slippageBps: 500,
            stake: false,
            token0Route: emptyRoute,
            token1Route: emptyRoute
        });
        
        try liquidityManager.createPosition(params) returns (uint256 tokenId, uint128 liquidity) {
            console.log("  SUCCESS! TokenId:", tokenId, "Liquidity:", liquidity);
        } catch Error(string memory reason) {
            console.log("  FAILED:", reason);
        }
        
        vm.stopPrank();
    }
    
    function testSequentialCbBTCLBTC() public {
        console.log("\n=== Test 2: Sequential cbBTC/LBTC Pool ===");
        
        address user = makeAddr("user");
        deal(USDC, user, 100e6);
        vm.deal(user, 1 ether);
        
        vm.startPrank(user);
        IERC20(USDC).approve(address(liquidityManager), 20e6);
        
        ICLPool targetPool = ICLPool(CBBTC_LBTC_POOL);
        address token0 = targetPool.token0();
        address token1 = targetPool.token1();
        (, int24 currentTick,,,,) = targetPool.slot0();
        int24 tickSpacing = targetPool.tickSpacing();
        
        console.log("  Token0:", token0 == CBBTC ? "cbBTC" : "LBTC");
        console.log("  Token1:", token1 == CBBTC ? "cbBTC" : "LBTC");
        
        // Route for token0 (cbBTC): USDC -> cbBTC
        LiquidityManager.SwapRoute memory token0Route = LiquidityManager.SwapRoute({
            pools: new address[](1),
            tokens: new address[](2),
            tickSpacings: new int24[](1)
        });
        token0Route.pools[0] = CBBTC_USDC_POOL;
        token0Route.tokens[0] = USDC;
        token0Route.tokens[1] = CBBTC;
        token0Route.tickSpacings[0] = ICLPool(CBBTC_USDC_POOL).tickSpacing();
        
        // Route for token1 (LBTC): cbBTC -> LBTC (using cbBTC as intermediate)
        LiquidityManager.SwapRoute memory token1Route = LiquidityManager.SwapRoute({
            pools: new address[](1),
            tokens: new address[](2),
            tickSpacings: new int24[](1)
        });
        token1Route.pools[0] = CBBTC_LBTC_POOL;
        token1Route.tokens[0] = CBBTC;  // Start with cbBTC!
        token1Route.tokens[1] = LBTC;
        token1Route.tickSpacings[0] = tickSpacing;
        
        LiquidityManager.PositionParams memory params = LiquidityManager.PositionParams({
            pool: CBBTC_LBTC_POOL,
            tickLower: ((currentTick - 200) / tickSpacing) * tickSpacing,
            tickUpper: ((currentTick + 200) / tickSpacing) * tickSpacing,
            deadline: block.timestamp + 300,
            usdcAmount: 20e6,
            slippageBps: 1000, // 10% for testing
            stake: false,
            token0Route: token0Route,
            token1Route: token1Route
        });
        
        console.log("  Testing sequential routing...");
        console.log("  Step 1: USDC -> cbBTC (all)");
        console.log("  Step 2: cbBTC -> LBTC (portion)");
        
        try liquidityManager.createPosition(params) returns (uint256 tokenId, uint128 liquidity) {
            console.log("  SUCCESS! TokenId:", tokenId, "Liquidity:", liquidity);
        } catch Error(string memory reason) {
            console.log("  FAILED:", reason);
        }
        
        vm.stopPrank();
    }
}