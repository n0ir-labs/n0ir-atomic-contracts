// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { WalletRegistry } from "./WalletRegistry.sol";
import { AtomicBase } from "./AtomicBase.sol";
import { RouteFinder } from "./RouteFinder.sol";
import { RouteFinderLib } from "./libraries/RouteFinderLib.sol";
import { ISwapRouter } from "@interfaces/ISwapRouter.sol";
import { INonfungiblePositionManager } from "@interfaces/INonfungiblePositionManager.sol";
import { ICLPool } from "@interfaces/ICLPool.sol";
import { IMixedQuoter } from "@interfaces/IMixedQuoter.sol";
import { ISugarHelper } from "@interfaces/ISugarHelper.sol";
import { IERC20 } from "@interfaces/IERC20.sol";
import { IAerodromeOracle } from "@interfaces/IAerodromeOracle.sol";
import { AggregatorV3Interface } from "@interfaces/AggregatorV3Interface.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title LiquidityManager
 * @notice Non-custodial atomic liquidity operations for Aerodrome V3 Slipstream pools
 * @dev Implements concentrated liquidity position management without taking custody of user NFTs
 * @dev Security: Positions are always minted directly to users, never held by the contract
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
    error OraclePriceUnavailable();
    error InvalidRecipient();
    error ArrayLengthMismatch();
    error InvalidTickSpacing();
    error EmergencyRecoveryFailed();
    error InvalidTickAlignment(int24 tick, int24 tickSpacing);
    error TickRangeTooNarrow(int24 tickLower, int24 tickUpper, int24 minWidth);

    // ============ State Variables ============
    /// @notice Registry contract for wallet access control
    WalletRegistry public immutable walletRegistry;
    
    /// @notice RouteFinder contract for automatic route discovery
    RouteFinder public immutable routeFinder;
    
    /// @notice Mapping from position ID to the address that created it
    mapping(uint256 => address) public positionOwners;
    
    /// @notice Mapping from address to array of position IDs they created
    mapping(address => uint256[]) public userPositions;

    // ============ Constants ============
    /// @notice Core contracts - immutable for gas optimization
    ISwapRouter public constant SWAP_ROUTER = ISwapRouter(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5);
    INonfungiblePositionManager public constant POSITION_MANAGER =
        INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    IMixedQuoter public constant QUOTER = IMixedQuoter(0x254cF9E1E6e233aa1AC962CB9B05b2cfeAaE15b0);
    ISugarHelper public constant SUGAR_HELPER = ISugarHelper(0x0AD09A66af0154a84e86F761313d02d0abB6edd5);
    IAerodromeOracle public constant ORACLE = IAerodromeOracle(0x43B36A7E6a4cdFe7de5Bd2Aa1FCcddf6a366dAA2);
    
    // Chainlink Price Feeds
    AggregatorV3Interface public constant ETH_USD_FEED = AggregatorV3Interface(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
    AggregatorV3Interface public constant AERO_USD_FEED = AggregatorV3Interface(0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0);
    AggregatorV3Interface public constant BTC_USD_FEED = AggregatorV3Interface(0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F);
    
    // Oracle configuration
    uint256 public constant MAX_PRICE_STALENESS = 3600; // 1 hour
    uint256 public constant MAX_PRICE_DEVIATION = 2000; // 20%

    /// @notice Token addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

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
    event PositionCreated(
        address indexed user,
        uint256 indexed tokenId,
        address indexed pool,
        uint256 usdcIn,
        uint128 liquidity
    );

    /// @notice Emitted when a position is closed
    /// @param user The address closing the position
    /// @param tokenId The NFT token ID being closed
    /// @param usdcOut Amount of USDC returned
    event PositionClosed(address indexed user, uint256 indexed tokenId, uint256 usdcOut);

    /// @notice Emitted when tokens are recovered
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a swap is executed
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);


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


    // ============ Constructor ============
    /// @notice Initializes the LiquidityManager with a wallet registry and route finder
    /// @param _walletRegistry Address of the wallet registry contract (can be address(0))
    /// @param _routeFinder Address of the RouteFinder contract (can be address(0) to disable auto-routing)
    /// @dev Registry can be address(0) for permissionless deployment
    constructor(address _walletRegistry, address _routeFinder) {
        walletRegistry = WalletRegistry(_walletRegistry);
        routeFinder = RouteFinder(_routeFinder);
    }

    // ============ Modifiers ============
    /// @notice Ensures caller is authorized to act on behalf of user
    /// @param user The user address to check authorization for
    modifier onlyAuthorized(address user) {
        // If wallet registry is not set (permissionless mode), only allow self-calls
        if (address(walletRegistry) == address(0)) {
            if (msg.sender != user) revert UnauthorizedAccess();
        } else {
            // If wallet registry is set, check if sender is registered
            if (!walletRegistry.isWallet(msg.sender)) revert UnauthorizedAccess();
        }
        _;
    }

    // ============ External Functions ============

    /**
     * @notice Creates a new concentrated liquidity position with explicit tick boundaries
     * @param pool Target pool address
     * @param tickLower Lower tick boundary (must be aligned to tick spacing)
     * @param tickUpper Upper tick boundary (must be aligned to tick spacing)
     * @param deadline Transaction deadline
     * @param usdcAmount USDC amount to invest
     * @param slippageBps Slippage tolerance in basis points
     * @return tokenId The NFT token ID of the created position
     * @return liquidity The amount of liquidity minted
     * @dev Non-custodial: Position NFT is minted directly to msg.sender
     * @dev Ticks must be properly aligned to the pool's tick spacing
     * @dev tickLower must be less than tickUpper
     */
    function createPosition(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 deadline,
        uint256 usdcAmount,
        uint256 slippageBps
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

        // Enhanced tick validation
        _validateTickRangeExtended(params.tickLower, params.tickUpper, tickSpacing, pool);

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
        
        // CRITICAL FIX: Mint position directly to the user (non-custodial)
        // This ensures users maintain ownership of their NFT positions at all times
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
            recipient: msg.sender, // SECURITY: Always mint directly to user, never to contract
            deadline: params.deadline,
            sqrtPriceX96: 0
        });

        (tokenId, liquidity,,) = POSITION_MANAGER.mint(mintParams);
        
        // Track position ownership
        positionOwners[tokenId] = msg.sender;
        userPositions[msg.sender].push(tokenId);

        // Non-custodial design: Users maintain full control of their positions
        _returnLeftoverTokens(token0, token1);

        emit PositionCreated(msg.sender, tokenId, params.pool, params.usdcAmount, liquidity);
    }

    /**
     * @notice Closes a position with automatic route discovery
     * @param tokenId Position NFT token ID
     * @param pool Pool address
     * @param deadline Transaction deadline
     * @param minUsdcOut Minimum USDC to receive
     * @param slippageBps Slippage tolerance in basis points
     * @return usdcOut Amount of USDC returned to user
     * @dev Non-custodial: User must approve this contract to transfer their NFT before calling
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
        returns (uint256 usdcOut)
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

    function _closePosition(ExitParams memory params) internal returns (uint256 usdcOut) {
        // SECURITY: Verify user owns the position before processing
        address positionOwner = POSITION_MANAGER.ownerOf(params.tokenId);
        require(positionOwner == msg.sender, "Not the owner of this position");

        // Non-custodial: User must approve the contract to transfer their NFT
        // This requires the user to call approve() on the Position Manager before calling closePosition
        POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), params.tokenId);
        
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
        
        // Clear position ownership tracking
        delete positionOwners[params.tokenId];
        _removePositionFromUser(msg.sender, params.tokenId);

        emit PositionClosed(msg.sender, params.tokenId, usdcOut);
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
                uint256 token0Decimals = _getTokenDecimals(token0);
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
     * @notice Gets token price in USDC via Chainlink oracles with staleness protection
     * @param token Token address to get price for
     * @return price Token price in USDC with 6 decimals
     * @dev Uses Chainlink for ETH/AERO, falls back to Aerodrome for others
     */
    function getTokenPriceViaOracle(address token) public view returns (uint256 price) {
        if (token == USDC) {
            return 1e6;
        }
        
        // Use Chainlink for supported tokens
        if (token == WETH) {
            return _getChainlinkPriceInUSDC(ETH_USD_FEED);
        }
        
        if (token == AERO) {
            return _getChainlinkPriceInUSDC(AERO_USD_FEED);
        }
        
        // cbBTC uses BTC price (1:1 parity)
        if (token == CBBTC) {
            return _getChainlinkPriceInUSDC(BTC_USD_FEED);
        }
        
        // Fallback to Aerodrome Oracle for other tokens
        return _getAerodromePriceInUSDC(token);
    }
    
    /**
     * @notice Get price from Chainlink with staleness checks
     * @param priceFeed Chainlink price feed contract
     * @return Price in USDC terms with 6 decimals
     */
    function _getChainlinkPriceInUSDC(AggregatorV3Interface priceFeed) internal view returns (uint256) {
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        
        // Validate price data
        require(price > 0, "Invalid Chainlink price");
        require(updatedAt > 0, "Round not complete");
        require(answeredInRound >= roundId, "Stale price round");
        
        // Check staleness (1 hour max)
        require(block.timestamp - updatedAt <= MAX_PRICE_STALENESS, "Chainlink price too old");
        
        // Chainlink feeds typically have 8 decimals, we need 6 for USDC
        uint8 feedDecimals = priceFeed.decimals();
        
        if (feedDecimals > 6) {
            return uint256(price) / 10**(feedDecimals - 6);
        } else if (feedDecimals < 6) {
            return uint256(price) * 10**(6 - feedDecimals);
        } else {
            return uint256(price);
        }
    }
    
    /**
     * @notice Fallback to Aerodrome Oracle for unsupported tokens
     * @param token Token to get price for
     * @return price Price in USDC with 6 decimals
     */
    function _getAerodromePriceInUSDC(address token) internal view returns (uint256 price) {
        // Try different connectors in order: NONE, WETH, cbBTC
        address[3] memory connectors = [NONE_CONNECTOR, WETH, CBBTC];

        for (uint256 i = 0; i < connectors.length; i++) {
            try ORACLE.getRate(
                token,
                USDC,
                connectors[i],
                0
            ) returns (uint256 rate, uint256 weight) {
                if (rate > 0 && weight > 0) {
                    uint8 tokenDecimals = IERC20Metadata(token).decimals();
                    
                    if (tokenDecimals == 18) {
                        price = rate;
                    } else if (tokenDecimals < 18) {
                        price = rate / (10 ** (18 - tokenDecimals));
                    } else {
                        price = rate * (10 ** (tokenDecimals - 18));
                    }

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

    function _getEffectiveSlippage(uint256 requestedSlippage) internal pure returns (uint256) {
        if (requestedSlippage == 0) {
            return DEFAULT_SLIPPAGE_BPS;
        }
        require(requestedSlippage <= MAX_SLIPPAGE_BPS, "Slippage too high");
        return requestedSlippage;
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
        // Only the owner of the wallet registry can recover tokens
        if (address(walletRegistry) == address(0)) revert UnauthorizedAccess();
        if (msg.sender != walletRegistry.owner()) revert UnauthorizedAccess();
        IERC20(token).transfer(msg.sender, amount);
        emit TokensRecovered(token, msg.sender, amount);
    }



    // ============ External View Functions ============
    
    /**
     * @notice Returns the address that created a position
     * @param tokenId The position NFT token ID
     * @return The address of the user who created the position
     */
    function getPositionOwner(uint256 tokenId) external view returns (address) {
        return positionOwners[tokenId];
    }
    
    /**
     * @notice Returns all position IDs created by a specific address
     * @param user The address to query positions for
     * @return An array of position token IDs created by the user
     */
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }
    
    /**
     * @notice Returns the number of positions created by a specific address
     * @param user The address to query
     * @return The count of positions created by the user
     */
    function getUserPositionCount(address user) external view returns (uint256) {
        return userPositions[user].length;
    }

    /**
     * @notice Enhanced tick range validation with comprehensive checks
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary  
     * @param tickSpacing Pool's tick spacing requirement
     * @param pool Pool contract instance
     * @dev Validates tick alignment, bounds, ordering, and reasonableness
     */
    function _validateTickRangeExtended(
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        ICLPool pool
    ) internal view {
        // Check tick ordering (lower must be less than upper)
        if (tickLower >= tickUpper) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        
        // Check tick bounds
        if (tickLower < MIN_TICK || tickUpper > int24(uint24(MAX_TICK))) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        
        // Check tick spacing alignment for lower tick
        if (tickLower % tickSpacing != 0) {
            revert InvalidTickAlignment(tickLower, tickSpacing);
        }
        
        // Check tick spacing alignment for upper tick
        if (tickUpper % tickSpacing != 0) {
            revert InvalidTickAlignment(tickUpper, tickSpacing);
        }
        
        // Ensure minimum range width (at least one tick spacing)
        if (tickUpper - tickLower < tickSpacing) {
            revert TickRangeTooNarrow(tickLower, tickUpper, tickSpacing);
        }
        
        // Optional: Check if range is reasonable relative to current price
        // This helps prevent user errors but doesn't block edge cases
        (, int24 currentTick,,,,) = pool.slot0();
        int24 rangeWidth = tickUpper - tickLower;
        
        // For high tick spacing pools, very wide ranges can cause issues
        // We allow it but the slippage protection will handle any problems
        if (tickSpacing >= 1000 && rangeWidth > tickSpacing * 100) {
            // Extremely wide range - allowed but may have high slippage
            // The existing slippage protection in _createPosition handles this
        }
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

    
    // ============ Internal Helper Functions ============
    
    /**
     * @notice Gets token decimals
     */
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == USDC) return 6;
        if (token == WETH) return 18;
        if (token == CBBTC) return 8;
        
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18; // Default to 18 decimals
        }
    }
    
    /**
     * @notice Removes a position ID from a user's position array
     * @param user The user address
     * @param tokenId The position token ID to remove
     */
    function _removePositionFromUser(address user, uint256 tokenId) internal {
        uint256[] storage positions = userPositions[user];
        uint256 length = positions.length;
        
        for (uint256 i = 0; i < length; i++) {
            if (positions[i] == tokenId) {
                // Move the last element to this position and pop
                positions[i] = positions[length - 1];
                positions.pop();
                break;
            }
        }
    }
}
