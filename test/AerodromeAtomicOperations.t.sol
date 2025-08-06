// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/AerodromeAtomicOperations.sol";
import "../contracts/CDPWalletRegistry.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/ICLPool.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IVoter.sol";

contract AerodromeAtomicOperationsTest is Test {
    AerodromeAtomicOperations public atomicOps;
    CDPWalletRegistry public registry;
    
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address constant POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    
    // cbBTC/LBTC pool and tokens
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;  // cbBTC
    address constant LBTC = 0xecAc9C5F704e954931349Da37F60E39f515c11c1;   // LBTC (correct address from pool)
    address constant USDC_CBBTC_POOL = 0x4e962BB3889Bf030368F56810A9c96B83CB3E778;  // USDC/cbBTC pool
    address constant CBBTC_LBTC_POOL = 0xA44D3Bb767d953711EA4Bce8C0F01f4d7D299aF6;  // cbBTC/LBTC pool
    
    address user = address(0x1234);
    uint256 baseMainnetFork;
    
    function setUp() public {
        // Fork Base mainnet
        baseMainnetFork = vm.createFork(vm.envString("BASE_RPC_URL"));
        vm.selectFork(baseMainnetFork);
        
        // Deploy contracts
        registry = new CDPWalletRegistry();
        atomicOps = new AerodromeAtomicOperations(address(registry));
        
        // Setup user with USDC
        deal(USDC, user, 1000e6); // 1000 USDC
        
        // Approve atomic ops contract
        vm.startPrank(user);
        IERC20(USDC).approve(address(atomicOps), type(uint256).max);
        vm.stopPrank();
    }
    
    function testOraclePricing() public view {
        // Test oracle integration
        uint256 wethPrice = atomicOps.getTokenPriceViaOracle(WETH);
        console.log("WETH price raw from oracle:", wethPrice);
        
        // The oracle returns price with different decimals
        // WETH has 18 decimals, USDC has 6 decimals
        // Price should be around 3500 USDC (without decimals adjustment)
        // So raw value should be around 3500e6 = 3500000000
        assertGt(wethPrice, 1000e6); // > $1000
        assertLt(wethPrice, 10000e6); // < $10000
    }
    
    function testCalculateOptimalAllocation() public view {
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        
        // Get current tick
        (,int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        // Create a range around current price
        int24 tickLower = ((currentTick - 1000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 1000) / tickSpacing) * tickSpacing;
        
        // Test allocation calculation
        (uint256 usdc0, uint256 usdc1) = atomicOps.calculateOptimalUSDCAllocation(
            1000e6, // 1000 USDC
            pool.token0(),
            pool.token1(),
            tickLower,
            tickUpper,
            pool
        );
        
        console.log("USDC for token0:", usdc0);
        console.log("USDC for token1:", usdc1);
        
        // Should sum to total
        assertEq(usdc0 + usdc1, 1000e6);
        
        // Should have non-zero allocation for in-range position
        if (currentTick >= tickLower && currentTick < tickUpper) {
            assertGt(usdc0, 0);
            assertGt(usdc1, 0);
        }
    }
    
    function testSwapMintAndStake() public {
        vm.startPrank(user);
        
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        (,int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        // Create range around current price
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 100e6, // 100 USDC
            slippageBps: 100, // 1% slippage
            stake: false, // Don't stake for this test
            token0Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            }),
            token1Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            })
        });
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapMintAndStake(params);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);
        
        console.log("Position minted with tokenId:", tokenId);
        console.log("Liquidity:", liquidity);
        console.log("USDC spent:", usdcBefore - usdcAfter);
        
        // Verify position was created
        assertGt(tokenId, 0);
        assertGt(liquidity, 0);
        
        // Verify user owns the position
        assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId), user);
        
        vm.stopPrank();
    }
    
    function testSwapMintAndStakeWithStaking() public {
        vm.startPrank(user);
        
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        (,int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        // Create range around current price
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 100e6, // 100 USDC
            slippageBps: 100, // 1% slippage
            stake: true, // ENABLE STAKING
            token0Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            }),
            token1Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            })
        });
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapMintAndStake(params);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);
        
        console.log("Position minted and staked with tokenId:", tokenId);
        console.log("Liquidity:", liquidity);
        console.log("USDC spent:", usdcBefore - usdcAfter);
        
        // Verify position was created
        assertGt(tokenId, 0);
        assertGt(liquidity, 0);
        
        // Check if gauge exists for this pool
        address voter = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
        address gauge = IVoter(voter).gauges(WETH_USDC_POOL);
        console.log("Gauge address:", gauge);
        
        if (gauge != address(0)) {
            // Verify the gauge owns the position (not the user)
            assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId), gauge);
            console.log("Position successfully staked in gauge");
            
            // Check if position is in gauge
            // Note: We might need to check gauge's staked positions
        } else {
            // If no gauge, position should be returned to user
            assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId), user);
            console.log("No gauge found, position returned to user");
        }
        
        vm.stopPrank();
    }
    
    function testFullExitWithStakedPosition() public {
        // First create and stake a position
        vm.startPrank(user);
        
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        (,int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        // Mint and stake position
        AerodromeAtomicOperations.SwapMintParams memory mintParams = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 100e6,
            slippageBps: 100,
            stake: true, // STAKE THE POSITION
            token0Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            }),
            token1Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            })
        });
        
        (uint256 tokenId,) = atomicOps.swapMintAndStake(mintParams);
        console.log("Staked position created with tokenId:", tokenId);
        
        // Verify gauge owns the position
        address gauge = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5).gauges(WETH_USDC_POOL);
        if (gauge != address(0)) {
            assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId), gauge);
            console.log("Position is staked in gauge:", gauge);
        }
        
        // Now exit the staked position
        AerodromeAtomicOperations.FullExitParams memory exitParams = AerodromeAtomicOperations.FullExitParams({
            tokenId: tokenId,
            pool: WETH_USDC_POOL,
            deadline: block.timestamp + 3600,
            minUsdcOut: 90e6, // Accept 10% slippage for test
            slippageBps: 200, // 2% slippage
            token0Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            }),
            token1Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            })
        });
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        uint256 aeroBefore = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631).balanceOf(user); // AERO token
        
        (uint256 usdcOut, uint256 aeroRewards) = atomicOps.fullExit(exitParams);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);
        uint256 aeroAfter = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631).balanceOf(user);
        
        console.log("USDC recovered:", usdcOut);
        console.log("AERO rewards collected:", aeroRewards);
        console.log("Actual USDC received:", usdcAfter - usdcBefore);
        console.log("Actual AERO received:", aeroAfter - aeroBefore);
        
        // Verify we got back close to what we put in (minus fees/slippage)
        assertGt(usdcOut, 0);
        assertEq(usdcAfter - usdcBefore, usdcOut);
        
        // AERO rewards might be 0 if position was just created
        if (aeroRewards > 0) {
            assertEq(aeroAfter - aeroBefore, aeroRewards);
        }
        
        vm.stopPrank();
    }
    
    function testCbBTC_LBTC_PoolWithSmartRouting() public {
        vm.startPrank(user);
        
        // Get pool info
        ICLPool pool = ICLPool(CBBTC_LBTC_POOL);
        (,int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        console.log("cbBTC/LBTC Pool:");
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Current tick:", currentTick);
        console.log("Tick spacing:", tickSpacing);
        
        // Determine which token is which
        bool cbbtcIsToken0 = (token0 == CBBTC);
        console.log("cbBTC is token0:", cbbtcIsToken0);
        
        // Create range around current price
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        // Get tick spacing for USDC/cbBTC pool
        ICLPool usdcCbbtcPool = ICLPool(USDC_CBBTC_POOL);
        int24 usdcCbbtcTickSpacing = usdcCbbtcPool.tickSpacing();
        console.log("USDC/cbBTC pool tick spacing:", usdcCbbtcTickSpacing);
        
        // Build smart routes:
        // Route 1: USDC -> cbBTC (direct, for cbBTC position)
        // Route 2: USDC -> cbBTC -> LBTC (multihop, for LBTC position)
        
        // Create route arrays
        address[] memory token0Pools;
        address[] memory token0Tokens;
        int24[] memory token0TickSpacings;
        
        address[] memory token1Pools;
        address[] memory token1Tokens;
        int24[] memory token1TickSpacings;
        
        if (cbbtcIsToken0) {
            // Token0 is cbBTC: USDC -> cbBTC (direct)
            token0Pools = new address[](1);
            token0Pools[0] = USDC_CBBTC_POOL;
            
            token0Tokens = new address[](2);
            token0Tokens[0] = USDC;
            token0Tokens[1] = CBBTC;
            
            token0TickSpacings = new int24[](1);
            token0TickSpacings[0] = usdcCbbtcTickSpacing;
            
            // Token1 is LBTC: USDC -> cbBTC -> LBTC (multihop)
            token1Pools = new address[](2);
            token1Pools[0] = USDC_CBBTC_POOL;
            token1Pools[1] = CBBTC_LBTC_POOL;
            
            token1Tokens = new address[](3);
            token1Tokens[0] = USDC;
            token1Tokens[1] = CBBTC;
            token1Tokens[2] = LBTC;
            
            token1TickSpacings = new int24[](2);
            token1TickSpacings[0] = usdcCbbtcTickSpacing;
            token1TickSpacings[1] = tickSpacing;
        } else {
            // Token0 is LBTC: USDC -> cbBTC -> LBTC (multihop)
            token0Pools = new address[](2);
            token0Pools[0] = USDC_CBBTC_POOL;
            token0Pools[1] = CBBTC_LBTC_POOL;
            
            token0Tokens = new address[](3);
            token0Tokens[0] = USDC;
            token0Tokens[1] = CBBTC;
            token0Tokens[2] = LBTC;
            
            token0TickSpacings = new int24[](2);
            token0TickSpacings[0] = usdcCbbtcTickSpacing;
            token0TickSpacings[1] = tickSpacing;
            
            // Token1 is cbBTC: USDC -> cbBTC (direct)
            token1Pools = new address[](1);
            token1Pools[0] = USDC_CBBTC_POOL;
            
            token1Tokens = new address[](2);
            token1Tokens[0] = USDC;
            token1Tokens[1] = CBBTC;
            
            token1TickSpacings = new int24[](1);
            token1TickSpacings[0] = usdcCbbtcTickSpacing;
        }
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: CBBTC_LBTC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 100e6, // 100 USDC
            slippageBps: 300, // 3% slippage for BTC pairs
            stake: false, // Don't stake for this test
            token0Route: AerodromeAtomicOperations.SwapRoute({
                pools: token0Pools,
                tokens: token0Tokens,
                tickSpacings: token0TickSpacings
            }),
            token1Route: AerodromeAtomicOperations.SwapRoute({
                pools: token1Pools,
                tokens: token1Tokens,
                tickSpacings: token1TickSpacings
            })
        });
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        
        console.log("\n=== Executing Smart Routing ===");
        console.log("Total USDC input: 100 USDC");
        console.log("Route for token0:", cbbtcIsToken0 ? "USDC -> cbBTC (direct)" : "USDC -> cbBTC -> LBTC (multihop)");
        console.log("Route for token1:", cbbtcIsToken0 ? "USDC -> cbBTC -> LBTC (multihop)" : "USDC -> cbBTC (direct)");
        console.log("Total swaps needed: 2 (smart routing through cbBTC)");
        
        (uint256 tokenId, uint128 liquidity) = atomicOps.swapMintAndStake(params);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);
        
        console.log("\n=== Results ===");
        console.log("Position minted with tokenId:", tokenId);
        console.log("Liquidity:", liquidity);
        console.log("USDC spent:", usdcBefore - usdcAfter);
        
        // Verify position was created
        assertGt(tokenId, 0);
        assertGt(liquidity, 0);
        
        // Verify user owns the position (not staked)
        assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId), user);
        
        // Get position details
        (,, address posToken0, address posToken1,,,, uint128 posLiquidity,,,,) = 
            INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);
        
        console.log("\n=== Position Details ===");
        console.log("Position token0:", posToken0);
        console.log("Position token1:", posToken1);
        console.log("Position liquidity:", posLiquidity);
        
        vm.stopPrank();
    }
    
    function testFullExit() public {
        // First create a position
        vm.startPrank(user);
        
        ICLPool pool = ICLPool(WETH_USDC_POOL);
        (,int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        int24 tickLower = ((currentTick - 500) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + 500) / tickSpacing) * tickSpacing;
        
        AerodromeAtomicOperations.SwapMintParams memory mintParams = AerodromeAtomicOperations.SwapMintParams({
            pool: WETH_USDC_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: block.timestamp + 3600,
            usdcAmount: 100e6,
            slippageBps: 100,
            stake: false,
            token0Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            }),
            token1Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            })
        });
        
        (uint256 tokenId,) = atomicOps.swapMintAndStake(mintParams);
        
        // Approve position for exit
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(atomicOps), tokenId);
        
        // Now exit the position
        AerodromeAtomicOperations.FullExitParams memory exitParams = AerodromeAtomicOperations.FullExitParams({
            tokenId: tokenId,
            pool: WETH_USDC_POOL,
            deadline: block.timestamp + 3600,
            minUsdcOut: 90e6, // Accept 10% slippage for test
            slippageBps: 200, // 2% slippage
            token0Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            }),
            token1Route: AerodromeAtomicOperations.SwapRoute({
                pools: new address[](0),
                tokens: new address[](0),
                tickSpacings: new int24[](0)
            })
        });
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        
        (uint256 usdcOut, uint256 aeroRewards) = atomicOps.fullExit(exitParams);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);
        
        console.log("USDC recovered:", usdcOut);
        console.log("AERO rewards:", aeroRewards);
        console.log("Total USDC after exit:", usdcAfter);
        
        // Should recover at least minUsdcOut
        assertGe(usdcOut, 90e6);
        assertEq(usdcAfter - usdcBefore, usdcOut);
        
        vm.stopPrank();
    }
}