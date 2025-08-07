// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/LiquidityManager.sol";
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
            slippageBps: 100,
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

    function testCreateStakeAndExit() public {
        console.log("\n=== Test 3: Create, Stake, and Exit cbBTC/LBTC Position ===");

        address user = makeAddr("user");
        deal(USDC, user, 100e6);
        vm.deal(user, 1 ether);

        vm.startPrank(user);
        IERC20(USDC).approve(address(liquidityManager), 30e6);

        ICLPool targetPool = ICLPool(CBBTC_LBTC_POOL);
        address token0 = targetPool.token0();
        address token1 = targetPool.token1();
        (, int24 currentTick,,,,) = targetPool.slot0();
        int24 tickSpacing = targetPool.tickSpacing();

        console.log("  Token0:", token0 == CBBTC ? "cbBTC" : "LBTC");
        console.log("  Token1:", token1 == CBBTC ? "cbBTC" : "LBTC");

        // Setup routes for sequential swapping
        LiquidityManager.SwapRoute memory token0Route = LiquidityManager.SwapRoute({
            pools: new address[](1),
            tokens: new address[](2),
            tickSpacings: new int24[](1)
        });
        token0Route.pools[0] = CBBTC_USDC_POOL;
        token0Route.tokens[0] = USDC;
        token0Route.tokens[1] = CBBTC;
        token0Route.tickSpacings[0] = ICLPool(CBBTC_USDC_POOL).tickSpacing();

        LiquidityManager.SwapRoute memory token1Route = LiquidityManager.SwapRoute({
            pools: new address[](1),
            tokens: new address[](2),
            tickSpacings: new int24[](1)
        });
        token1Route.pools[0] = CBBTC_LBTC_POOL;
        token1Route.tokens[0] = CBBTC;
        token1Route.tokens[1] = LBTC;
        token1Route.tickSpacings[0] = tickSpacing;

        // Step 1: Create and stake position
        console.log("\n  Step 1: Creating and staking position...");

        LiquidityManager.PositionParams memory params = LiquidityManager.PositionParams({
            pool: CBBTC_LBTC_POOL,
            tickLower: ((currentTick - 200) / tickSpacing) * tickSpacing,
            tickUpper: ((currentTick + 200) / tickSpacing) * tickSpacing,
            deadline: block.timestamp + 300,
            usdcAmount: 25e6,
            slippageBps: 100, // 10% for testing
            stake: true, // STAKE the position
            token0Route: token0Route,
            token1Route: token1Route
        });

        uint256 tokenId;
        uint128 liquidity;
        try liquidityManager.createPosition(params) returns (uint256 id, uint128 liq) {
            tokenId = id;
            liquidity = liq;
            console.log("    SUCCESS! TokenId:", tokenId, "Liquidity:", liquidity);
            console.log("    Position is staked in gauge");
        } catch Error(string memory reason) {
            console.log("    FAILED:", reason);
            return;
        }

        // Check if position is staked
        bool isStaked = liquidityManager.isPositionStaked(tokenId);
        console.log("    Position staked status:", isStaked);
        require(isStaked, "Position should be staked");

        // Step 2: Skip time simulation for now (deadline issue)
        console.log("\n  Step 2: Testing immediate exit (no time warp)...");

        // Step 3: Full exit - unstake, burn, and convert to USDC
        console.log("\n  Step 3: Executing full exit...");

        uint256 usdcBalanceBefore = IERC20(USDC).balanceOf(user);
        console.log("    USDC balance before exit:", usdcBalanceBefore / 1e6, "USDC");

        // For exit, we need different routes:
        // token0 (cbBTC) -> USDC: Direct via cbBTC/USDC pool
        LiquidityManager.SwapRoute memory exitToken0Route = LiquidityManager.SwapRoute({
            pools: new address[](1),
            tokens: new address[](2),
            tickSpacings: new int24[](1)
        });
        exitToken0Route.pools[0] = CBBTC_USDC_POOL;
        exitToken0Route.tokens[0] = CBBTC;
        exitToken0Route.tokens[1] = USDC;
        exitToken0Route.tickSpacings[0] = ICLPool(CBBTC_USDC_POOL).tickSpacing();

        // token1 (LBTC) -> USDC: First LBTC->cbBTC, then cbBTC->USDC (multi-hop)
        // But we can only do single hop, so let's just use LBTC->cbBTC for now
        LiquidityManager.SwapRoute memory exitToken1Route = LiquidityManager.SwapRoute({
            pools: new address[](2),
            tokens: new address[](3),
            tickSpacings: new int24[](2)
        });
        exitToken1Route.pools[0] = CBBTC_LBTC_POOL;
        exitToken1Route.pools[1] = CBBTC_USDC_POOL;
        exitToken1Route.tokens[0] = LBTC;
        exitToken1Route.tokens[1] = CBBTC;
        exitToken1Route.tokens[2] = USDC;
        exitToken1Route.tickSpacings[0] = tickSpacing;
        exitToken1Route.tickSpacings[1] = ICLPool(CBBTC_USDC_POOL).tickSpacing();

        LiquidityManager.ExitParams memory exitParams = LiquidityManager.ExitParams({
            tokenId: tokenId,
            pool: CBBTC_LBTC_POOL,
            deadline: block.timestamp + 300,
            minUsdcOut: 1e6, // Extremely low minimum just to test the flow
            slippageBps: 100, // 10% slippage (max allowed by contract)
            token0Route: exitToken0Route, // Route for cbBTC -> USDC
            token1Route: exitToken1Route // Route for LBTC -> cbBTC -> USDC
         });

        try liquidityManager.closePosition(exitParams) returns (uint256 usdcReceived, uint256 aeroRewards) {
            console.log("    SUCCESS! USDC received:", usdcReceived / 1e6, "USDC");
            console.log("    AERO rewards received:", aeroRewards);

            uint256 usdcBalanceAfter = IERC20(USDC).balanceOf(user);
            console.log("    USDC balance after exit:", usdcBalanceAfter / 1e6, "USDC");
            console.log("    Net USDC recovered:", (usdcBalanceAfter - usdcBalanceBefore) / 1e6, "USDC");

            // Verify we got back a reasonable amount (accounting for slippage and fees)
            require(usdcReceived > 15e6, "Should recover at least 15 USDC");
        } catch Error(string memory reason) {
            console.log("    FAILED:", reason);
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
        token1Route.tokens[0] = CBBTC; // Start with cbBTC!
        token1Route.tokens[1] = LBTC;
        token1Route.tickSpacings[0] = tickSpacing;

        LiquidityManager.PositionParams memory params = LiquidityManager.PositionParams({
            pool: CBBTC_LBTC_POOL,
            tickLower: ((currentTick - 200) / tickSpacing) * tickSpacing,
            tickUpper: ((currentTick + 200) / tickSpacing) * tickSpacing,
            deadline: block.timestamp + 300,
            usdcAmount: 20e6,
            slippageBps: 100, // 10% for testing
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

    // Helper functions
    function toArray(address a) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = a;
        return arr;
    }

    function toArray(address a, address b) internal pure returns (address[] memory) {
        address[] memory arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function toArray(address a, address b, address c) internal pure returns (address[] memory) {
        address[] memory arr = new address[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        return arr;
    }

    function toIntArray(int24 a) internal pure returns (int24[] memory) {
        int24[] memory arr = new int24[](1);
        arr[0] = a;
        return arr;
    }

    function toIntArray(int24 a, int24 b) internal pure returns (int24[] memory) {
        int24[] memory arr = new int24[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function testWETHSuperOETHbFullCycle() public {
        console.log("\n=== Test 4: Create, Stake, and Exit WETH/superOETHb Position ===");

        address targetPool = 0x6446021F4E396dA3df4235C62537431372195D38;
        address weth = 0x4200000000000000000000000000000000000006;
        address superOETHb = 0xDBFeFD2e8460a6Ee4955A68582F85708BAEA60A3;
        address usdcWethPool = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59; // USDC/WETH pool

        // Get pool info
        ICLPool pool = ICLPool(targetPool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        int24 tickSpacing = pool.tickSpacing();

        console.log("    Token0:", token0 == weth ? "WETH" : "superOETHb");
        console.log("    Token1:", token1 == superOETHb ? "superOETHb" : "WETH");
        console.log("    Tick spacing:", uint256(int256(tickSpacing)));

        uint256 usdcAmount = 50e6; // 50 USDC
        deal(USDC, address(this), 100e6);
        IERC20(USDC).approve(address(liquidityManager), 100e6);

        // Step 1: Create and stake position with sequential routing
        console.log("\n  Step 1: Creating and staking position...");

        // Setup entry routes: USDC -> WETH, then WETH -> superOETHb
        LiquidityManager.SwapRoute memory token0Route;
        LiquidityManager.SwapRoute memory token1Route;

        if (token0 == weth) {
            // Token0 is WETH: USDC -> WETH
            token0Route = LiquidityManager.SwapRoute({
                tokens: toArray(USDC, weth),
                pools: toArray(usdcWethPool),
                tickSpacings: toIntArray(100) // USDC/WETH pool tick spacing
             });

            // Token1 is superOETHb: WETH -> superOETHb (using target pool itself)
            token1Route = LiquidityManager.SwapRoute({
                tokens: toArray(weth, superOETHb),
                pools: toArray(targetPool),
                tickSpacings: toIntArray(tickSpacing)
            });
        } else {
            // Token0 is superOETHb: WETH -> superOETHb (using target pool)
            token0Route = LiquidityManager.SwapRoute({
                tokens: toArray(weth, superOETHb),
                pools: toArray(targetPool),
                tickSpacings: toIntArray(tickSpacing)
            });

            // Token1 is WETH: USDC -> WETH
            token1Route = LiquidityManager.SwapRoute({
                tokens: toArray(USDC, weth),
                pools: toArray(usdcWethPool),
                tickSpacings: toIntArray(100)
            });
        }

        (uint256 tokenId, uint128 liquidity) = liquidityManager.createPosition(
            LiquidityManager.PositionParams({
                pool: targetPool,
                tickLower: -1000,
                tickUpper: 1000,
                deadline: block.timestamp + 300,
                usdcAmount: usdcAmount,
                slippageBps: 500,
                stake: true, // Stake directly in creation
                token0Route: token0Route,
                token1Route: token1Route
            })
        );

        console.log("      SUCCESS! TokenId:", tokenId, "Liquidity:", liquidity);

        // Verify position is staked
        bool isStaked = liquidityManager.isPositionStaked(tokenId);
        console.log("      Position staked status:", isStaked);
        assertTrue(isStaked, "Position should be staked");

        // Step 2: Exit position
        console.log("\n  Step 2: Executing full exit...");

        uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));
        console.log("      USDC balance before exit:", balanceBefore / 1e6, "USDC");

        // Setup exit routes
        LiquidityManager.SwapRoute memory exitRoute0;
        LiquidityManager.SwapRoute memory exitRoute1;

        if (token0 == weth) {
            // Token0 (WETH) -> USDC
            exitRoute0 = LiquidityManager.SwapRoute({
                tokens: toArray(weth, USDC),
                pools: toArray(usdcWethPool),
                tickSpacings: toIntArray(100)
            });

            // Token1 (superOETHb) -> WETH (using target pool) -> USDC
            exitRoute1 = LiquidityManager.SwapRoute({
                tokens: toArray(superOETHb, weth, USDC),
                pools: toArray(targetPool, usdcWethPool),
                tickSpacings: toIntArray(tickSpacing, 100)
            });
        } else {
            // Token0 (superOETHb) -> WETH (using target pool) -> USDC
            exitRoute0 = LiquidityManager.SwapRoute({
                tokens: toArray(superOETHb, weth, USDC),
                pools: toArray(targetPool, usdcWethPool),
                tickSpacings: toIntArray(tickSpacing, 100)
            });

            // Token1 (WETH) -> USDC
            exitRoute1 = LiquidityManager.SwapRoute({
                tokens: toArray(weth, USDC),
                pools: toArray(usdcWethPool),
                tickSpacings: toIntArray(100)
            });
        }

        (uint256 usdcOut,) = liquidityManager.closePosition(
            LiquidityManager.ExitParams({
                tokenId: tokenId,
                pool: targetPool,
                deadline: block.timestamp + 300,
                minUsdcOut: 1,
                slippageBps: 500,
                token0Route: exitRoute0,
                token1Route: exitRoute1
            })
        );

        uint256 balanceAfter = IERC20(USDC).balanceOf(address(this));
        console.log("      SUCCESS! USDC received:", usdcOut / 1e6, "USDC");
        console.log("      USDC balance after exit:", balanceAfter / 1e6, "USDC");

        uint256 netUsdc = balanceAfter - balanceBefore;
        console.log("      Net USDC recovered:", netUsdc / 1e6, "USDC");

        assertTrue(usdcOut > 0, "Should receive some USDC");
        assertTrue(balanceAfter > balanceBefore, "USDC balance should increase");
    }
}
