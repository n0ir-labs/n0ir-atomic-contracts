// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { WalletRegistry } from "./WalletRegistry.sol";
import { AtomicBase } from "./AtomicBase.sol";
import { RouteFinder } from "./RouteFinder.sol";
import { RouteFinderLib } from "./libraries/RouteFinderLib.sol";
import { ISwapRouter } from "@interfaces/ISwapRouter.sol";
import { INonfungiblePositionManager } from "@interfaces/INonfungiblePositionManager.sol";
import { IGauge } from "@interfaces/IGauge.sol";
import { ICLPool } from "@interfaces/ICLPool.sol";
import { IMixedQuoter } from "@interfaces/IMixedQuoter.sol";
import { ISugarHelper } from "@interfaces/ISugarHelper.sol";
import { IERC20 } from "@interfaces/IERC20.sol";
import { IGaugeFactory } from "@interfaces/IGaugeFactory.sol";
import { IVoter } from "@interfaces/IVoter.sol";
import { IAerodromeOracle } from "@interfaces/IAerodromeOracle.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title LiquidityManager
 * @notice Manages atomic liquidity operations for Aerodrome V3 Slipstream pools
 * @dev Implements concentrated liquidity position management with atomic swap/mint/stake capabilities
 */
contract LiquidityManager is AtomicBase, IERC721Receiver {
    // ============ Custom Errors ============
    error InvalidRoute();
    error InvalidSlippage();
    error UnauthorizedAccess();
    error PositionNotFound();
    error InsufficientBalance();
    error SwapFailed();
    error MintFailed();
    error StakeFailed();
    error GaugeNotFound();
    error OraclePriceUnavailable();
    error InvalidRecipient();
    error ArrayLengthMismatch();
    error InvalidTickSpacing();
    error EmergencyRecoveryFailed();

    // ============ State Variables ============
    /// @notice Registry contract for wallet access control
    WalletRegistry public immutable walletRegistry;
    
    /// @notice RouteFinder contract for automatic route discovery
    RouteFinder public immutable routeFinder;

    /// @notice Tracks ownership of staked positions (tokenId => owner)
    mapping(uint256 => address) public stakedPositionOwners;

    /// @notice Tracks position IDs owned by each address
    mapping(address => uint256[]) private ownerPositionIds;

    /// @notice Tracks index of position ID in owner's array for efficient removal
    mapping(uint256 => uint256) private positionIdIndex;

    // ============ Constants ============
    /// @notice Core contracts - immutable for gas optimization
    ISwapRouter public constant SWAP_ROUTER = ISwapRouter(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5);
    INonfungiblePositionManager public constant POSITION_MANAGER =
        INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    IMixedQuoter public constant QUOTER = IMixedQuoter(0x254cF9E1E6e233aa1AC962CB9B05b2cfeAaE15b0);
    ISugarHelper public constant SUGAR_HELPER = ISugarHelper(0x0AD09A66af0154a84e86F761313d02d0abB6edd5);
    IAerodromeOracle public constant ORACLE = IAerodromeOracle(0x43B36A7E6a4cdFe7de5Bd2Aa1FCcddf6a366dAA2);

    /// @notice Gauge and voting infrastructure
    address public constant GAUGE_FACTORY = 0xD30677bd8dd15132F251Cb54CbDA552d2A05Fb08;
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;

    /// @notice Token addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    /// @notice Oracle connector for direct routing
    address private constant NONE_CONNECTOR = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    // ============ Mathematical Constants ============
    
    /// @dev Default slippage tolerance in basis points (1% = 100 bps)
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 100;
    
    /// @dev Maximum allowed slippage in basis points (10% = 1000 bps)
    uint256 private constant MAX_SLIPPAGE_BPS = 1000;
    
    /// @dev Basis points denominator (100% = 10000 bps)
    uint256 private constant BPS_DENOMINATOR = 10_000;
    
    /// @dev Uniswap V3 Q96 fixed point precision (2^96)
    uint256 private constant Q96 = 2 ** 96;
    
    /// @dev Uniswap V3 Q128 fixed point precision (2^128)
    uint256 private constant Q128 = 2 ** 128;
    
    /// @dev Maximum valid tick for Uniswap V3 pools
    uint256 private constant MAX_TICK = 887_272;
    
    /// @dev Minimum valid tick for Uniswap V3 pools
    int24 private constant MIN_TICK = -887272;
    
    /// @dev Maximum uint128 value for collect operations
    uint128 private constant MAX_UINT128 = type(uint128).max;
    
    /// @dev Transaction deadline buffer (5 minutes)
    uint256 private constant DEADLINE_BUFFER = 300;

    // ============ Events ============
    /// @notice Emitted when a new position is created
    /// @param user The address creating the position
    /// @param tokenId The NFT token ID of the created position
    /// @param pool The pool address
    /// @param usdcIn Amount of USDC invested
    /// @param liquidity Amount of liquidity minted
    /// @param staked Whether the position was staked
    event PositionCreated(
        address indexed user,
        uint256 indexed tokenId,
        address indexed pool,
        uint256 usdcIn,
        uint128 liquidity,
        bool staked
    );

    /// @notice Emitted when a position is closed
    /// @param user The address closing the position
    /// @param tokenId The NFT token ID being closed
    /// @param usdcOut Amount of USDC returned
    /// @param aeroRewards Amount of AERO rewards claimed
    event PositionClosed(address indexed user, uint256 indexed tokenId, uint256 usdcOut, uint256 aeroRewards);

    /// @notice Emitted when tokens are recovered
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a swap is executed
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /// @notice Emitted when rewards are claimed from a position
    event RewardsClaimed(address indexed user, uint256 indexed tokenId, uint256 aeroAmount);

    /// @notice Emitted when rewards are claimed from multiple positions
    event AllRewardsClaimed(address indexed user, uint256 totalAeroAmount, uint256 positionCount);

    // ============ Type Definitions ============
    /// @notice Defines the type of routing strategy
    enum RouteType {
        EMPTY, // No swap needed (token is USDC)
        DIRECT, // Direct swap from USDC to token
        INTERMEDIATE // Needs intermediate token (sequential swap)

    }

    /// @notice Defines a swap route through pools
    /// @param pools Array of pool addresses to route through
    /// @param tokens Array of token addresses in the route
    /// @param tickSpacings Array of tick spacings for each pool
    struct SwapRoute {
        address[] pools;
        address[] tokens;
        int24[] tickSpacings;
    }

    /// @notice Parameters for creating a position
    struct PositionParams {
        address pool; // Target pool address
        int24 tickLower; // Lower tick boundary
        int24 tickUpper; // Upper tick boundary
        uint256 deadline; // Transaction deadline
        uint256 usdcAmount; // USDC amount to invest
        uint256 slippageBps; // Slippage tolerance in basis points
        bool stake; // Whether to stake in gauge
        SwapRoute token0Route; // Routing for token0
        SwapRoute token1Route; // Routing for token1
    }

    /// @notice Parameters for exiting a position
    struct ExitParams {
        uint256 tokenId; // Position NFT token ID
        address pool; // Pool address
        uint256 deadline; // Transaction deadline
        uint256 minUsdcOut; // Minimum USDC to receive
        uint256 slippageBps; // Slippage tolerance in basis points
        SwapRoute token0Route; // Routing for token0 to USDC
        SwapRoute token1Route; // Routing for token1 to USDC
    }

    /// @notice Detailed information about a liquidity position
    struct PositionInfo {
        uint256 id; // Position NFT token ID
        address owner; // Owner of the position
        address poolAddress; // Pool address
        int24 tickLower; // Lower tick boundary
        int24 tickUpper; // Upper tick boundary
        uint128 liquidity; // Liquidity amount
        uint128 tokensOwed0; // Unclaimed token0 fees
        uint128 tokensOwed1; // Unclaimed token1 fees
        bool inRange; // Whether position is in range
        uint256 currentValueUsd; // Current position value in USD
        uint256 unclaimedFeesUsd; // Unclaimed fees value in USD
        bool staked; // Whether position is staked in gauge
        address gaugeAddress; // Gauge address if staked
    }

    // ============ Constructor ============
    /// @notice Initializes the LiquidityManager with a wallet registry and route finder
    /// @param _walletRegistry Address of the wallet registry contract (can be address(0))
    /// @param _routeFinder Address of the RouteFinder contract (can be address(0) to disable auto-routing)
    /// @dev Registry can be address(0) for permissionless deployment
    constructor(address _walletRegistry, address _routeFinder) {
        if (_walletRegistry != address(0)) {
            walletRegistry = WalletRegistry(_walletRegistry);
        }
        if (_routeFinder != address(0)) {
            routeFinder = RouteFinder(_routeFinder);
        }
    }

    // ============ Modifiers ============
    /// @notice Ensures caller is authorized to act on behalf of user
    /// @param user The user address to check authorization for
    modifier onlyAuthorized(address user) {
        if (msg.sender != user) {
            if (address(walletRegistry) == address(0) || !walletRegistry.isWallet(msg.sender)) {
                revert UnauthorizedAccess();
            }
        }
        _;
    }

    // ============ External Functions ============

    /**
     * @notice Creates a new concentrated liquidity position with percentage-based range
     * @param pool Target pool address
     * @param rangePercentage Price range as percentage in basis points (500 = ±5% from current price)
     * @param deadline Transaction deadline
     * @param usdcAmount USDC amount to invest
     * @param slippageBps Slippage tolerance in basis points
     * @param stake Whether to stake in gauge
     * @return tokenId The NFT token ID of the created position
     * @return liquidity The amount of liquidity minted
     * @dev Automatically calculates ticks based on current price and desired range percentage
     */
    function createPosition(
        address pool,
        uint256 rangePercentage,
        uint256 deadline,
        uint256 usdcAmount,
        uint256 slippageBps,
        bool stake
    )
        external
        nonReentrant
        deadlineCheck(deadline)
        validAmount(usdcAmount)
        onlyAuthorized(msg.sender)
        returns (uint256 tokenId, uint128 liquidity)
    {
        require(address(routeFinder) != address(0), "RouteFinder not configured");
        require(rangePercentage > 0 && rangePercentage <= 10000, "Invalid range percentage");
        
        // Get pool info
        ICLPool clPool = ICLPool(pool);
        address token0 = clPool.token0();
        address token1 = clPool.token1();
        int24 tickSpacing = clPool.tickSpacing();
        
        // Get current tick and calculate range
        (, int24 currentTick,,,,) = clPool.slot0();
        (int24 tickLower, int24 tickUpper) = calculateTicksFromPercentage(
            currentTick,
            rangePercentage,
            tickSpacing
        );
        
        // Find routes automatically
        (
            RouteFinderLib.SwapRoute memory token0Route,
            RouteFinderLib.SwapRoute memory token1Route,
            RouteFinderLib.RouteStatus status
        ) = routeFinder.findRoutesForPositionOpen(token0, token1, pool, tickSpacing);
        
        // Check if routes were found
        if (status == RouteFinderLib.RouteStatus.NO_ROUTE) {
            revert InvalidRoute();
        }
        
        // Create position parameters with discovered routes
        PositionParams memory params = PositionParams({
            pool: pool,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: deadline,
            usdcAmount: usdcAmount,
            slippageBps: slippageBps,
            stake: stake,
            token0Route: SwapRoute({
                pools: token0Route.pools,
                tokens: token0Route.tokens,
                tickSpacings: token0Route.tickSpacings
            }),
            token1Route: SwapRoute({
                pools: token1Route.pools,
                tokens: token1Route.tokens,
                tickSpacings: token1Route.tickSpacings
            })
        });
        
        // Use existing createPosition logic
        return _createPosition(params);
    }

    /**
     * @notice Creates a new concentrated liquidity position with explicit tick boundaries
     * @param pool Target pool address
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param deadline Transaction deadline
     * @param usdcAmount USDC amount to invest
     * @param slippageBps Slippage tolerance in basis points
     * @param stake Whether to stake in gauge
     * @return tokenId The NFT token ID of the created position
     * @return liquidity The amount of liquidity minted
     * @dev For advanced users who need precise tick control
     */
    function createPositionWithTicks(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 deadline,
        uint256 usdcAmount,
        uint256 slippageBps,
        bool stake
    )
        external
        nonReentrant
        deadlineCheck(deadline)
        validAmount(usdcAmount)
        onlyAuthorized(msg.sender)
        returns (uint256 tokenId, uint128 liquidity)
    {
        require(address(routeFinder) != address(0), "RouteFinder not configured");
        
        // Get pool info
        ICLPool clPool = ICLPool(pool);
        address token0 = clPool.token0();
        address token1 = clPool.token1();
        int24 tickSpacing = clPool.tickSpacing();
        
        // Find routes automatically
        (
            RouteFinderLib.SwapRoute memory token0Route,
            RouteFinderLib.SwapRoute memory token1Route,
            RouteFinderLib.RouteStatus status
        ) = routeFinder.findRoutesForPositionOpen(token0, token1, pool, tickSpacing);
        
        // Check if routes were found
        if (status == RouteFinderLib.RouteStatus.NO_ROUTE) {
            revert InvalidRoute();
        }
        
        // Create position parameters with discovered routes
        PositionParams memory params = PositionParams({
            pool: pool,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deadline: deadline,
            usdcAmount: usdcAmount,
            slippageBps: slippageBps,
            stake: stake,
            token0Route: SwapRoute({
                pools: token0Route.pools,
                tokens: token0Route.tokens,
                tickSpacings: token0Route.tickSpacings
            }),
            token1Route: SwapRoute({
                pools: token1Route.pools,
                tokens: token1Route.tokens,
                tickSpacings: token1Route.tickSpacings
            })
        });
        
        // Use existing createPosition logic
        return _createPosition(params);
    }

    function _createPosition(PositionParams memory params) internal returns (uint256 tokenId, uint128 liquidity) {
        _safeTransferFrom(USDC, msg.sender, address(this), params.usdcAmount);

        _validatePool(params.pool, address(0));

        ICLPool pool = ICLPool(params.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        int24 tickSpacing = pool.tickSpacing();

        _validateTickRange(params.tickLower, params.tickUpper, tickSpacing);

        uint256 effectiveSlippage = _getEffectiveSlippage(params.slippageBps);

        // Analyze routes to determine if sequential swapping is needed
        (bool needsSequential, address intermediateToken) =
            _analyzeRoutes(params.token0Route, params.token1Route, token0, token1);

        uint256 amount0 = 0;
        uint256 amount1 = 0;

        if (needsSequential && intermediateToken != address(0)) {
            // Sequential routing: one token depends on another
            (amount0, amount1) = _executeSequentialSwaps(params, token0, token1, intermediateToken, effectiveSlippage);
        } else {
            // Standard routing: independent swaps
            // Calculate optimal allocation
            (uint256 usdc0, uint256 usdc1) = calculateOptimalUSDCAllocation(
                params.usdcAmount, token0, token1, params.tickLower, params.tickUpper, pool
            );

            // Handle token0 swap
            if (token0 != USDC) {
                if (usdc0 > 0) {
                    if (params.token0Route.pools.length > 0) {
                        amount0 = _executeSwapWithRoute(USDC, token0, usdc0, params.token0Route, effectiveSlippage);
                    } else {
                        amount0 = _swapExactInputDirect(USDC, token0, usdc0, params.pool, effectiveSlippage);
                    }
                } else {
                    amount0 = 0;
                }
            } else {
                amount0 = usdc0;
            }

            // Handle token1 swap
            if (token1 != USDC) {
                if (usdc1 > 0) {
                    if (params.token1Route.pools.length > 0) {
                        amount1 = _executeSwapWithRoute(USDC, token1, usdc1, params.token1Route, effectiveSlippage);
                    } else {
                        amount1 = _swapExactInputDirect(USDC, token1, usdc1, params.pool, effectiveSlippage);
                    }
                } else {
                    amount1 = 0;
                }
            } else {
                amount1 = usdc1;
            }
        }

        // Approve tokens directly to Position Manager (it doesn't use Permit2)
        IERC20(token0).approve(address(POSITION_MANAGER), amount0);
        IERC20(token1).approve(address(POSITION_MANAGER), amount1);

        // For high tick spacing pools, use very low minimum amounts
        // PSC errors occur when the price moves significantly during mint
        // Using 0 for minimums allows the position manager to use whatever ratio is needed
        uint256 amount0Min = 0;
        uint256 amount1Min = 0;
        
        // Only apply slippage protection for normal tick spacing pools
        if (tickSpacing < 1000) {
            amount0Min = (amount0 * (10_000 - effectiveSlippage)) / 10_000;
            amount1Min = (amount1 * (10_000 - effectiveSlippage)) / 10_000;
        }
        
        // Mint position
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: params.stake ? address(this) : msg.sender,
            deadline: params.deadline,
            sqrtPriceX96: 0
        });

        (tokenId, liquidity,,) = POSITION_MANAGER.mint(mintParams);

        // Stake if requested
        if (params.stake) {
            address gauge = _findGaugeForPool(params.pool);
            if (gauge != address(0)) {
                // Track ownership before staking
                stakedPositionOwners[tokenId] = msg.sender;

                // Add position to owner's list
                ownerPositionIds[msg.sender].push(tokenId);
                positionIdIndex[tokenId] = ownerPositionIds[msg.sender].length - 1;

                POSITION_MANAGER.approve(gauge, tokenId);
                IGauge(gauge).deposit(tokenId);
                // NFT is now held by the gauge, tracked ownership allows user to claim later
            } else {
                // If no gauge found, return position to user
                POSITION_MANAGER.safeTransferFrom(address(this), msg.sender, tokenId);
            }
        }
        // If not staking, position was already minted directly to user (no transfer needed)

        _returnLeftoverTokens(token0, token1);

        emit PositionCreated(msg.sender, tokenId, params.pool, params.usdcAmount, liquidity, params.stake);
    }

    /**
     * @notice Closes a position with automatic route discovery
     * @param tokenId Position NFT token ID
     * @param pool Pool address
     * @param deadline Transaction deadline
     * @param minUsdcOut Minimum USDC to receive
     * @param slippageBps Slippage tolerance in basis points
     * @return usdcOut Amount of USDC returned to user
     * @return aeroRewards Amount of AERO rewards claimed
     * @dev Automatically discovers optimal swap routes using RouteFinder
     */
    function closePosition(
        uint256 tokenId,
        address pool,
        uint256 deadline,
        uint256 minUsdcOut,
        uint256 slippageBps
    )
        external
        nonReentrant
        deadlineCheck(deadline)
        onlyAuthorized(msg.sender)
        returns (uint256 usdcOut, uint256 aeroRewards)
    {
        require(address(routeFinder) != address(0), "RouteFinder not configured");
        
        // Get pool info
        ICLPool clPool = ICLPool(pool);
        address token0 = clPool.token0();
        address token1 = clPool.token1();
        
        // Find routes automatically
        (
            RouteFinderLib.SwapRoute memory token0Route,
            RouteFinderLib.SwapRoute memory token1Route,
            RouteFinderLib.RouteStatus status
        ) = routeFinder.findRoutesForPositionClose(token0, token1);
        
        // Check if routes were found (at least partial success needed)
        if (status == RouteFinderLib.RouteStatus.NO_ROUTE) {
            revert InvalidRoute();
        }
        
        // Create exit parameters with discovered routes
        ExitParams memory params = ExitParams({
            tokenId: tokenId,
            pool: pool,
            deadline: deadline,
            minUsdcOut: minUsdcOut,
            slippageBps: slippageBps,
            token0Route: SwapRoute({
                pools: token0Route.pools,
                tokens: token0Route.tokens,
                tickSpacings: token0Route.tickSpacings
            }),
            token1Route: SwapRoute({
                pools: token1Route.pools,
                tokens: token1Route.tokens,
                tickSpacings: token1Route.tickSpacings
            })
        });
        
        // Use existing closePosition logic
        return _closePosition(params);
    }

    function _closePosition(ExitParams memory params) internal returns (uint256 usdcOut, uint256 aeroRewards) {
        address gauge = _findGaugeForPool(params.pool);

        // Track AERO rewards
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));

        // Check if position is staked by checking NFT ownership
        address positionOwner = POSITION_MANAGER.ownerOf(params.tokenId);

        // Handle staked positions
        if (gauge != address(0) && positionOwner == gauge) {
            // Position is staked in gauge - verify ownership
            require(stakedPositionOwners[params.tokenId] == msg.sender, "Not the owner of this staked position");

            // Withdraw from gauge
            IGauge(gauge).withdraw(params.tokenId);
            aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroBefore;

            // Remove position from owner's list
            _removePositionFromOwner(msg.sender, params.tokenId);

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
        (uint256 expectedAmount0, uint256 expectedAmount1) = _calculateExpectedAmounts(params.tokenId, params.pool);

        uint256 amount0Min = (expectedAmount0 * (10_000 - effectiveSlippage)) / 10_000;
        uint256 amount1Min = (expectedAmount1 * (10_000 - effectiveSlippage)) / 10_000;

        // Get position info
        (,,,,,,, uint128 liquidity,,,,) = POSITION_MANAGER.positions(params.tokenId);

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: params.tokenId,
            liquidity: liquidity,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: params.deadline
        });

        (uint256 amount0, uint256 amount1) = POSITION_MANAGER.decreaseLiquidity(decreaseParams);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: params.tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (amount0, amount1) = POSITION_MANAGER.collect(collectParams);
        POSITION_MANAGER.burn(params.tokenId);

        // Swap tokens back to USDC with slippage protection

        if (token0 != USDC && amount0 > 0) {
            if (params.token0Route.pools.length > 0) {
                usdcOut += _executeSwapWithRoute(token0, USDC, amount0, params.token0Route, effectiveSlippage);
            } else {
                usdcOut += _swapExactInputDirect(token0, USDC, amount0, params.pool, effectiveSlippage);
            }
        } else if (token0 == USDC) {
            usdcOut += amount0;
        }

        if (token1 != USDC && amount1 > 0) {
            if (params.token1Route.pools.length > 0) {
                usdcOut += _executeSwapWithRoute(token1, USDC, amount1, params.token1Route, effectiveSlippage);
            } else {
                usdcOut += _swapExactInputDirect(token1, USDC, amount1, params.pool, effectiveSlippage);
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

    /**
     * @notice Claims AERO rewards for a single staked position
     * @param tokenId The position NFT token ID
     * @return aeroAmount Amount of AERO rewards claimed
     * @dev Only the position owner can claim rewards
     */
    function claimRewards(uint256 tokenId) 
        external 
        nonReentrant 
        returns (uint256 aeroAmount) 
    {
        // Check if position is staked and owned by sender
        address positionOwner = stakedPositionOwners[tokenId];
        
        if (positionOwner == address(0)) {
            // Position might be unstaked, check direct ownership
            positionOwner = POSITION_MANAGER.ownerOf(tokenId);
            require(positionOwner == msg.sender, "Not the owner of this position");
            
            // Unstaked positions don't earn AERO rewards
            return 0;
        }
        
        require(positionOwner == msg.sender, "Not the owner of this staked position");
        
        // Get position details to find the pool and gauge
        (,, address token0, address token1, int24 tickSpacing,,,,,,,) = POSITION_MANAGER.positions(tokenId);
        
        // Reconstruct pool address (we need to find it from token0, token1, tickSpacing)
        // This is a limitation - we might need to track pool addresses per position
        address pool = _findPoolFromTokens(token0, token1, tickSpacing);
        require(pool != address(0), "Pool not found");
        
        address gauge = _findGaugeForPool(pool);
        require(gauge != address(0), "No gauge for this pool");
        
        // Track AERO balance before claim
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        // Claim rewards from gauge
        IGauge(gauge).getReward(tokenId);
        
        // Calculate rewards claimed
        aeroAmount = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        
        // Transfer rewards to user
        if (aeroAmount > 0) {
            IERC20(AERO).transfer(msg.sender, aeroAmount);
            emit RewardsClaimed(msg.sender, tokenId, aeroAmount);
        }
        
        return aeroAmount;
    }

    /**
     * @notice Claims AERO rewards for all staked positions owned by an address
     * @param owner The address to claim rewards for
     * @return totalAeroAmount Total amount of AERO rewards claimed
     * @dev Only the owner can claim their rewards
     */
    function claimAllRewards(address owner) 
        external 
        nonReentrant 
        returns (uint256 totalAeroAmount) 
    {
        require(owner == msg.sender, "Can only claim own rewards");
        
        uint256[] memory positionIds = ownerPositionIds[owner];
        uint256 positionCount = positionIds.length;
        
        if (positionCount == 0) {
            return 0;
        }
        
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        // Iterate through all positions and claim rewards
        for (uint256 i = 0; i < positionCount; i++) {
            uint256 tokenId = positionIds[i];
            
            // Get position details
            (,, address token0, address token1, int24 tickSpacing,,,,,,,) = POSITION_MANAGER.positions(tokenId);
            
            // Find pool and gauge
            address pool = _findPoolFromTokens(token0, token1, tickSpacing);
            if (pool == address(0)) continue;
            
            address gauge = _findGaugeForPool(pool);
            if (gauge == address(0)) continue;
            
            // Claim rewards from gauge
            try IGauge(gauge).getReward(tokenId) {} catch {
                // Continue if claim fails for this position
                continue;
            }
        }
        
        // Calculate total rewards claimed
        totalAeroAmount = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        
        // Transfer all rewards to user
        if (totalAeroAmount > 0) {
            IERC20(AERO).transfer(owner, totalAeroAmount);
            emit AllRewardsClaimed(owner, totalAeroAmount, positionCount);
        }
        
        return totalAeroAmount;
    }

    // ============ Public View Functions ============

    /**
     * @notice Calculates optimal USDC allocation for a position
     * @param totalUSDC Total USDC amount to allocate
     * @param token0 First token address
     * @param token1 Second token address
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param pool Pool contract
     * @return usdc0 USDC amount to allocate for token0
     * @return usdc1 USDC amount to allocate for token1
     */
    function calculateOptimalUSDCAllocation(
        uint256 totalUSDC,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        ICLPool pool
    )
        public
        view
        returns (uint256 usdc0, uint256 usdc1)
    {
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

        // Get proper token decimals
        uint8 token0Decimals = _getTokenDecimals(token0);
        uint8 token1Decimals = _getTokenDecimals(token1);

        // Calculate token amounts based on prices
        // token0PriceInUSDC is in USDC units (6 decimals) per 1 token (with its native decimals)
        // To convert USDC amount to token amount: tokenAmount = usdcAmount * 10^tokenDecimals / price
        uint256 token0Amount = initialUsdc0 > 0 ? (initialUsdc0 * (10 ** token0Decimals)) / token0PriceInUSDC : 0;

        // Use SugarHelper to get the corresponding token1 amount needed
        uint256 token1Needed =
            SUGAR_HELPER.estimateAmount1(token0Amount, address(pool), sqrtPriceX96, tickLower, tickUpper);

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

    // ============ Internal Functions ============

    /**
     * @notice Analyzes routes to determine if sequential swapping is needed
     * @dev Checks for dependencies between token routes
     * @return needsSequential True if token1 depends on token0
     * @return intermediateToken The intermediate token to use
     */
    function _analyzeRoutes(
        SwapRoute memory token0Route,
        SwapRoute memory token1Route,
        address token0,
        address /* token1 */
    )
        internal
        pure
        returns (bool needsSequential, address intermediateToken)
    {
        // Check if token1 route starts with token0
        if (token1Route.tokens.length > 0 && token1Route.tokens[0] == token0) {
            return (true, token0);
        }

        // Check if both routes need the same intermediate token
        if (token0Route.tokens.length > 1 && token1Route.tokens.length > 1) {
            // If both routes go through the same intermediate token (e.g., both through cbBTC)
            if (token0Route.tokens[1] == token1Route.tokens[0]) {
                return (true, token0Route.tokens[1]);
            }
        }

        return (false, address(0));
    }

    /**
     * @notice Executes sequential swaps for dependent routes
     * @dev Handles cases where token1 depends on token0
     */
    function _executeSequentialSwaps(
        PositionParams memory params,
        address token0,
        address token1,
        address /* intermediateToken */,
        uint256 slippageBps
    )
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        ICLPool pool = ICLPool(params.pool);

        // Case 1: token1 route starts with token0 (e.g., cbBTC/LBTC where LBTC needs cbBTC)
        if (params.token1Route.tokens.length > 0 && params.token1Route.tokens[0] == token0) {
            // Calculate how much token0 we need in total
            // First, get the optimal allocation as if we had both tokens
            (, uint256 usdc1Equivalent) = calculateOptimalUSDCAllocation(
                params.usdcAmount, token0, token1, params.tickLower, params.tickUpper, pool
            );

            // Calculate how much token0 we need to get token1
            uint256 token0ForToken1 = 0;
            if (usdc1Equivalent > 0 && token1 != USDC) {
                // Estimate token0 amount needed for token1 based on price ratio
                uint256 token0Price = getTokenPriceViaOracle(token0);
                getTokenPriceViaOracle(token1);

                // Amount of token0 needed to get usdc1Equivalent worth of token1
                // token0Amount = (usdc1Equivalent / token0Price) * 1e18 (adjusting for decimals)
                uint256 token0Decimals = token0 == WETH ? 18 : (token0 == CBBTC ? 8 : 6);
                token0ForToken1 = (usdc1Equivalent * (10 ** token0Decimals)) / token0Price;
            }

            // Total USDC to swap to token0
            uint256 totalUsdcForToken0 = params.usdcAmount; // Use all USDC to get token0 first

            // Swap all USDC to token0
            uint256 totalToken0;
            if (params.token0Route.pools.length > 0) {
                totalToken0 = _executeSwapWithRoute(USDC, token0, totalUsdcForToken0, params.token0Route, slippageBps);
            } else {
                totalToken0 = _swapExactInputDirect(USDC, token0, totalUsdcForToken0, params.pool, slippageBps);
            }

            // Now split token0: some for position, some to swap to token1
            if (token1 != USDC && token0ForToken1 > 0 && token0ForToken1 < totalToken0) {
                // Swap portion of token0 to token1
                amount1 = _swapExactInputDirect(token0, token1, token0ForToken1, params.pool, slippageBps);
                amount0 = totalToken0 - token0ForToken1;
            } else if (token1 == USDC) {
                // token1 is USDC, no swap needed for it
                amount0 = totalToken0;
                amount1 = 0; // Will be handled by leftover USDC
            } else {
                // Edge case: use half for each
                uint256 halfToken0 = totalToken0 / 2;
                amount1 = _swapExactInputDirect(token0, token1, halfToken0, params.pool, slippageBps);
                amount0 = totalToken0 - halfToken0;
            }
        } else {
            // Case 2: Both tokens need the same intermediate (rare case)
            // For simplicity, split 50/50 and swap independently
            uint256 half = params.usdcAmount / 2;

            if (token0 != USDC) {
                amount0 = _executeSwapWithRoute(USDC, token0, half, params.token0Route, slippageBps);
            } else {
                amount0 = half;
            }

            if (token1 != USDC) {
                amount1 = _executeSwapWithRoute(USDC, token1, params.usdcAmount - half, params.token1Route, slippageBps);
            } else {
                amount1 = params.usdcAmount - half;
            }
        }
    }

    /**
     * @notice Gets token price in USDC via oracle
     * @param token Token address to get price for
     * @return price Token price in USDC with 6 decimals
     * @dev Tries multiple connectors for best route
     */
    function getTokenPriceViaOracle(address token) public view returns (uint256 price) {
        if (token == USDC) {
            return 1e6;
        }

        // Try different connectors in order: NONE, WETH, cbBTC (skip USDC since src is already USDC)
        address[3] memory connectors = [NONE_CONNECTOR, WETH, CBBTC];

        for (uint256 i = 0; i < connectors.length; i++) {
            try ORACLE.getRate(
                USDC, // from token (USDC)
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
        revert OraclePriceUnavailable();
    }

    /**
     * @notice Approves token to Swap Router
     * @param token Token address to approve
     * @param amount Amount to approve (uses max if needed)
     */
    function _approveTokenToRouter(address token, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), address(SWAP_ROUTER)) < amount) {
            IERC20(token).approve(address(SWAP_ROUTER), type(uint256).max);
        }
    }

    function _swapExactInputDirect(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address pool,
        uint256 slippageBps
    )
        internal
        returns (uint256 amountOut)
    {
        // Early return for zero amount
        if (amountIn == 0) {
            return 0;
        }

        // Early return if tokenIn and tokenOut are the same (no swap needed)
        if (tokenIn == tokenOut) {
            return amountIn;
        }

        // Calculate minAmountOut using quoter with the provided pool
        uint256 minAmountOut = _calculateMinimumOutput(tokenIn, tokenOut, amountIn, slippageBps, pool);

        // Ensure we have the tokens
        if (IERC20(tokenIn).balanceOf(address(this)) < amountIn) {
            revert InsufficientBalance();
        }

        // Get tick spacing from pool
        int24 tickSpacing = ICLPool(pool).tickSpacing();

        // Approve Swap Router to spend our tokens
        _approveTokenToRouter(tokenIn, amountIn);

        // Execute swap using Swap Router
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tickSpacing: tickSpacing,
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = SWAP_ROUTER.exactInputSingle(params);

        // Verify the output
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        uint256 actualReceived = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (actualReceived < minAmountOut) {
            revert InsufficientOutput(minAmountOut, actualReceived);
        }

        return actualReceived;
    }


    function _executeSwapWithRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        SwapRoute memory route,
        uint256 slippageBps
    )
        internal
        returns (uint256 amountOut)
    {
        // Early return for zero amount
        if (amountIn == 0) {
            return 0;
        }

        if (route.pools.length == 0) revert InvalidRoute();
        if (route.tokens.length != route.pools.length + 1) revert ArrayLengthMismatch();
        if (route.tickSpacings.length != route.pools.length) revert ArrayLengthMismatch();

        // For single-hop use the pool, for multi-hop pass address(0)
        address poolForQuote = route.pools.length == 1 ? route.pools[0] : address(0);
        uint256 minAmountOut = _calculateMinimumOutput(tokenIn, tokenOut, amountIn, slippageBps, poolForQuote);

        // Single hop swap
        if (route.pools.length == 1) {
            return _swapExactInputDirect(route.tokens[0], route.tokens[1], amountIn, route.pools[0], slippageBps);
        }

        // Multi-hop swap using exactInput with encoded path
        bytes memory path = _encodeMultihopPath(route);
        
        // Approve Swap Router
        _approveTokenToRouter(tokenIn, amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut
        });

        amountOut = SWAP_ROUTER.exactInput(params);

        // Verify the output
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        uint256 actualReceived = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (actualReceived < minAmountOut) {
            revert InsufficientOutput(minAmountOut, actualReceived);
        }

        return actualReceived;
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
    )
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = POSITION_MANAGER.positions(tokenId);

        // Get current pool state
        (uint160 sqrtPriceX96,,,,,) = ICLPool(pool).slot0();

        // Use SugarHelper to calculate amounts
        (amount0, amount1) = SUGAR_HELPER.getAmountsForLiquidity(
            sqrtPriceX96, getSqrtRatioAtTick(tickLower), getSqrtRatioAtTick(tickUpper), liquidity
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

    /**
     * @notice Removes a position ID from owner's tracking list
     * @param owner The owner address
     * @param tokenId The position ID to remove
     */
    function _removePositionFromOwner(address owner, uint256 tokenId) internal {
        uint256 index = positionIdIndex[tokenId];
        uint256 lastIndex = ownerPositionIds[owner].length - 1;

        if (index != lastIndex) {
            // Move the last element to the position being removed
            uint256 lastTokenId = ownerPositionIds[owner][lastIndex];
            ownerPositionIds[owner][index] = lastTokenId;
            positionIdIndex[lastTokenId] = index;
        }

        // Remove the last element
        ownerPositionIds[owner].pop();
        delete positionIdIndex[tokenId];
    }

    /**
     * @notice Calculates sqrt price from tick
     * @param tick The tick value
     * @return The sqrt price as Q96
     */
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > MAX_TICK) revert InvalidTickRange(tick, tick);

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
            if (ratio == 0) revert InvalidTickRange(tick, tick);
            ratio = type(uint256).max / ratio;
        }

        return uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /**
     * @notice Handles receipt of NFT positions
     * @dev Required for IERC721Receiver compliance
     */
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @notice Recovers stuck tokens
     * @param token Token address to recover
     * @param amount Amount to recover
     * @dev Only callable by wallet registry
     */
    function recoverToken(address token, uint256 amount) external {
        if (msg.sender != address(walletRegistry)) revert UnauthorizedAccess();
        IERC20(token).transfer(msg.sender, amount);
        emit TokensRecovered(token, msg.sender, amount);
    }


    // ============ Admin Functions ============

    /**
     * @notice Emergency recovery for stuck staked positions
     * @param tokenId The stuck position token ID
     * @param pool The pool address
     * @param recipient The address to send recovered funds to
     * @return usdcOut Amount of USDC recovered
     * @return aeroRewards Amount of AERO rewards recovered
     * @dev Only for positions without ownership records
     */
    function emergencyRecoverStakedPosition(
        uint256 tokenId,
        address pool,
        address recipient
    )
        external
        returns (uint256 usdcOut, uint256 aeroRewards)
    {
        if (msg.sender != address(walletRegistry)) revert UnauthorizedAccess();
        if (stakedPositionOwners[tokenId] != address(0)) revert UnauthorizedAccess();

        address gauge = _findGaugeForPool(pool);
        if (gauge == address(0)) revert GaugeNotFound();

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
        (,,,,,,, uint128 liquidity,,,,) = POSITION_MANAGER.positions(tokenId);

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
                amount0Min: 0, // Emergency recovery, accept any amount
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
            usdcOut += _swapExactInputDirect(token0, USDC, amount0, pool, 500); // 5% slippage for emergency
        } else if (token0 == USDC) {
            usdcOut = amount0;
        }

        if (token1 != USDC && amount1 > 0) {
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

    // ============ External View Functions ============

    /**
     * @notice Returns the owner of a staked position
     * @param tokenId The position NFT token ID
     * @return owner The owner address (address(0) if not staked)
     */
    function getStakedPositionOwner(uint256 tokenId) external view returns (address owner) {
        return stakedPositionOwners[tokenId];
    }

    /**
     * @notice Checks if a position is staked through this contract
     * @param tokenId The position NFT token ID
     * @return isStaked True if the position is staked
     */
    function isPositionStaked(uint256 tokenId) external view returns (bool isStaked) {
        return stakedPositionOwners[tokenId] != address(0);
    }

    /**
     * @notice Returns all staked position IDs for a given owner
     * @param owner The address to query positions for
     * @return positionIds Array of position IDs staked by the owner
     */
    function getStakedPositions(address owner) external view returns (uint256[] memory positionIds) {
        return ownerPositionIds[owner];
    }

    /**
     * @notice Calculates tick range from percentage
     * @param currentTick Current pool tick
     * @param rangePercentage Range percentage in basis points (500 = 5%)
     * @param tickSpacing Pool's tick spacing requirement
     * @return tickLower Aligned lower tick
     * @return tickUpper Aligned upper tick
     */
    function calculateTicksFromPercentage(
        int24 currentTick,
        uint256 rangePercentage,
        int24 tickSpacing
    ) public pure returns (int24 tickLower, int24 tickUpper) {
        // Calculate tick delta for the percentage range
        int24 tickDelta;
        
        // For pools with large tick spacing (>= 1000), use a more conservative approach
        // to avoid creating ranges that are too wide which cause PSC errors
        if (tickSpacing >= 1000) {
            // For high tick spacing pools, use the absolute minimum range
            // PSC errors occur when the range is too wide relative to current liquidity
            // Use only 1 tick space on each side of current tick
            tickDelta = tickSpacing;
        } else {
            // Original calculation for normal tick spacing pools
            // Using approximation: tickDelta ≈ percentage * 100
            // This is based on: tick = log₁.₀₀₀₁(price), so for X% price change:
            // tickDelta ≈ log₁.₀₀₀₁(1 + X/100) ≈ (X/100) * 10000 = X * 100
            tickDelta = int24(uint24(rangePercentage * 100));
            
            // Ensure minimum tick delta based on tick spacing
            if (tickDelta < tickSpacing * 2) {
                tickDelta = tickSpacing * 2; // At least 2 tick spaces wide
            }
        }
        
        // Calculate raw ticks
        int24 rawTickLower = currentTick - tickDelta;
        int24 rawTickUpper = currentTick + tickDelta;
        
        // Align to tick spacing
        // For lower tick: round down to nearest multiple of tickSpacing
        if (rawTickLower >= 0) {
            tickLower = (rawTickLower / tickSpacing) * tickSpacing;
        } else {
            // For negative numbers, we need to round down (more negative)
            tickLower = ((rawTickLower - tickSpacing + 1) / tickSpacing) * tickSpacing;
        }
        
        // For upper tick: round up to nearest multiple of tickSpacing
        if (rawTickUpper >= 0) {
            // Round up for positive numbers
            if (rawTickUpper % tickSpacing == 0) {
                tickUpper = rawTickUpper;
            } else {
                tickUpper = ((rawTickUpper / tickSpacing) + 1) * tickSpacing;
            }
        } else {
            // For negative numbers, round up means towards zero
            tickUpper = (rawTickUpper / tickSpacing) * tickSpacing;
        }
        
        // Ensure ticks are within valid range
        int24 MIN_TICK = -887272;
        int24 MAX_TICK_INT24 = 887272;
        
        if (tickLower < MIN_TICK) {
            // Align MIN_TICK to tick spacing when used as boundary
            tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        }
        if (tickUpper > MAX_TICK_INT24) {
            // Align MAX_TICK to tick spacing when used as boundary
            tickUpper = (MAX_TICK_INT24 / tickSpacing) * tickSpacing;
        }
        
        // Ensure minimum range (at least one tick spacing)
        if (tickUpper <= tickLower) {
            tickUpper = tickLower + tickSpacing;
        }
        
        return (tickLower, tickUpper);
    }

    function _calculateMinimumOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        address pool // Pool is already provided by the caller
    )
        internal
        returns (uint256 minAmountOut)
    {
        // Changed from view to non-view for quoter
        // Early return for zero amount
        if (amountIn == 0) {
            return 0;
        }

        // If tokens are the same, no swap needed
        if (tokenIn == tokenOut) {
            return amountIn;
        }

        // If no pool provided (multi-hop case), return minimum
        if (pool == address(0)) {
            // No direct pool available, use conservative minimum
            return 1;
        }

        // Get tick spacing from the provided pool
        int24 tickSpacing = ICLPool(pool).tickSpacing();

        // Quote the exact swap amount
        try QUOTER.quoteExactInputSingle(
            IMixedQuoter.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: tickSpacing,
                amountIn: amountIn,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut, uint160, uint32, uint256) {
            // Quoter provided expected output

            // Apply slippage to the quoted amount
            minAmountOut = (amountOut * (10_000 - slippageBps)) / 10_000;

            // Applied slippage tolerance
        } catch {
            // Fallback: quoter unavailable, use conservative minimum
            minAmountOut = 1; // Minimum 1 unit to ensure swap succeeds
        }

        // Ensure we always have some minimum to avoid complete loss
        if (minAmountOut == 0) {
            minAmountOut = 1;
        }
    }

    /**
     * @notice Gets detailed information about a single position
     * @param tokenId The position NFT token ID
     * @return info Detailed position information
     */
    function getPositionInfo(uint256 tokenId) external view returns (PositionInfo memory info) {
        // Get position data from NFT manager
        (
            ,
            ,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = POSITION_MANAGER.positions(tokenId);
        
        // Check if position exists
        require(liquidity > 0 || tokensOwed0 > 0 || tokensOwed1 > 0, "Position does not exist");
        
        // Find pool from tokens
        address pool = _findPoolFromTokens(token0, token1, tickSpacing);
        
        // Get current tick to check if in range
        bool inRange = false;
        if (pool != address(0)) {
            (, int24 currentTick,,,,) = ICLPool(pool).slot0();
            inRange = currentTick >= tickLower && currentTick <= tickUpper;
        }
        
        // Determine owner and staking status
        address owner;
        bool staked = false;
        address gaugeAddress = address(0);
        
        if (stakedPositionOwners[tokenId] != address(0)) {
            // Position is staked through this contract
            owner = stakedPositionOwners[tokenId];
            staked = true;
            gaugeAddress = _findGaugeForPool(pool);
        } else {
            // Position is not staked, get direct owner
            try POSITION_MANAGER.ownerOf(tokenId) returns (address nftOwner) {
                owner = nftOwner;
                // Check if owner is a gauge (staked outside this contract)
                if (pool != address(0)) {
                    address gauge = _findGaugeForPool(pool);
                    if (gauge != address(0) && nftOwner == gauge) {
                        staked = true;
                        gaugeAddress = gauge;
                        // We don't know the actual owner in this case
                        owner = address(0);
                    }
                }
            } catch {
                owner = address(0);
            }
        }
        
        // Calculate USD values
        uint256 currentValueUsd = _calculatePositionValueUsd(
            pool,
            liquidity,
            tickLower,
            tickUpper,
            token0,
            token1
        );
        
        uint256 unclaimedFeesUsd = _calculateUnclaimedFeesUsd(
            token0,
            token1,
            tokensOwed0,
            tokensOwed1
        );
        
        // Populate position info
        info = PositionInfo({
            id: tokenId,
            owner: owner,
            poolAddress: pool,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            tokensOwed0: tokensOwed0,
            tokensOwed1: tokensOwed1,
            inRange: inRange,
            currentValueUsd: currentValueUsd,
            unclaimedFeesUsd: unclaimedFeesUsd,
            staked: staked,
            gaugeAddress: gaugeAddress
        });
    }
    
    /**
     * @notice Gets detailed information about all positions owned by an address
     * @param owner The address to query positions for
     * @return infos Array of position information
     */
    function getAllPositionsInfo(address owner) external view returns (PositionInfo[] memory infos) {
        // Get staked positions tracked by this contract
        uint256[] memory stakedIds = ownerPositionIds[owner];
        uint256 stakedCount = stakedIds.length;
        
        // Create array for all positions (we'll resize later if needed)
        PositionInfo[] memory tempInfos = new PositionInfo[](stakedCount + 100); // Assume max 100 unstaked
        uint256 actualCount = 0;
        
        // Add staked positions
        for (uint256 i = 0; i < stakedCount; i++) {
            try this.getPositionInfo(stakedIds[i]) returns (PositionInfo memory info) {
                tempInfos[actualCount] = info;
                actualCount++;
            } catch {
                // Skip if position doesn't exist or has issues
                continue;
            }
        }
        
        // Note: We can't easily enumerate all NFTs owned by an address
        // The caller should track their unstaked position IDs separately
        // or use a subgraph/indexer for complete enumeration
        
        // Copy to correctly sized array
        infos = new PositionInfo[](actualCount);
        for (uint256 i = 0; i < actualCount; i++) {
            infos[i] = tempInfos[i];
        }
    }
    
    // ============ Internal Helper Functions ============
    
    /**
     * @notice Finds a pool address from token addresses and tick spacing
     * @param token0 First token address
     * @param token1 Second token address
     * @param tickSpacing Tick spacing of the pool
     * @return pool The pool address, or address(0) if not found
     */
    function _findPoolFromTokens(
        address token0,
        address token1,
        int24 tickSpacing
    ) internal view returns (address pool) {
        // This is a simplified implementation
        // In production, you'd want to use the factory's getPool function
        // or maintain a mapping of position -> pool
        
        // Try common pools based on tick spacing
        if (tickSpacing == 100) {
            // Most common for volatile pairs
            pool = _getPoolAddress(token0, token1, tickSpacing);
        } else if (tickSpacing == 1) {
            // Stable pairs
            pool = _getPoolAddress(token0, token1, tickSpacing);
        } else {
            // Other tick spacings
            pool = _getPoolAddress(token0, token1, tickSpacing);
        }
        
        // Verify pool exists by checking code size
        uint256 size;
        assembly {
            size := extcodesize(pool)
        }
        
        if (size == 0) {
            return address(0);
        }
        
        // Verify it's actually a pool with matching tokens
        try ICLPool(pool).token0() returns (address poolToken0) {
            try ICLPool(pool).token1() returns (address poolToken1) {
                if ((poolToken0 == token0 && poolToken1 == token1) ||
                    (poolToken0 == token1 && poolToken1 == token0)) {
                    return pool;
                }
            } catch {}
        } catch {}
        
        return address(0);
    }
    
    /**
     * @notice Calculates pool address deterministically
     * @dev This would need the actual factory's pool creation logic
     */
    function _getPoolAddress(
        address token0,
        address token1,
        int24 tickSpacing
    ) internal pure returns (address) {
        // Placeholder - would need actual factory logic
        // In production, use factory.getPool() or similar
        return address(uint160(uint256(keccak256(abi.encodePacked(token0, token1, tickSpacing)))));
    }
    
    /**
     * @notice Calculates the USD value of a position
     */
    function _calculatePositionValueUsd(
        address pool,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        address token0,
        address token1
    ) internal view returns (uint256 valueUsd) {
        if (liquidity == 0 || pool == address(0)) {
            return 0;
        }
        
        // Get current pool price
        (uint160 sqrtPriceX96, int24 currentTick,,,,) = ICLPool(pool).slot0();
        
        // Calculate token amounts at current price
        (uint256 amount0, uint256 amount1) = _getTokenAmountsFromLiquidity(
            liquidity,
            sqrtPriceX96,
            tickLower,
            tickUpper,
            currentTick
        );
        
        // Get token prices in USD
        uint256 token0PriceUsd = _getTokenPriceUsd(token0);
        uint256 token1PriceUsd = _getTokenPriceUsd(token1);
        
        // Calculate total USD value
        // Prices are in 18 decimals, amounts need decimal adjustment
        uint8 decimals0 = _getTokenDecimals(token0);
        uint8 decimals1 = _getTokenDecimals(token1);
        
        valueUsd = (amount0 * token0PriceUsd / (10 ** decimals0)) +
                   (amount1 * token1PriceUsd / (10 ** decimals1));
    }
    
    /**
     * @notice Calculates the USD value of unclaimed fees
     */
    function _calculateUnclaimedFeesUsd(
        address token0,
        address token1,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) internal view returns (uint256 feesUsd) {
        if (tokensOwed0 == 0 && tokensOwed1 == 0) {
            return 0;
        }
        
        // Get token prices in USD
        uint256 token0PriceUsd = _getTokenPriceUsd(token0);
        uint256 token1PriceUsd = _getTokenPriceUsd(token1);
        
        // Calculate fees USD value
        uint8 decimals0 = _getTokenDecimals(token0);
        uint8 decimals1 = _getTokenDecimals(token1);
        
        feesUsd = (uint256(tokensOwed0) * token0PriceUsd / (10 ** decimals0)) +
                  (uint256(tokensOwed1) * token1PriceUsd / (10 ** decimals1));
    }
    
    /**
     * @notice Gets token price in USD from oracle
     */
    function _getTokenPriceUsd(address token) internal view returns (uint256 priceUsd) {
        if (token == USDC) {
            return 1e18; // USDC = $1 with 18 decimals
        }
        
        // Try to get price from oracle
        try ORACLE.getRate(token, USDC, NONE_CONNECTOR, 0) returns (uint256 rate, uint256) {
            return rate; // Rate is already in 18 decimals
        } catch {
            // If direct rate fails, try with WETH as connector
            try ORACLE.getRate(token, USDC, WETH, 0) returns (uint256 rate, uint256) {
                return rate;
            } catch {
                return 0; // Price unavailable
            }
        }
    }
    
    /**
     * @notice Gets token decimals
     */
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == USDC) return 6;
        if (token == WETH) return 18;
        if (token == CBBTC) return 8;
        if (token == AERO) return 18;
        
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18; // Default to 18 decimals
        }
    }
    
    /**
     * @notice Calculates token amounts from liquidity
     * @dev Simplified calculation - in production use proper Uniswap V3 math
     */
    function _getTokenAmountsFromLiquidity(
        uint128 liquidity,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) return (0, 0);
        
        // These calculations are simplified
        // In production, use proper Uniswap V3 liquidity math
        
        if (currentTick < tickLower) {
            // Position is entirely in token0
            amount0 = uint256(liquidity) * 1e18 / uint256(sqrtPriceX96);
            amount1 = 0;
        } else if (currentTick >= tickUpper) {
            // Position is entirely in token1
            amount0 = 0;
            amount1 = uint256(liquidity) * uint256(sqrtPriceX96) / 1e18;
        } else {
            // Position is in range, split between both tokens
            // Simplified calculation
            amount0 = uint256(liquidity) * 1e18 / uint256(sqrtPriceX96) / 2;
            amount1 = uint256(liquidity) * uint256(sqrtPriceX96) / 1e18 / 2;
        }
    }
}
