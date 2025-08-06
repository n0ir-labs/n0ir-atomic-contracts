// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./WalletRegistry.sol";
import "../AtomicBase.sol";
import "@interfaces/IUniversalRouter.sol";
import "@interfaces/IPermit2.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IGauge.sol";
import "@interfaces/ICLPool.sol";
import "@interfaces/IMixedQuoter.sol";
import "@interfaces/ISugarHelper.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/IGaugeFactory.sol";
import "@interfaces/IVoter.sol";
import "@interfaces/IOffchainOracle.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title LiquidityManager
 * @notice Mock contract that mirrors N0irProtocol functionality with different naming
 * @dev Full implementation of N0irProtocol features for testing
 */
contract LiquidityManager is AtomicBase, IERC721Receiver {
    WalletRegistry public immutable walletRegistry;
    
    // Core protocol addresses (matching N0irProtocol)
    IUniversalRouter public constant UNIVERSAL_ROUTER = IUniversalRouter(0x01D40099fCD87C018969B0e8D4aB1633Fb34763C);
    IPermit2 public constant PERMIT2 = IPermit2(0x494bbD8A3302AcA833D307D11838f18DbAdA9C25);
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    IMixedQuoter public constant QUOTER = IMixedQuoter(0x0A5aA5D3a4d28014f967Bf0f29EAA3FF9807D5c6);
    ISugarHelper public constant SUGAR_HELPER = ISugarHelper(0x0AD09A66af0154a84e86F761313d02d0abB6edd5);
    IOffchainOracle public constant ORACLE = IOffchainOracle(0x288a124CB87D7c95656Ad7512B7Da733Bb60A432);
    address public constant GAUGE_FACTORY = 0xD30677bd8dd15132F251Cb54CbDA552d2A05Fb08;
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 100; // 1%
    uint256 private constant MAX_SLIPPAGE_BPS = 1000; // 10%
    uint256 private constant Q96 = 2**96;
    uint256 private constant Q128 = 2**128;
    
    // Events (matching N0irProtocol but renamed)
    event PositionCreated(
        address indexed user,
        uint256 indexed tokenId,
        address indexed pool,
        uint256 usdcIn,
        uint128 liquidity,
        bool staked
    );
    
    event PositionClosed(
        address indexed user,
        uint256 indexed tokenId,
        uint256 usdcOut,
        uint256 aeroRewards
    );
    
    // Structs (matching N0irProtocol)
    struct SwapRoute {
        address[] pools;
        address[] tokens;
        int24[] tickSpacings;
    }
    
    struct PositionParams {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint256 deadline;
        uint256 usdcAmount;
        uint256 slippageBps;
        bool stake;
        SwapRoute token0Route;
        SwapRoute token1Route;
    }
    
    struct ExitParams {
        uint256 tokenId;
        address pool;
        uint256 deadline;
        uint256 minUsdcOut;
        uint256 slippageBps;
        SwapRoute token0Route;
        SwapRoute token1Route;
    }
    
    constructor(address _walletRegistry) {
        walletRegistry = WalletRegistry(_walletRegistry);
    }
    
    modifier onlyAuthorized(address user) {
        require(
            msg.sender == user || 
            (address(walletRegistry) != address(0) && walletRegistry.isWallet(msg.sender)),
            "Unauthorized"
        );
        _;
    }
    
    /**
     * @notice Creates a position (mirrors swapMintAndStake)
     */
    function createPosition(PositionParams calldata params)
        external
        nonReentrant
        deadlineCheck(params.deadline)
        validAmount(params.usdcAmount)
        onlyAuthorized(msg.sender)
        returns (uint256 tokenId, uint128 liquidity)
    {
        return _createPosition(params);
    }
    
    function _createPosition(PositionParams memory params)
        internal
        returns (uint256 tokenId, uint128 liquidity)
    {
        _safeTransferFrom(USDC, msg.sender, address(this), params.usdcAmount);
        
        _validatePool(params.pool, address(0));
        
        ICLPool pool = ICLPool(params.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        int24 tickSpacing = pool.tickSpacing();
        
        _validateTickRange(params.tickLower, params.tickUpper, tickSpacing);
        
        uint256 effectiveSlippage = _getEffectiveSlippage(params.slippageBps);
        
        // Calculate optimal allocation
        (uint256 usdc0, uint256 usdc1) = calculateOptimalUSDCAllocation(
            params.usdcAmount,
            token0,
            token1,
            params.tickLower,
            params.tickUpper,
            pool
        );
        
        // Swap USDC to tokens
        uint256 amount0 = 0;
        uint256 amount1 = 0;
        
        // Handle token0 swap
        if (token0 != USDC) {
            if (params.token0Route.pools.length > 0) {
                amount0 = _executeSwapWithRoute(
                    USDC,
                    token0,
                    usdc0,
                    params.token0Route,
                    effectiveSlippage
                );
            } else {
                amount0 = _swapExactInputDirect(
                    USDC,
                    token0,
                    usdc0,
                    params.pool,
                    effectiveSlippage
                );
            }
        } else {
            amount0 = usdc0;
        }
        
        // Handle token1 swap
        if (token1 != USDC) {
            if (params.token1Route.pools.length > 0) {
                amount1 = _executeSwapWithRoute(
                    USDC,
                    token1,
                    usdc1,
                    params.token1Route,
                    effectiveSlippage
                );
            } else {
                amount1 = _swapExactInputDirect(
                    USDC,
                    token1,
                    usdc1,
                    params.pool,
                    effectiveSlippage
                );
            }
        } else {
            amount1 = usdc1;
        }
        
        // Approve tokens directly to Position Manager (it doesn't use Permit2)
        IERC20(token0).approve(address(POSITION_MANAGER), amount0);
        IERC20(token1).approve(address(POSITION_MANAGER), amount1);
        
        // Mint position
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: (amount0 * (10000 - effectiveSlippage)) / 10000,
            amount1Min: (amount1 * (10000 - effectiveSlippage)) / 10000,
            recipient: params.stake ? address(this) : msg.sender,
            deadline: params.deadline,
            sqrtPriceX96: 0
        });
        
        (tokenId, liquidity, , ) = POSITION_MANAGER.mint(mintParams);
        
        // Stake if requested
        if (params.stake) {
            address gauge = _findGaugeForPool(params.pool);
            if (gauge != address(0)) {
                POSITION_MANAGER.approve(gauge, tokenId);
                IGauge(gauge).deposit(tokenId);
                // NFT is now held by the gauge, user interacts with gauge directly
            } else {
                // If no gauge found, return position to user
                POSITION_MANAGER.safeTransferFrom(address(this), msg.sender, tokenId);
            }
        } else {
            // If not staking, transfer position NFT to user
            POSITION_MANAGER.safeTransferFrom(address(this), msg.sender, tokenId);
        }
        
        _returnLeftoverTokens(token0, token1);
        
        emit PositionCreated(msg.sender, tokenId, params.pool, params.usdcAmount, liquidity, params.stake);
    }
    
    /**
     * @notice Closes a position (mirrors fullExit)
     */
    function closePosition(ExitParams calldata params)
        external
        nonReentrant
        deadlineCheck(params.deadline)
        onlyAuthorized(msg.sender)
        returns (uint256 usdcOut, uint256 aeroRewards)
    {
        address gauge = _findGaugeForPool(params.pool);
        
        // Track AERO rewards
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        // Check if position is staked by checking NFT ownership
        address positionOwner = POSITION_MANAGER.ownerOf(params.tokenId);
        
        // Handle staked positions
        if (gauge != address(0) && positionOwner == gauge) {
            // Position is staked in gauge - withdraw it
            IGauge(gauge).withdraw(params.tokenId);
            aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        } else {
            // Position is not staked - transfer from user
            POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), params.tokenId);
        }
        
        // Collect any fees first
        POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: params.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        ICLPool pool = ICLPool(params.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        // Get effective slippage
        uint256 effectiveSlippage = _getEffectiveSlippage(params.slippageBps);
        
        // Calculate minimum amounts with slippage
        (uint256 expectedAmount0, uint256 expectedAmount1) = _calculateExpectedAmounts(
            params.tokenId,
            params.pool
        );
        
        uint256 amount0Min = (expectedAmount0 * (10000 - effectiveSlippage)) / 10000;
        uint256 amount1Min = (expectedAmount1 * (10000 - effectiveSlippage)) / 10000;
        
        // Get position info
        (,,,,,,,uint128 liquidity,,,,) = POSITION_MANAGER.positions(params.tokenId);
        
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = 
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: params.tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: params.deadline
            });
        
        (uint256 amount0, uint256 amount1) = POSITION_MANAGER.decreaseLiquidity(decreaseParams);
        
        INonfungiblePositionManager.CollectParams memory collectParams = 
            INonfungiblePositionManager.CollectParams({
                tokenId: params.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        
        (amount0, amount1) = POSITION_MANAGER.collect(collectParams);
        POSITION_MANAGER.burn(params.tokenId);
        
        // Swap tokens back to USDC (reuse effectiveSlippage from above)
        
        if (token0 != USDC && amount0 > 0) {
            _approveTokenToPermit2(token0, amount0);
            _approveUniversalRouterViaPermit2(token0, amount0);
            
            if (params.token0Route.pools.length > 0) {
                usdcOut += _executeSwapWithRoute(
                    token0,
                    USDC,
                    amount0,
                    params.token0Route,
                    effectiveSlippage
                );
            } else {
                usdcOut += _swapExactInputDirect(
                    token0,
                    USDC,
                    amount0,
                    params.pool,
                    effectiveSlippage
                );
            }
        } else if (token0 == USDC) {
            usdcOut += amount0;
        }
        
        if (token1 != USDC && amount1 > 0) {
            _approveTokenToPermit2(token1, amount1);
            _approveUniversalRouterViaPermit2(token1, amount1);
            
            if (params.token1Route.pools.length > 0) {
                usdcOut += _executeSwapWithRoute(
                    token1,
                    USDC,
                    amount1,
                    params.token1Route,
                    effectiveSlippage
                );
            } else {
                usdcOut += _swapExactInputDirect(
                    token1,
                    USDC,
                    amount1,
                    params.pool,
                    effectiveSlippage
                );
            }
        } else if (token1 == USDC) {
            usdcOut += amount1;
        }
        
        require(usdcOut >= params.minUsdcOut, "Insufficient output");
        
        if (usdcOut > 0) {
            IERC20(USDC).transfer(msg.sender, usdcOut);
        }
        
        if (aeroRewards > 0) {
            IERC20(AERO).transfer(msg.sender, aeroRewards);
        }
        
        emit PositionClosed(msg.sender, params.tokenId, usdcOut, aeroRewards);
    }
    
    function calculateOptimalUSDCAllocation(
        uint256 totalUSDC,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        ICLPool pool
    ) public view returns (uint256 usdc0, uint256 usdc1) {
        uint256 token0Price = getTokenPriceViaOracle(token0);
        uint256 token1Price = getTokenPriceViaOracle(token1);
        
        (uint160 sqrtPriceX96,,,,,) = pool.slot0();
        
        // Price ratio calculation removed - was unused
        
        uint160 sqrtRatioAX96 = getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = getSqrtRatioAtTick(tickUpper);
        
        uint256 liquidity0 = Q96 * Q96 / (uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96));
        uint256 liquidity1 = uint256(sqrtRatioBX96) * uint256(sqrtRatioAX96) / Q96;
        
        uint256 totalValue = (liquidity0 * token0Price / 1e18) + (liquidity1 * token1Price / 1e18);
        
        usdc0 = (totalUSDC * liquidity0 * token0Price / 1e18) / totalValue;
        usdc1 = totalUSDC - usdc0;
    }
    
    function getTokenPriceViaOracle(address token) public view returns (uint256 price) {
        if (token == USDC) {
            return 1e6;
        }
        
        try ORACLE.getRate(token, USDC, false) returns (uint256 rate) {
            price = rate;
        } catch {
            if (token == WETH) {
                price = 3595e6;
            } else if (token == AERO) {
                price = 1.2e6;
            } else {
                price = 1e6;
            }
        }
    }
    
    function _approveTokenToPermit2(address token, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), address(PERMIT2)) < amount) {
            IERC20(token).approve(address(PERMIT2), type(uint256).max);
        }
    }
    
    function _approveUniversalRouterViaPermit2(address token, uint256 amount) internal {
        // First ensure token is approved to Permit2
        if (IERC20(token).allowance(address(this), address(PERMIT2)) < amount) {
            IERC20(token).approve(address(PERMIT2), type(uint256).max);
        }
        
        // Then approve Universal Router via Permit2 with max amounts
        PERMIT2.approve(
            token,
            address(UNIVERSAL_ROUTER),
            type(uint160).max,
            uint48(block.timestamp + 30 days)
        );
    }
    
    function _swapExactInputDirect(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address pool,
        uint256 slippageBps
    ) internal returns (uint256 amountOut) {
        // Calculate expected output using quoter
        uint256 expectedOut = _getQuote(tokenIn, tokenOut, amountIn, pool);
        uint256 minAmountOut = (expectedOut * (10000 - slippageBps)) / 10000;
        
        // Ensure we have the tokens
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "Insufficient tokenIn balance");
        
        // First, approve Permit2 to spend your contract's tokens
        if (IERC20(tokenIn).allowance(address(this), address(PERMIT2)) < amountIn) {
            IERC20(tokenIn).approve(address(PERMIT2), type(uint256).max);
        }
        
        // Then, approve Universal Router on Permit2
        PERMIT2.approve(
            tokenIn,
            address(UNIVERSAL_ROUTER),
            uint160(amountIn),
            uint48(block.timestamp + 3600) // expiration
        );
        
        bytes memory commands = abi.encodePacked(bytes1(0x00)); // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        
        // Get tick spacing directly from the pool
        int24 tickSpacing = ICLPool(pool).tickSpacing();
        bytes memory tickSpacingBytes = abi.encodePacked(uint24(uint256(int256(tickSpacing))));
        
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            abi.encodePacked(tokenIn, tickSpacingBytes, tokenOut), // path with tick spacing
            true,           // payerIsUser = true (Universal Router pulls via Permit2)
            true            // useSlipstreamPools = true for Aerodrome V3 CL pools
        );
        
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute{value: 0}(commands, inputs);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
        
        require(amountOut >= minAmountOut, "Insufficient output amount");
    }
    
    function _executeSwapWithRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        SwapRoute memory route,
        uint256 slippageBps
    ) internal returns (uint256 amountOut) {
        require(route.pools.length > 0, "Empty route");
        require(route.tokens.length == route.pools.length + 1, "Invalid route tokens");
        require(route.tickSpacings.length == route.pools.length, "Invalid route tick spacings");
        
        // Calculate minimum output with slippage
        uint256 expectedOut = _getQuoteForRoute(tokenIn, tokenOut, amountIn, route);
        uint256 minAmountOut = (expectedOut * (10000 - slippageBps)) / 10000;
        
        // Single hop swap
        if (route.pools.length == 1) {
            return _swapExactInputDirect(
                route.tokens[0],
                route.tokens[1],
                amountIn,
                route.pools[0],
                slippageBps
            );
        }
        
        // Multi-hop swap
        bytes memory path = _encodeMultihopPath(route);
        
        // Ensure we have the tokens
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "Insufficient tokenIn balance");
        
        // First, approve Permit2 to spend your contract's tokens
        if (IERC20(tokenIn).allowance(address(this), address(PERMIT2)) < amountIn) {
            IERC20(tokenIn).approve(address(PERMIT2), type(uint256).max);
        }
        
        // Then, approve Universal Router on Permit2
        PERMIT2.approve(
            tokenIn,
            address(UNIVERSAL_ROUTER),
            uint160(amountIn),
            uint48(block.timestamp + 3600)
        );
        
        bytes memory commands = abi.encodePacked(bytes1(0x00)); // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            path,           // encoded path
            true,           // payerIsUser = true (Universal Router pulls via Permit2)
            true            // useSlipstreamPools = true for Aerodrome V3
        );
        
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute{value: 0}(commands, inputs);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
        
        require(amountOut >= minAmountOut, "Insufficient output amount");
    }
    
    function _encodeMultihopPath(SwapRoute memory route) internal pure returns (bytes memory) {
        bytes memory path = abi.encodePacked(route.tokens[0]);
        
        for (uint256 i = 0; i < route.pools.length; i++) {
            bytes memory tickSpacingBytes = abi.encodePacked(uint24(uint256(int256(route.tickSpacings[i]))));
            path = abi.encodePacked(path, tickSpacingBytes, route.tokens[i + 1]);
        }
        
        return path;
    }
    
    function _calculateExpectedAmounts(
        uint256 tokenId,
        address pool
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (,,,,,int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
        
        // Get current pool state
        (uint160 sqrtPriceX96,,,,,) = ICLPool(pool).slot0();
        
        // Use SugarHelper to calculate amounts
        (amount0, amount1) = SUGAR_HELPER.getAmountsForLiquidity(
            sqrtPriceX96,
            getSqrtRatioAtTick(tickLower),
            getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }
    
    function _returnLeftoverTokens(address token0, address token1) internal {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        
        if (balance0 > 0) {
            IERC20(token0).transfer(msg.sender, balance0);
        }
        if (balance1 > 0) {
            IERC20(token1).transfer(msg.sender, balance1);
        }
    }
    
    function _findGaugeForPool(address pool) internal view returns (address gauge) {
        try IVoter(VOTER).gauges(pool) returns (address g) {
            gauge = g;
        } catch {
            gauge = address(0);
        }
    }
    
    function _getEffectiveSlippage(uint256 requestedSlippage) internal pure returns (uint256) {
        if (requestedSlippage == 0) {
            return DEFAULT_SLIPPAGE_BPS;
        }
        require(requestedSlippage <= MAX_SLIPPAGE_BPS, "Slippage too high");
        return requestedSlippage;
    }
    
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(887272), "T");
        
        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
        
        if (tick > 0) ratio = type(uint256).max / ratio;
        
        return uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
    
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
    
    function recoverToken(address token, uint256 amount) external {
        require(msg.sender == address(walletRegistry), "Only registry");
        IERC20(token).transfer(msg.sender, amount);
    }
    
    function _getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address pool
    ) internal returns (uint256 amountOut) {
        try QUOTER.quoteExactInputSingle(
            IMixedQuoter.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                tickSpacing: ICLPool(pool).tickSpacing(),
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 out, uint160, uint32, uint256) {
            amountOut = out;
        } catch {
            // Fallback: estimate based on current pool price
            (uint160 sqrtPriceX96,,,,,) = ICLPool(pool).slot0();
            uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
            
            // Rough estimate - swap will likely get less due to price impact
            if (tokenIn < tokenOut) {
                // token0 -> token1
                amountOut = (amountIn * price * 95) / 100; // Apply 5% buffer
            } else {
                // token1 -> token0  
                amountOut = (amountIn * 95) / (price * 100); // Apply 5% buffer
            }
        }
    }
    
    function _getQuoteForRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        SwapRoute memory route
    ) internal returns (uint256 amountOut) {
        // For single hop, use direct quote
        if (route.pools.length == 1) {
            return _getQuote(tokenIn, tokenOut, amountIn, route.pools[0]);
        }
        
        // For multi-hop, estimate conservatively
        // This is a simplified approach - ideally would simulate the full path
        amountOut = amountIn;
        for (uint256 i = 0; i < route.pools.length; i++) {
            amountOut = _getQuote(
                route.tokens[i],
                route.tokens[i + 1],
                amountOut,
                route.pools[i]
            );
        }
    }
}