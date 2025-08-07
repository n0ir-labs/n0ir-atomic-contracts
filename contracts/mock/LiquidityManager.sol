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
import "@interfaces/IAerodromeOracle.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title LiquidityManager
 * @notice Mock contract that mirrors N0irProtocol functionality with different naming
 * @dev Full implementation of N0irProtocol features for testing
 */
contract LiquidityManager is AtomicBase, IERC721Receiver {
    WalletRegistry public immutable walletRegistry;
    
    // Ownership tracking for staked positions
    mapping(uint256 => address) public stakedPositionOwners;
    
    // Core protocol addresses
    IUniversalRouter public constant UNIVERSAL_ROUTER = IUniversalRouter(0x01D40099fCD87C018969B0e8D4aB1633Fb34763C);
    IPermit2 public constant PERMIT2 = IPermit2(0x494bbD8A3302AcA833D307D11838f18DbAdA9C25);
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    IMixedQuoter public constant QUOTER = IMixedQuoter(0x0A5aA5D3a4d28014f967Bf0f29EAA3FF9807D5c6);
    ISugarHelper public constant SUGAR_HELPER = ISugarHelper(0x0AD09A66af0154a84e86F761313d02d0abB6edd5);
    IAerodromeOracle public constant ORACLE = IAerodromeOracle(0x43B36A7E6a4cdFe7de5Bd2Aa1FCcddf6a366dAA2);
    address public constant GAUGE_FACTORY = 0xD30677bd8dd15132F251Cb54CbDA552d2A05Fb08;
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant NONE_CONNECTOR = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    
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
                // Track ownership before staking
                stakedPositionOwners[tokenId] = msg.sender;
                
                POSITION_MANAGER.approve(gauge, tokenId);
                IGauge(gauge).deposit(tokenId);
                // NFT is now held by the gauge, tracked ownership allows user to claim later
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
            // Position is staked in gauge - verify ownership
            require(
                stakedPositionOwners[params.tokenId] == msg.sender,
                "Not the owner of this staked position"
            );
            
            // Withdraw from gauge
            IGauge(gauge).withdraw(params.tokenId);
            aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
            
            // Clear ownership tracking
            delete stakedPositionOwners[params.tokenId];
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
        (uint160 sqrtPriceX96, int24 currentTick,,,,) = pool.slot0();
        
        // Check if position is in range
        if (currentTick < tickLower) {
            // Price below range: need 100% token0
            return (totalUSDC, 0);
        } else if (currentTick >= tickUpper) {
            // Price above range: need 100% token1
            return (0, totalUSDC);
        }
        
        // In-range position: calculate optimal ratio using tick position
        // Get USD prices from oracle
        uint256 token0PriceInUSDC = getTokenPriceViaOracle(token0);
        uint256 token1PriceInUSDC = getTokenPriceViaOracle(token1);
        
        // Ensure prices are valid to prevent division by zero
        require(token0PriceInUSDC > 0, "Invalid token0 price");
        require(token1PriceInUSDC > 0, "Invalid token1 price");
        
        // Calculate allocation based on tick position in range
        uint256 tickRange = uint256(int256(tickUpper - tickLower));
        uint256 tickPosition = uint256(int256(currentTick - tickLower));
        
        // Prevent division by zero
        if (tickRange == 0) {
            // If range is too narrow, split 50/50
            usdc0 = totalUSDC / 2;
            usdc1 = totalUSDC - usdc0;
            return (usdc0, usdc1);
        }
        
        uint256 token1Ratio = (tickPosition * 100) / tickRange;
        
        // Initial allocation
        uint256 initialUsdc1 = (totalUSDC * token1Ratio) / 100;
        uint256 initialUsdc0 = totalUSDC - initialUsdc1;
        
        // Convert USDC amounts to token amounts
        uint256 token0Decimals = token0 == WETH ? 18 : 6;
        uint256 token1Decimals = token1 == WETH ? 18 : 6;
        
        // Calculate token amounts based on prices
        uint256 token0Amount = (initialUsdc0 * (10 ** token0Decimals)) / token0PriceInUSDC;
        
        // Use SugarHelper to get the corresponding token1 amount needed
        uint256 token1Needed = SUGAR_HELPER.estimateAmount1(
            token0Amount,
            address(pool),
            sqrtPriceX96,
            tickLower,
            tickUpper
        );
        
        // Calculate actual USDC values
        uint256 usdc0Value = (token0Amount * token0PriceInUSDC) / (10 ** token0Decimals);
        uint256 usdc1Value = (token1Needed * token1PriceInUSDC) / (10 ** token1Decimals);
        
        // Scale to match totalUSDC exactly
        uint256 totalValue = usdc0Value + usdc1Value;
        if (totalValue > 0) {
            usdc0 = (usdc0Value * totalUSDC) / totalValue;
            usdc1 = totalUSDC - usdc0;
        } else {
            // Fallback to initial allocation
            usdc0 = initialUsdc0;
            usdc1 = initialUsdc1;
        }
    }
    
    function getTokenPriceViaOracle(address token) public view returns (uint256 price) {
        if (token == USDC) {
            return 1e6;
        }
        
        // Try different connectors in order: NONE, WETH, cbBTC (skip USDC since src is already USDC)
        address[3] memory connectors = [NONE_CONNECTOR, WETH, CBBTC];
        
        for (uint i = 0; i < connectors.length; i++) {
            try ORACLE.getRate(
                USDC,  // from token (USDC)
                token, // to token (the token we want price for)
                connectors[i], 
                0
            ) returns (uint256 rate, uint256 weight) {
                if (rate > 0 && weight > 0) {
                    // Oracle returns the rate of USDC -> token with 18 decimals
                    // This tells us how much token we get for 1 USDC
                    // To get the price of token in USDC, we need to invert this
                    
                    // For WETH: if rate = 258926278352007064085601812 (0.000258926... WETH per USDC)
                    // Then 1 WETH = 1 / 0.000258926... = ~3862 USDC
                    
                    // Calculate price: we need to invert the rate
                    // rate = amount of token per 1 USDC (with 18 decimals)  
                    // We want: USDC per 1 token (with 6 decimals)
                    
                    // The math: 
                    // - Oracle gives us: X tokens per 1 USDC (with 18 decimals)
                    // - We want: Y USDC per 1 token (with 6 decimals)
                    // - Formula: Y = 1/X but accounting for decimals
                    // - Y = (1 * 10^6) / (X / 10^18) = 10^6 * 10^18 / X = 10^24 / X
                    // - But since X can be > 10^24, we need 10^30 / X to get enough precision
                    // - Result needs to be multiplied by 1e6 to get proper USDC decimals
                    price = (1e30 / rate) * 1e6;
                    
                    // Ensure price is non-zero
                    if (price > 0) {
                        return price;
                    }
                }
            } catch {
                continue;
            }
        }
        
        // Revert if oracle fails for all connectors
        revert("Oracle price unavailable");
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
        // For production: Don't rely on quoter, use conservative minimum
        // Calculate minAmountOut based on oracle prices with extra buffer
        uint256 minAmountOut = _calculateMinimumOutput(tokenIn, tokenOut, amountIn, slippageBps);
        
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
        
        // Use oracle-based minimum calculation instead of quoter
        uint256 minAmountOut = _calculateMinimumOutput(tokenIn, tokenOut, amountIn, slippageBps);
        
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
        
        if (tick > 0) {
            require(ratio > 0, "Invalid ratio for tick");
            ratio = type(uint256).max / ratio;
        }
        
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
    
    /**
     * @notice Emergency function to recover stuck staked positions
     * @dev Only callable by wallet registry owner for positions without ownership records
     * @param tokenId The stuck position token ID
     * @param pool The pool address
     * @param recipient The address to send recovered funds to
     */
    function emergencyRecoverStakedPosition(
        uint256 tokenId,
        address pool,
        address recipient
    ) external returns (uint256 usdcOut, uint256 aeroRewards) {
        require(msg.sender == address(walletRegistry), "Only registry");
        require(stakedPositionOwners[tokenId] == address(0), "Position has owner");
        
        address gauge = _findGaugeForPool(pool);
        require(gauge != address(0), "No gauge found");
        
        // Track AERO before withdrawal
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        // Withdraw from gauge
        IGauge(gauge).withdraw(tokenId);
        aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        
        // Get pool info
        ICLPool clPool = ICLPool(pool);
        address token0 = clPool.token0();
        address token1 = clPool.token1();
        
        // Get position info
        (,,,,,,,uint128 liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
        
        // Collect fees
        POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        // Remove liquidity
        (uint256 amount0, uint256 amount1) = POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,  // Emergency recovery, accept any amount
                amount1Min: 0,
                deadline: block.timestamp + 300
            })
        );
        
        // Collect tokens
        (amount0, amount1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        // Burn the position
        POSITION_MANAGER.burn(tokenId);
        
        // Swap tokens to USDC if needed
        if (token0 != USDC && amount0 > 0) {
            _approveUniversalRouterViaPermit2(token0, amount0);
            usdcOut += _swapExactInputDirect(token0, USDC, amount0, pool, 500); // 5% slippage for emergency
        } else if (token0 == USDC) {
            usdcOut = amount0;
        }
        
        if (token1 != USDC && amount1 > 0) {
            _approveUniversalRouterViaPermit2(token1, amount1);
            usdcOut += _swapExactInputDirect(token1, USDC, amount1, pool, 500); // 5% slippage for emergency
        } else if (token1 == USDC) {
            usdcOut += amount1;
        }
        
        // Transfer recovered funds
        if (usdcOut > 0) {
            IERC20(USDC).transfer(recipient, usdcOut);
        }
        if (aeroRewards > 0) {
            IERC20(AERO).transfer(recipient, aeroRewards);
        }
        
        emit PositionClosed(recipient, tokenId, usdcOut, aeroRewards);
    }
    
    /**
     * @notice Check if a user owns a staked position
     * @param tokenId The position NFT token ID
     * @return owner The owner address (address(0) if not staked through this contract)
     */
    function getStakedPositionOwner(uint256 tokenId) external view returns (address owner) {
        return stakedPositionOwners[tokenId];
    }
    
    /**
     * @notice Check if a position is staked through this contract
     * @param tokenId The position NFT token ID
     * @return isStaked True if the position is staked through this contract
     */
    function isPositionStaked(uint256 tokenId) external view returns (bool isStaked) {
        return stakedPositionOwners[tokenId] != address(0);
    }
    
    function _calculateMinimumOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps
    ) internal view returns (uint256 minAmountOut) {
        // Production approach: Use oracle prices for reliable minimum calculation
        uint256 tokenInPrice = getTokenPriceViaOracle(tokenIn);
        uint256 tokenOutPrice = getTokenPriceViaOracle(tokenOut);
        
        // Ensure prices are never zero to prevent division by zero
        require(tokenInPrice > 0, "Invalid tokenIn price");
        require(tokenOutPrice > 0, "Invalid tokenOut price");
        
        // Get decimals
        uint256 tokenInDecimals = tokenIn == WETH ? 18 : 6;
        uint256 tokenOutDecimals = tokenOut == WETH ? 18 : 6;
        
        // Calculate value in USDC terms
        uint256 valueInUsdc;
        if (tokenIn == USDC) {
            valueInUsdc = amountIn;
        } else {
            // Convert to USDC value: amount * price / 10^decimals
            valueInUsdc = (amountIn * tokenInPrice) / (10 ** tokenInDecimals);
        }
        
        // Calculate expected output
        uint256 expectedOut;
        if (tokenOut == USDC) {
            expectedOut = valueInUsdc;
        } else {
            // Convert from USDC value: value * 10^decimals / price
            expectedOut = (valueInUsdc * (10 ** tokenOutDecimals)) / tokenOutPrice;
        }
        
        // Apply slippage PLUS additional safety buffer for production
        // Using higher tolerance to account for:
        // 1. Oracle price staleness
        // 2. AMM price impact
        // 3. MEV/sandwich protection
        uint256 totalSlippageBps = slippageBps + 200; // Add 2% safety buffer
        if (totalSlippageBps > MAX_SLIPPAGE_BPS) {
            totalSlippageBps = MAX_SLIPPAGE_BPS;
        }
        
        minAmountOut = (expectedOut * (10000 - totalSlippageBps)) / 10000;
        
        // Ensure we always have some minimum to avoid complete loss
        if (minAmountOut == 0) {
            minAmountOut = 1;
        }
    }
    
}