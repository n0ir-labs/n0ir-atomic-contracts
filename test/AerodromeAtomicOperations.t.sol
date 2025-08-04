// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../contracts/AerodromeAtomicOperations.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IGauge.sol";

contract AerodromeAtomicOperationsTest is Test {
    AerodromeAtomicOperations public atomic;
    
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    address constant USDC_WHALE = 0x0000000000000000000000000000000000000001;
    address constant USER = address(0x1337);
    
    uint256 baseMainnetFork;
    
    function setUp() public {
        string memory rpcUrl = vm.envString("BASE_RPC_URL");
        baseMainnetFork = vm.createFork(rpcUrl);
        vm.selectFork(baseMainnetFork);
        
        atomic = new AerodromeAtomicOperations();
        
        vm.label(address(atomic), "AerodromeAtomicOperations");
        vm.label(USDC, "USDC");
        vm.label(AERO, "AERO");
        vm.label(WETH, "WETH");
        vm.label(USER, "User");
        
        deal(USDC, USER, 10000e6);
        
        vm.startPrank(USER);
        IERC20(USDC).approve(address(atomic), type(uint256).max);
        vm.stopPrank();
    }
    
    function testSwapMintAndStake() public {
        vm.startPrank(USER);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            token0: USDC < WETH ? USDC : WETH,
            token1: USDC > WETH ? USDC : WETH,
            tickSpacing: 100,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 1000e6,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: true
        });
        
        uint256 balanceBefore = IERC20(USDC).balanceOf(USER);
        
        (uint256 tokenId, uint128 liquidity) = atomic.swapMintAndStake(params);
        
        assertGt(tokenId, 0, "Should receive valid tokenId");
        assertGt(liquidity, 0, "Should receive liquidity");
        assertEq(IERC20(USDC).balanceOf(USER), balanceBefore - 1000e6, "Should deduct USDC");
        
        vm.stopPrank();
    }
    
    function testSwapAndMintWithoutStaking() public {
        vm.startPrank(USER);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            token0: USDC < WETH ? USDC : WETH,
            token1: USDC > WETH ? USDC : WETH,
            tickSpacing: 100,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 1000e6,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: false
        });
        
        (uint256 tokenId, uint128 liquidity) = atomic.swapAndMint(params);
        
        assertGt(tokenId, 0, "Should receive valid tokenId");
        assertGt(liquidity, 0, "Should receive liquidity");
        
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
        assertEq(positionManager.ownerOf(tokenId), USER, "User should own the NFT");
        
        vm.stopPrank();
    }
    
    function testFullExit() public {
        vm.startPrank(USER);
        
        AerodromeAtomicOperations.SwapMintParams memory mintParams = AerodromeAtomicOperations.SwapMintParams({
            token0: USDC < WETH ? USDC : WETH,
            token1: USDC > WETH ? USDC : WETH,
            tickSpacing: 100,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 1000e6,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: false
        });
        
        (uint256 tokenId,) = atomic.swapAndMint(mintParams);
        
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
        positionManager.approve(address(atomic), tokenId);
        
        uint256 balanceBefore = IERC20(USDC).balanceOf(USER);
        
        AerodromeAtomicOperations.ExitParams memory exitParams = AerodromeAtomicOperations.ExitParams({
            tokenId: tokenId,
            minUsdcOut: 900e6,
            deadline: block.timestamp + 1 hours,
            swapToUsdc: true
        });
        
        (uint256 usdcOut,) = atomic.fullExit(exitParams);
        
        assertGt(usdcOut, 900e6, "Should receive at least minUsdcOut");
        assertEq(IERC20(USDC).balanceOf(USER), balanceBefore + usdcOut, "Should receive USDC");
        
        vm.expectRevert();
        positionManager.ownerOf(tokenId);
        
        vm.stopPrank();
    }
    
    function testRevertOnInvalidTickRange() public {
        vm.startPrank(USER);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            token0: USDC < WETH ? USDC : WETH,
            token1: USDC > WETH ? USDC : WETH,
            tickSpacing: 100,
            tickLower: 887200,
            tickUpper: -887200,
            usdcAmount: 1000e6,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: false
        });
        
        vm.expectRevert();
        atomic.swapMintAndStake(params);
        
        vm.stopPrank();
    }
    
    function testRevertOnExpiredDeadline() public {
        vm.startPrank(USER);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            token0: USDC < WETH ? USDC : WETH,
            token1: USDC > WETH ? USDC : WETH,
            tickSpacing: 100,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 1000e6,
            minLiquidity: 1,
            deadline: block.timestamp - 1,
            stake: false
        });
        
        vm.expectRevert();
        atomic.swapMintAndStake(params);
        
        vm.stopPrank();
    }
    
    function testRevertOnZeroAmount() public {
        vm.startPrank(USER);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            token0: USDC < WETH ? USDC : WETH,
            token1: USDC > WETH ? USDC : WETH,
            tickSpacing: 100,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 0,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: false
        });
        
        vm.expectRevert();
        atomic.swapMintAndStake(params);
        
        vm.stopPrank();
    }
    
    function testClaimAndSwap() public {
        vm.startPrank(USER);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            token0: USDC < WETH ? USDC : WETH,
            token1: USDC > WETH ? USDC : WETH,
            tickSpacing: 100,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: 1000e6,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: true
        });
        
        (uint256 tokenId,) = atomic.swapMintAndStake(params);
        
        vm.warp(block.timestamp + 7 days);
        
        uint256 balanceBefore = IERC20(USDC).balanceOf(USER);
        
        (uint256 aeroAmount, uint256 usdcReceived) = atomic.claimAndSwap(
            tokenId,
            0,
            block.timestamp + 1 hours
        );
        
        if (aeroAmount > 0) {
            assertGt(usdcReceived, 0, "Should receive USDC from AERO swap");
            assertEq(IERC20(USDC).balanceOf(USER), balanceBefore + usdcReceived, "USDC balance should increase");
        }
        
        vm.stopPrank();
    }
    
    function testFuzzSwapMintAmounts(uint256 amount) public {
        amount = bound(amount, 100e6, 10000e6);
        
        deal(USDC, USER, amount);
        
        vm.startPrank(USER);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            token0: USDC < WETH ? USDC : WETH,
            token1: USDC > WETH ? USDC : WETH,
            tickSpacing: 100,
            tickLower: -887200,
            tickUpper: 887200,
            usdcAmount: amount,
            minLiquidity: 1,
            deadline: block.timestamp + 1 hours,
            stake: false
        });
        
        (uint256 tokenId, uint128 liquidity) = atomic.swapAndMint(params);
        
        assertGt(tokenId, 0, "Should receive valid tokenId");
        assertGt(liquidity, 0, "Should receive liquidity");
        
        vm.stopPrank();
    }
}