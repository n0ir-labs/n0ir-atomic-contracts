// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../contracts/LiquidityManager.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/ICLPool.sol";

contract StakedPositionsTest is Test {
    LiquidityManager liquidityManager;

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;

    address user1;
    address user2;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        liquidityManager = new LiquidityManager(address(0), address(0));
        vm.makePersistent(address(liquidityManager));

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Fund users with USDC
        deal(USDC, user1, 1000e6);
        deal(USDC, user2, 1000e6);
        vm.deal(user1, 1 ether);
        vm.deal(user2, 1 ether);
    }

    function testGetStakedPositionsEmpty() public view {
        // Test that a user with no positions returns empty array
        uint256[] memory positions = liquidityManager.getStakedPositions(user1);
        assertEq(positions.length, 0, "Should return empty array for user with no positions");
    }

    function testGetStakedPositionsSingleUser() public {
        vm.startPrank(user1);
        IERC20(USDC).approve(address(liquidityManager), 100e6);

        ICLPool pool = ICLPool(WETH_USDC_POOL);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        LiquidityManager.SwapRoute memory emptyRoute = LiquidityManager.SwapRoute({
            pools: new address[](0),
            tokens: new address[](0),
            tickSpacings: new int24[](0)
        });

        // Create first staked position
        LiquidityManager.PositionParams memory params1 = LiquidityManager.PositionParams({
            pool: WETH_USDC_POOL,
            token0Route: emptyRoute,
            token1Route: emptyRoute,
            usdcAmount: 30e6,
            tickLower: ((currentTick - 200) / tickSpacing) * tickSpacing,
            tickUpper: ((currentTick + 200) / tickSpacing) * tickSpacing,
            stake: true,
            slippageBps: 100,
            deadline: block.timestamp + 600
        });

        (uint256 tokenId1,) = liquidityManager.createPosition(params1);

        // Create second staked position
        LiquidityManager.PositionParams memory params2 = LiquidityManager.PositionParams({
            pool: WETH_USDC_POOL,
            token0Route: emptyRoute,
            token1Route: emptyRoute,
            usdcAmount: 20e6,
            tickLower: ((currentTick - 100) / tickSpacing) * tickSpacing,
            tickUpper: ((currentTick + 100) / tickSpacing) * tickSpacing,
            stake: true,
            slippageBps: 100,
            deadline: block.timestamp + 600
        });

        (uint256 tokenId2,) = liquidityManager.createPosition(params2);
        vm.stopPrank();

        // Check that getStakedPositions returns both positions
        uint256[] memory positions = liquidityManager.getStakedPositions(user1);
        assertEq(positions.length, 2, "Should return 2 positions");
        assertEq(positions[0], tokenId1, "First position should match tokenId1");
        assertEq(positions[1], tokenId2, "Second position should match tokenId2");

        // Verify positions are actually staked
        assertTrue(liquidityManager.isPositionStaked(tokenId1), "Position 1 should be staked");
        assertTrue(liquidityManager.isPositionStaked(tokenId2), "Position 2 should be staked");
        assertEq(liquidityManager.getStakedPositionOwner(tokenId1), user1, "Position 1 owner should be user1");
        assertEq(liquidityManager.getStakedPositionOwner(tokenId2), user1, "Position 2 owner should be user1");
    }

    function testGetStakedPositionsMultipleUsers() public {
        // User1 creates a position
        vm.startPrank(user1);
        IERC20(USDC).approve(address(liquidityManager), 50e6);

        ICLPool pool = ICLPool(WETH_USDC_POOL);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        LiquidityManager.SwapRoute memory emptyRoute = LiquidityManager.SwapRoute({
            pools: new address[](0),
            tokens: new address[](0),
            tickSpacings: new int24[](0)
        });

        LiquidityManager.PositionParams memory params = LiquidityManager.PositionParams({
            pool: WETH_USDC_POOL,
            token0Route: emptyRoute,
            token1Route: emptyRoute,
            usdcAmount: 25e6,
            tickLower: ((currentTick - 200) / tickSpacing) * tickSpacing,
            tickUpper: ((currentTick + 200) / tickSpacing) * tickSpacing,
            stake: true,
            slippageBps: 100,
            deadline: block.timestamp + 600
        });

        (uint256 tokenId1,) = liquidityManager.createPosition(params);
        vm.stopPrank();

        // User2 creates a position
        vm.startPrank(user2);
        IERC20(USDC).approve(address(liquidityManager), 50e6);

        (uint256 tokenId2,) = liquidityManager.createPosition(params);
        vm.stopPrank();

        // Check each user only sees their own positions
        uint256[] memory user1Positions = liquidityManager.getStakedPositions(user1);
        assertEq(user1Positions.length, 1, "User1 should have 1 position");
        assertEq(user1Positions[0], tokenId1, "User1's position should be tokenId1");

        uint256[] memory user2Positions = liquidityManager.getStakedPositions(user2);
        assertEq(user2Positions.length, 1, "User2 should have 1 position");
        assertEq(user2Positions[0], tokenId2, "User2's position should be tokenId2");
    }

    function testPositionRemovalOnClose() public {
        vm.startPrank(user1);
        IERC20(USDC).approve(address(liquidityManager), 100e6);

        ICLPool pool = ICLPool(WETH_USDC_POOL);
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        LiquidityManager.SwapRoute memory emptyRoute = LiquidityManager.SwapRoute({
            pools: new address[](0),
            tokens: new address[](0),
            tickSpacings: new int24[](0)
        });

        // Create two positions
        LiquidityManager.PositionParams memory params = LiquidityManager.PositionParams({
            pool: WETH_USDC_POOL,
            token0Route: emptyRoute,
            token1Route: emptyRoute,
            usdcAmount: 30e6,
            tickLower: ((currentTick - 200) / tickSpacing) * tickSpacing,
            tickUpper: ((currentTick + 200) / tickSpacing) * tickSpacing,
            stake: true,
            slippageBps: 100,
            deadline: block.timestamp + 600
        });

        (uint256 tokenId1,) = liquidityManager.createPosition(params);
        (uint256 tokenId2,) = liquidityManager.createPosition(params);

        // Verify both positions are tracked
        uint256[] memory positionsBefore = liquidityManager.getStakedPositions(user1);
        assertEq(positionsBefore.length, 2, "Should have 2 positions before closing");

        // Close the first position
        LiquidityManager.ExitParams memory closeParams = LiquidityManager.ExitParams({
            tokenId: tokenId1,
            pool: WETH_USDC_POOL,
            deadline: block.timestamp + 600,
            minUsdcOut: 0,
            slippageBps: 100,
            token0Route: emptyRoute,
            token1Route: emptyRoute
        });

        liquidityManager.closePosition(closeParams);

        // Verify position was removed from tracking
        uint256[] memory positionsAfter = liquidityManager.getStakedPositions(user1);
        assertEq(positionsAfter.length, 1, "Should have 1 position after closing");
        assertEq(positionsAfter[0], tokenId2, "Remaining position should be tokenId2");

        // Verify the closed position is no longer tracked
        assertFalse(liquidityManager.isPositionStaked(tokenId1), "Closed position should not be staked");
        assertEq(liquidityManager.getStakedPositionOwner(tokenId1), address(0), "Closed position should have no owner");

        // Close the second position
        closeParams.tokenId = tokenId2;
        liquidityManager.closePosition(closeParams);

        // Verify all positions removed
        uint256[] memory positionsFinal = liquidityManager.getStakedPositions(user1);
        assertEq(positionsFinal.length, 0, "Should have no positions after closing all");

        vm.stopPrank();
    }
}
