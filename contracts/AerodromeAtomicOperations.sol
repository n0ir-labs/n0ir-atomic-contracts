// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./AtomicBase.sol";
import "./CDPWalletRegistry.sol";
import "@interfaces/IUniversalRouter.sol";
import "@interfaces/IPermit2.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IGauge.sol";
import "@interfaces/ICLPool.sol";
import "@interfaces/IMixedQuoter.sol";
import "@interfaces/ISugarHelper.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/IGaugeFactory.sol";
import "@interfaces/ILpSugar.sol";
import "@interfaces/IVoter.sol";
import "@interfaces/IOffchainOracle.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title AerodromeAtomicOperations
 * @author N0IR
 * @notice Atomic operations with oracle integration for accurate pricing
 * @dev Uses 1inch Offchain Oracle for USD price discovery
 */
contract AerodromeAtomicOperations is AtomicBase, IERC721Receiver {
    /// @notice CDP Wallet Registry for access control
    CDPWalletRegistry public immutable walletRegistry;
    
    /// @notice Aerodrome Universal Router for token swaps
    IUniversalRouter public constant UNIVERSAL_ROUTER = IUniversalRouter(0x01D40099fCD87C018969B0e8D4aB1633Fb34763C);
    /// @notice Permit2 contract for token approvals
    IPermit2 public constant PERMIT2 = IPermit2(0x494bbD8A3302AcA833D307D11838f18DbAdA9C25);
    /// @notice NFT Position Manager for CL positions
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    /// @notice Quoter for calculating swap amounts
    IMixedQuoter public constant QUOTER = IMixedQuoter(0x0A5aA5D3a4d28014f967Bf0f29EAA3FF9807D5c6);
    /// @notice SugarHelper for liquidity calculations
    ISugarHelper public constant SUGAR_HELPER = ISugarHelper(0x0AD09A66af0154a84e86F761313d02d0abB6edd5);
    /// @notice 1inch Offchain Oracle for price discovery
    IOffchainOracle public constant ORACLE = IOffchainOracle(0x288a124CB87D7c95656Ad7512B7Da733Bb60A432);
    /// @notice Gauge Factory for finding gauges
    address public constant GAUGE_FACTORY = 0xD30677bd8dd15132F251Cb54CbDA552d2A05Fb08;
    /// @notice Voter contract for gauge lookups
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    /// @notice USDC token address on Base
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @notice AERO token address on Base
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    /// @notice WETH token address on Base
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    
    /// @notice Default slippage tolerance (1%)
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 100; // 1%
    /// @notice Maximum allowed slippage tolerance (10%)
    uint256 private constant MAX_SLIPPAGE_BPS = 1000; // 10%
    /// @notice Q96 for sqrt price calculations
    uint256 private constant Q96 = 2**96;
    
    /**
     * @notice Emitted when a new position is opened
     * @param user The user who opened the position
     * @param tokenId The ID of the minted position NFT
     * @param pool The pool address
     * @param usdcIn The amount of USDC used
     * @param liquidity The amount of liquidity minted
     * @param staked Whether the position was staked
     */
    event PositionOpened(
        address indexed user,
        uint256 indexed tokenId,
        address indexed pool,
        uint256 usdcIn,
        uint128 liquidity,
        bool staked
    );
    
    /**
     * @notice Emitted when a position is closed
     * @param user The user who closed the position
     * @param tokenId The ID of the closed position
     * @param usdcOut The amount of USDC received
     * @param aeroRewards The amount of AERO rewards collected
     */
    event PositionClosed(
        address indexed user,
        uint256 indexed tokenId,
        uint256 usdcOut,
        uint256 aeroRewards
    );
    
    /**
     * @notice Defines a swap route through one or more pools
     * @param pools Ordered list of pool addresses for the route
     * @param tokens Ordered list of token addresses (length = pools.length + 1)
     * @param tickSpacings Tick spacing for each pool in the route
     */
    struct SwapRoute {
        address[] pools;
        address[] tokens;
        int24[] tickSpacings;
    }
    
    /**
     * @notice Parameters for swapping and minting a position
     * @param pool The pool address for the position
     * @param tickLower The lower tick of the range
     * @param tickUpper The upper tick of the range
     * @param deadline The deadline timestamp for the transaction
     * @param usdcAmount The amount of USDC to use
     * @param slippageBps Custom slippage tolerance in basis points (0 = use default)
     * @param stake Whether to stake the position in the gauge
     * @param token0Route Route from USDC to token0 (empty = direct swap)
     * @param token1Route Route from USDC to token1 (empty = direct swap)
     */
    struct SwapMintParams {
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
    
    /**
     * @notice Parameters for exiting a position
     * @param tokenId The ID of the position to exit
     * @param pool The pool address of the position
     * @param deadline The deadline timestamp for the transaction
     * @param minUsdcOut The minimum USDC to receive after exit
     * @param slippageBps Custom slippage tolerance in basis points (0 = use default)
     * @param token0Route Optional custom route from token0 to USDC (empty = direct swap)
     * @param token1Route Optional custom route from token1 to USDC (empty = direct swap)
     */
    struct FullExitParams {
        uint256 tokenId;
        address pool;
        uint256 deadline;
        uint256 minUsdcOut;
        uint256 slippageBps;
        SwapRoute token0Route;
        SwapRoute token1Route;
    }
    
    /**
     * @notice Creates the contract with optional CDP registry
     * @param _walletRegistry Optional CDP wallet registry for access control
     */
    constructor(address _walletRegistry) {
        walletRegistry = CDPWalletRegistry(_walletRegistry);
    }
    
    /**
     * @notice Checks if the caller is authorized (either direct owner or CDP wallet)
     * @param user The user address to check
     */
    modifier onlyAuthorized(address user) {
        require(
            msg.sender == user || 
            (address(walletRegistry) != address(0) && walletRegistry.isRegisteredWallet(msg.sender)),
            "Unauthorized"
        );
        _;
    }
    
    /**
     * @notice Swaps USDC for pool tokens and mints a concentrated liquidity position
     * @dev Can optionally stake the position in the gauge
     * @param params The parameters for the swap and mint operation
     * @return tokenId The ID of the minted position NFT
     * @return liquidity The amount of liquidity minted
     */
    function swapMintAndStake(SwapMintParams calldata params)
        external
        nonReentrant
        deadlineCheck(params.deadline)
        validAmount(params.usdcAmount)
        onlyAuthorized(msg.sender)
        returns (uint256 tokenId, uint128 liquidity)
    {
        return _swapMintAndStake(params);
    }
    
    /**
     * @notice Internal implementation of swap, mint, and optional stake
     * @param params The parameters for the operation
     * @return tokenId The ID of the minted position NFT
     * @return liquidity The amount of liquidity minted
     */
    function _swapMintAndStake(SwapMintParams memory params)
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
        
        // Get effective slippage for this operation
        uint256 effectiveSlippage = _getEffectiveSlippage(params.slippageBps);
        
        // Calculate optimal swap amounts using oracle and SugarHelper
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
        if (token0 == USDC && usdc0 > 0) {
            // Token0 is USDC, no swap needed
            amount0 = usdc0;
        } else if (usdc0 > 0) {
            // Need to swap USDC to token0
            _approveUniversalRouterViaPermit2(USDC, usdc0);
            
            // Use custom route if provided and valid
            if (params.token0Route.pools.length > 0) {
                // Validate route starts with USDC and ends with token0
                require(
                    params.token0Route.tokens.length > 0 && 
                    params.token0Route.tokens[0] == USDC && 
                    params.token0Route.tokens[params.token0Route.tokens.length - 1] == token0,
                    "Invalid token0 route"
                );
                amount0 = _executeSwapWithRoute(params.token0Route, usdc0, 0);
            } else {
                // Direct swap USDC -> token0
                amount0 = _swapExactInputDirect(USDC, token0, usdc0, 0, params.pool);
            }
        }
        
        // Handle token1 swap
        if (token1 == USDC && usdc1 > 0) {
            // Token1 is USDC, no swap needed
            amount1 = usdc1;
        } else if (usdc1 > 0) {
            // Need to swap USDC to token1
            _approveUniversalRouterViaPermit2(USDC, usdc1);
            
            // Use custom route if provided and valid
            if (params.token1Route.pools.length > 0) {
                // Validate route starts with USDC and ends with token1
                require(
                    params.token1Route.tokens.length > 0 && 
                    params.token1Route.tokens[0] == USDC && 
                    params.token1Route.tokens[params.token1Route.tokens.length - 1] == token1,
                    "Invalid token1 route"
                );
                amount1 = _executeSwapWithRoute(params.token1Route, usdc1, 0);
            } else {
                // Direct swap USDC -> token1
                amount1 = _swapExactInputDirect(USDC, token1, usdc1, 0, params.pool);
            }
        }
        
        // Approve position manager
        if (amount0 > 0) _safeApprove(token0, address(POSITION_MANAGER), amount0);
        if (amount1 > 0) _safeApprove(token1, address(POSITION_MANAGER), amount1);
        
        // Calculate minimum amounts with slippage
        uint256 amount0Min = (amount0 * (10000 - effectiveSlippage)) / 10000;
        uint256 amount1Min = (amount1 * (10000 - effectiveSlippage)) / 10000;
        
        // Mint position
        (tokenId, liquidity,,) = POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
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
                sqrtPriceX96: 0 // Let the pool use its current price
            })
        );
        
        // Stake if requested
        if (params.stake) {
            address gauge = _findGaugeForPool(params.pool);
            if (gauge != address(0)) {
                POSITION_MANAGER.approve(gauge, tokenId);
                IGauge(gauge).deposit(tokenId);
            } else {
                // If no gauge found, return position to user
                POSITION_MANAGER.safeTransferFrom(address(this), msg.sender, tokenId);
            }
        }
        
        // Return any leftover tokens
        _returnLeftoverTokens(token0, token1);
        
        emit PositionOpened(msg.sender, tokenId, params.pool, params.usdcAmount, liquidity, params.stake);
    }
    
    /**
     * @notice Calculates optimal USDC allocation using oracle prices and liquidity math
     * @dev Uses 1inch Oracle for prices and SugarHelper for liquidity calculations
     */
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
        
        // In-range position: calculate optimal ratio
        // Get USD prices from oracle
        uint256 token0PriceInUSDC = getTokenPriceViaOracle(token0);
        uint256 token1PriceInUSDC = getTokenPriceViaOracle(token1);
        
        // Start with an initial guess based on current tick position in range
        uint256 tickRange = uint256(int256(tickUpper - tickLower));
        uint256 tickPosition = uint256(int256(currentTick - tickLower));
        uint256 token1Ratio = (tickPosition * 100) / tickRange;
        
        // Initial allocation
        uint256 initialUsdc1 = (totalUSDC * token1Ratio) / 100;
        uint256 initialUsdc0 = totalUSDC - initialUsdc1;
        
        // Convert USDC amounts to token amounts
        // Oracle returns price as USDC per token (e.g., 1 WETH = 3595e6 USDC)
        // To get token amount: USDC amount * token decimals / price
        uint256 token0Decimals = token0 == WETH ? 18 : 6;
        uint256 token1Decimals = token1 == WETH ? 18 : 6;
        
        // For WETH: 100 USDC = 100e6 * 1e18 / 3595e6 = amount in wei
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
        // Token amount * price / token decimals = USDC value
        uint256 usdc0Value = (token0Amount * token0PriceInUSDC) / (10 ** token0Decimals);
        uint256 usdc1Value = (token1Needed * token1PriceInUSDC) / (10 ** token1Decimals);
        
        // Scale to match totalUSDC exactly
        uint256 totalValue = usdc0Value + usdc1Value;
        if (totalValue > 0) {
            usdc0 = (usdc0Value * totalUSDC) / totalValue;
            usdc1 = totalUSDC - usdc0;
        } else {
            // Fallback to 50/50 if calculation fails
            usdc0 = totalUSDC / 2;
            usdc1 = totalUSDC - usdc0;
        }
        
        return (usdc0, usdc1);
    }
    
    /**
     * @notice Gets token price in USDC using the oracle
     * @param token The token to price
     * @return price The price in USDC with 18 decimals precision
     */
    function getTokenPriceViaOracle(address token) public view returns (uint256 price) {
        if (token == USDC) {
            return 1e6; // 1 USDC = 1 USDC (USDC has 6 decimals)
        }
        
        try ORACLE.getRate(token, USDC, false) returns (uint256 rate) {
            // Oracle returns how many USDC (with 6 decimals) per 1 token (with token decimals)
            // For WETH: returns ~3595e6 meaning 1 WETH = 3595 USDC
            return rate;
        } catch {
            // Fallback: try to get rate via ETH
            try ORACLE.getRateToEth(token, false) returns (uint256 tokenToEth) {
                try ORACLE.getRateToEth(USDC, false) returns (uint256 usdcToEth) {
                    // Calculate token/USDC rate
                    // Both rates are in ETH, so division gives us token/USDC ratio
                    return (tokenToEth * 1e6) / usdcToEth;
                } catch {
                    revert("Oracle: USDC rate failed");
                }
            } catch {
                revert("Oracle: Token rate failed");
            }
        }
    }
    
    /**
     * @notice Fully exits a position by unstaking, burning, and swapping to USDC
     * @param params The parameters for the exit operation
     * @return usdcOut The amount of USDC received
     * @return aeroRewards The amount of AERO rewards collected
     */
    function fullExit(FullExitParams calldata params)
        external
        nonReentrant
        deadlineCheck(params.deadline)
        onlyAuthorized(msg.sender)
        returns (uint256 usdcOut, uint256 aeroRewards)
    {
        (,, address token0, address token1, ,, , uint128 liquidity,,,,) = POSITION_MANAGER.positions(params.tokenId);
        require(liquidity > 0, "Position has no liquidity");
        
        address gauge = _findGaugeForPool(params.pool);
        
        // Track AERO rewards
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        // Check if position is staked by checking NFT ownership
        address positionOwner = POSITION_MANAGER.ownerOf(params.tokenId);
        
        // Handle staked positions
        if (gauge != address(0) && positionOwner == gauge) {
            // Position is staked in gauge - withdraw it
            // Note: This will work regardless of who originally staked it
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
        
        // Get effective slippage
        uint256 effectiveSlippage = _getEffectiveSlippage(params.slippageBps);
        
        // Calculate minimum amounts with slippage
        (uint256 expectedAmount0, uint256 expectedAmount1) = _calculateExpectedAmounts(
            params.tokenId,
            params.pool
        );
        
        uint256 amount0Min = (expectedAmount0 * (10000 - effectiveSlippage)) / 10000;
        uint256 amount1Min = (expectedAmount1 * (10000 - effectiveSlippage)) / 10000;
        
        // Decrease liquidity
        (uint256 amount0, uint256 amount1) = POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: params.tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: params.deadline
            })
        );
        
        // Collect the tokens
        (amount0, amount1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: params.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        // Swap tokens to USDC
        // Handle token0 swap to USDC
        if (token0 == USDC) {
            // Token0 is already USDC
            usdcOut = amount0;
        } else if (amount0 > 0) {
            // Need to swap token0 to USDC
            _approveUniversalRouterViaPermit2(token0, amount0);
            
            // Use custom route if provided and valid
            if (params.token0Route.pools.length > 0) {
                // Validate route starts with token0 and ends with USDC
                require(
                    params.token0Route.tokens.length > 0 && 
                    params.token0Route.tokens[0] == token0 && 
                    params.token0Route.tokens[params.token0Route.tokens.length - 1] == USDC,
                    "Invalid token0 exit route"
                );
                usdcOut += _executeSwapWithRoute(params.token0Route, amount0, 0);
            } else {
                // Direct swap token0 -> USDC
                usdcOut += _swapExactInputDirect(token0, USDC, amount0, 0, params.pool);
            }
        }
        
        // Handle token1 swap to USDC
        if (token1 == USDC) {
            // Token1 is already USDC
            usdcOut += amount1;
        } else if (amount1 > 0) {
            // Need to swap token1 to USDC
            _approveUniversalRouterViaPermit2(token1, amount1);
            
            // Use custom route if provided and valid
            if (params.token1Route.pools.length > 0) {
                // Validate route starts with token1 and ends with USDC
                require(
                    params.token1Route.tokens.length > 0 && 
                    params.token1Route.tokens[0] == token1 && 
                    params.token1Route.tokens[params.token1Route.tokens.length - 1] == USDC,
                    "Invalid token1 exit route"
                );
                usdcOut += _executeSwapWithRoute(params.token1Route, amount1, 0);
            } else {
                // Direct swap token1 -> USDC
                usdcOut += _swapExactInputDirect(token1, USDC, amount1, 0, params.pool);
            }
        }
        
        // Transfer AERO rewards if any
        if (aeroRewards > 0) {
            _safeTransfer(AERO, msg.sender, aeroRewards);
        }
        
        require(usdcOut >= params.minUsdcOut, "Insufficient USDC output");
        _safeTransfer(USDC, msg.sender, usdcOut);
        
        emit PositionClosed(msg.sender, params.tokenId, usdcOut, aeroRewards);
    }
    
    /**
     * @notice Approves token to Permit2 if needed
     */
    function _approveTokenToPermit2(address token, uint256 amount) internal {
        uint256 currentAllowance = IERC20(token).allowance(address(this), address(PERMIT2));
        if (currentAllowance < amount) {
            _safeApprove(token, address(PERMIT2), type(uint256).max);
        }
    }
    
    /**
     * @notice Approves Universal Router via Permit2
     */
    function _approveUniversalRouterViaPermit2(address token, uint256 amount) internal {
        _approveTokenToPermit2(token, amount);
        
        (uint160 currentAmount, uint48 expiration, ) = PERMIT2.allowance(
            address(this),
            token,
            address(UNIVERSAL_ROUTER)
        );
        
        if (currentAmount < amount || expiration < block.timestamp) {
            uint160 maxAmount = type(uint160).max;
            uint48 newExpiration = uint48(block.timestamp + 30 days);
            PERMIT2.approve(token, address(UNIVERSAL_ROUTER), maxAmount, newExpiration);
        }
    }
    
    /**
     * @notice Swaps using a specific pool via Universal Router
     */
    function _swapExactInputDirect(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address pool
    ) internal returns (uint256 amountOut) {
        bytes memory commands = abi.encodePacked(bytes1(0x00)); // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        
        int24 tickSpacing = ICLPool(pool).tickSpacing();
        bytes memory tickSpacingBytes = abi.encodePacked(uint24(uint256(int256(tickSpacing))));
        
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            abi.encodePacked(tokenIn, tickSpacingBytes, tokenOut), // path with tick spacing
            true,           // payerIsUser  
            false           // useSlipstreamPools = false for Aerodrome CL pools
        );
        
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute{value: 0}(commands, inputs);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
        
        require(amountOut >= minAmountOut, "Insufficient output amount");
    }
    
    /**
     * @notice Executes a swap using a predefined route (single or multihop)
     * @param route The swap route containing pools and tokens
     * @param amountIn The amount of input token
     * @param minAmountOut The minimum amount of output token
     * @return amountOut The actual amount of output token received
     */
    function _executeSwapWithRoute(
        SwapRoute memory route,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        // Validate route
        require(route.pools.length > 0, "Empty route");
        require(route.tokens.length == route.pools.length + 1, "Invalid route tokens");
        require(route.tickSpacings.length == route.pools.length, "Invalid route tick spacings");
        
        // Single hop swap
        if (route.pools.length == 1) {
            return _swapExactInputDirect(
                route.tokens[0],
                route.tokens[1],
                amountIn,
                minAmountOut,
                route.pools[0]
            );
        }
        
        // Multihop swap
        bytes memory path = _encodeMultihopPath(route);
        
        bytes memory commands = abi.encodePacked(bytes1(0x00)); // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            path,           // encoded multihop path
            true,           // payerIsUser
            false           // useSlipstreamPools = false for Aerodrome CL pools
        );
        
        uint256 balanceBefore = IERC20(route.tokens[route.tokens.length - 1]).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute{value: 0}(commands, inputs);
        amountOut = IERC20(route.tokens[route.tokens.length - 1]).balanceOf(address(this)) - balanceBefore;
        
        require(amountOut >= minAmountOut, "Insufficient output amount");
    }
    
    /**
     * @notice Encodes a multihop path for the Universal Router
     * @param route The swap route to encode
     * @return path The encoded path bytes
     */
    function _encodeMultihopPath(SwapRoute memory route) internal pure returns (bytes memory) {
        bytes memory path;
        
        for (uint256 i = 0; i < route.pools.length; i++) {
            // Add token address (20 bytes)
            path = abi.encodePacked(path, route.tokens[i]);
            
            // Aerodrome Universal Router expects tick spacing directly (3 bytes)
            // NOT the fee - they are separate pool properties
            path = abi.encodePacked(path, route.tickSpacings[i]);
        }
        
        // Add final token
        path = abi.encodePacked(path, route.tokens[route.tokens.length - 1]);
        
        return path;
    }
    
    // Note: Removed _tickSpacingToFee function as Aerodrome's Universal Router
    // expects tick spacing directly in the path, not fees.
    // Pools have both fee() and tickSpacing() properties which serve different purposes:
    // - fee(): The actual swap fee charged by the pool (e.g., 333 = 0.0333%)
    // - tickSpacing(): The granularity of tick positions (e.g., 1, 10, 50, 100, 200, 2000)
    
    /**
     * @notice Calculates expected amounts from burning a position using SugarHelper
     */
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
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }
    
    /**
     * @notice Returns any leftover tokens to the user
     */
    function _returnLeftoverTokens(address token0, address token1) internal {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        
        if (balance0 > 0) {
            _safeTransfer(token0, msg.sender, balance0);
        }
        if (balance1 > 0) {
            _safeTransfer(token1, msg.sender, balance1);
        }
    }
    
    /**
     * @notice Finds the gauge for a pool
     */
    function _findGaugeForPool(address pool) internal view returns (address gauge) {
        try IVoter(VOTER).gauges(pool) returns (address g) {
            if (g != address(0)) {
                return g;
            }
        } catch {}
        
        try IGaugeFactory(GAUGE_FACTORY).getPoolGauge(pool) returns (address g) {
            return g;
        } catch {}
        
        return address(0);
    }
    
    /**
     * @notice Gets effective slippage to use
     */
    function _getEffectiveSlippage(uint256 requestedSlippage) internal pure returns (uint256) {
        if (requestedSlippage == 0) {
            return DEFAULT_SLIPPAGE_BPS;
        }
        require(requestedSlippage <= MAX_SLIPPAGE_BPS, "Slippage too high");
        return requestedSlippage;
    }
    
    /**
     * @notice Handles receipt of NFT positions
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
    
    /**
     * @notice Emergency function to recover stuck tokens
     */
    function recoverToken(address token, uint256 amount) external {
        require(msg.sender == address(walletRegistry), "Only registry owner");
        _safeTransfer(token, msg.sender, amount);
    }
}

/// @title TickMath library
/// @notice Computes sqrt price for ticks of size 1.0001
library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK)), 'T');

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
}