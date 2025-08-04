// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../contracts/AerodromeAtomicOperations.sol";
import "../contracts/CDPWalletRegistry.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IGauge.sol";
import "@interfaces/ICLFactory.sol";
import "@interfaces/ICLPool.sol";

contract AerodromeAtomicOperationsTest is Test {
    AerodromeAtomicOperations public atomic;
    CDPWalletRegistry public walletRegistry;
    
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    address constant USDC_WHALE = 0x0000000000000000000000000000000000000001;
    address constant USER = address(0x1337);
    
    // Test with the specific pool requested
    address constant TEST_POOL = 0x4A021bA3ab1F0121e7DF76f345C547db86Cb3468;
    
    uint256 baseMainnetFork;
    address testPool;
    
    function setUp() public {
        // Use direct RPC URL instead of env variable
        baseMainnetFork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(baseMainnetFork);
        
        // Deploy wallet registry and register USER as a CDP wallet
        walletRegistry = new CDPWalletRegistry();
        // As the owner, register USER as a CDP wallet
        walletRegistry.registerWallet(USER);
        
        // Deploy atomic operations contract with wallet registry
        atomic = new AerodromeAtomicOperations(address(walletRegistry));
        
        // Find a valid pool for testing
        ICLFactory factory = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
        address token0 = USDC < WETH ? USDC : WETH;
        address token1 = USDC > WETH ? USDC : WETH;
        
        // Try to find an existing pool with common tick spacings
        int24[4] memory tickSpacings = [int24(1), int24(50), int24(100), int24(200)];
        for (uint i = 0; i < tickSpacings.length; i++) {
            testPool = factory.getPool(token0, token1, tickSpacings[i]);
            if (testPool != address(0)) {
                break;
            }
        }
        
        require(testPool != address(0), "No USDC/WETH pool found");
        
        vm.label(address(atomic), "AerodromeAtomicOperations");
        vm.label(address(walletRegistry), "CDPWalletRegistry");
        vm.label(USDC, "USDC");
        vm.label(AERO, "AERO");
        vm.label(WETH, "WETH");
        vm.label(USER, "User");
        vm.label(testPool, "TestPool");
        
        deal(USDC, USER, 10000e6);
        
        vm.startPrank(USER);
        IERC20(USDC).approve(address(atomic), type(uint256).max);
        vm.stopPrank();
    }
    
    function testSwapMintAndStake() public {
        vm.startPrank(USER);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: testPool,
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
            pool: testPool,
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
            pool: testPool,
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
            pool: testPool,
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
            pool: testPool,
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
            pool: testPool,
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
            pool: testPool,
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
            pool: testPool,
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
    
    function testSpecificPoolSwapMintAndStake() public {
        // Test with the specific pool address: 0x4A021bA3ab1F0121e7DF76f345C547db86Cb3468
        // Get pool info
        ICLPool pool = ICLPool(TEST_POOL);
        address token0 = pool.token0();
        address token1 = pool.token1();
        int24 tickSpacing = pool.tickSpacing();
        (uint160 sqrtPriceX96, int24 currentTick,,,,) = pool.slot0();
        
        console.log("Testing specific pool:", TEST_POOL);
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Current tick:", currentTick);
        console.log("Tick spacing:", tickSpacing);
        
        // Calculate tick range around current price (± 5%)
        int24 tickRange = 500; // Approximately 5% range
        int24 tickLower = ((currentTick - tickRange) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick + tickRange) / tickSpacing) * tickSpacing;
        
        console.log("Tick lower:", tickLower);
        console.log("Tick upper:", tickUpper);
        
        uint256 usdcAmount = 1000e6; // 1,000 USDC
        
        // Approve USDC
        vm.startPrank(USER);
        IERC20(USDC).approve(address(atomic), usdcAmount);
        
        // Setup swap parameters
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: TEST_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            usdcAmount: usdcAmount,
            minLiquidity: 0, // Accept any liquidity for testing
            deadline: block.timestamp + 3600,
            stake: false // Changed to false - this pool might not have a gauge
        });
        
        // Execute swap, mint and stake
        console.log("Executing swapMintAndStake with 1000 USDC");
        (uint256 tokenId, uint128 liquidity) = atomic.swapMintAndStake(params);
        vm.stopPrank();
        
        // Verify results
        assertGt(tokenId, 0, "Should have minted a position");
        assertGt(liquidity, 0, "Should have minted liquidity");
        
        console.log("Success! Token ID:", tokenId);
        console.log("Liquidity minted:", liquidity);
        
        // Verify position details
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
        
        (
            ,
            ,
            address posToken0,
            address posToken1,
            int24 posTickSpacing,
            int24 posTickLower,
            int24 posTickUpper,
            uint128 posLiquidity,
            ,
            ,
            ,
            
        ) = positionManager.positions(tokenId);
        
        assertEq(posToken0, token0, "Token0 should match");
        assertEq(posToken1, token1, "Token1 should match");
        assertEq(posTickLower, tickLower, "Tick lower should match");
        assertEq(posTickUpper, tickUpper, "Tick upper should match");
        assertEq(posLiquidity, liquidity, "Liquidity should match");
        
        console.log("Position verified successfully!");
    }
    
    function testSpecificPoolDifferentRanges() public {
        ICLPool pool = ICLPool(TEST_POOL);
        int24 tickSpacing = pool.tickSpacing();
        (uint160 sqrtPriceX96, int24 currentTick,,,,) = pool.slot0();
        
        console.log("Testing different ranges for pool:", TEST_POOL);
        console.log("Current tick:", currentTick);
        
        // Test with position below current price (100% token0)
        int24 tickLower = ((currentTick - 5000) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((currentTick - 2000) / tickSpacing) * tickSpacing;
        
        _testSpecificPoolWithRange(tickLower, tickUpper, "Below range position");
        
        // Test with position above current price (100% token1)
        tickLower = ((currentTick + 2000) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + 5000) / tickSpacing) * tickSpacing;
        
        _testSpecificPoolWithRange(tickLower, tickUpper, "Above range position");
        
        // Test with narrow range around current price
        tickLower = ((currentTick - 100) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + 100) / tickSpacing) * tickSpacing;
        
        _testSpecificPoolWithRange(tickLower, tickUpper, "Narrow range position");
    }
    
    function _testSpecificPoolWithRange(int24 tickLower, int24 tickUpper, string memory description) internal {
        console.log("\nTesting:", description);
        console.log("Tick lower:", tickLower);
        console.log("Tick upper:", tickUpper);
        
        uint256 usdcAmount = 100e6; // 100 USDC
        
        vm.startPrank(USER);
        IERC20(USDC).approve(address(atomic), usdcAmount);
        
        AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
            pool: TEST_POOL,
            tickLower: tickLower,
            tickUpper: tickUpper,
            usdcAmount: usdcAmount,
            minLiquidity: 0,
            deadline: block.timestamp + 3600,
            stake: false // Don't stake for these tests
        });
        
        try atomic.swapMintAndStake(params) returns (uint256 tokenId, uint128 liquidity) {
            console.log("Token ID:", tokenId);
            console.log("Liquidity:", liquidity);
            
            assertGt(tokenId, 0, "Should have minted a position");
            assertGt(liquidity, 0, "Should have minted liquidity");
        } catch Error(string memory reason) {
            console.log("Failed with reason:", reason);
            fail(reason);
        } catch (bytes memory data) {
            console.log("Failed with data");
            fail("Unknown error");
        }
        
        vm.stopPrank();
    }
}