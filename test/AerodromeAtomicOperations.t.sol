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