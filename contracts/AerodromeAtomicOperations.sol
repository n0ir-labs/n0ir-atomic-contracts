// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./AtomicBase.sol";
import "./CDPWalletRegistry.sol";
import "@interfaces/IUniversalRouter.sol";
import "@interfaces/IPermit2.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IGauge.sol";
import "@interfaces/ICLFactory.sol";
import "@interfaces/ICLPool.sol";
import "@interfaces/IMixedQuoter.sol";
import "@interfaces/IERC20.sol";
import "@interfaces/IGaugeFactory.sol";
import "@interfaces/ILpSugar.sol";
import "@interfaces/IVoter.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title AerodromeAtomicOperations
 * @author N0IR
 * @notice Atomic operations for Aerodrome Finance concentrated liquidity positions
 * @dev Provides atomic swap, mint, stake, and exit operations for Aerodrome CL pools
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
    /// @notice CL Factory for pool and gauge lookups
    ICLFactory public constant CL_FACTORY = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
    /// @notice Gauge Factory for finding gauges
    address public constant GAUGE_FACTORY = 0xD30677bd8dd15132F251Cb54CbDA552d2A05Fb08;
    /// @notice LP Sugar for getting pool data including gauges
    address public constant LP_SUGAR = 0x27fc745390d1f4BaF8D184FBd97748340f786634;
    /// @notice Voter contract for gauge lookups
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    
    /// @notice USDC token address on Base
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @notice AERO token address on Base
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    /// @notice WETH token address on Base
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    
    /// @notice No sqrt price limit for swaps
    uint256 private constant SQRT_PRICE_LIMIT_X96 = 0;
    /// @notice Default slippage tolerance (1%)
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 100; // 1%
    /// @notice Maximum allowed slippage tolerance (10%)
    uint256 private constant MAX_SLIPPAGE_BPS = 1000; // 10%
    
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
     * @notice Emitted when rewards are claimed
     * @param user The user who claimed rewards
     * @param tokenId The position ID
     * @param aeroAmount The amount of AERO claimed
     * @param usdcReceived The amount of USDC received (if swapped)
     */
    event RewardsClaimed(
        address indexed user,
        uint256 indexed tokenId,
        uint256 aeroAmount,
        uint256 usdcReceived
    );
    
    /**
     * @notice Emitted on emergency withdrawal
     * @param user The address that initiated withdrawal
     * @param token The token withdrawn
     * @param amount The amount withdrawn
     */
    event EmergencyWithdraw(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    
    /**
     * @notice Modifier to restrict access to CDP wallets only
     */
    modifier onlyCDPWallet() {
        require(walletRegistry.isRegisteredWallet(msg.sender), "Not a CDP wallet");
        _;
    }
    
    /**
     * @notice Modifier to validate swap routes
     * @param routes The swap routes to validate
     */
    modifier validateRoutes(SwapRoute[] memory routes) {
        // Allow empty routes for direct USDC positions
        if (routes.length > 0) {
            require(routes.length <= 2, "Too many routes");
            
            for (uint256 i = 0; i < routes.length; i++) {
                require(routes[i].pools.length > 0 && routes[i].pools.length <= 3, "Invalid hop count");
                require(routes[i].tokenOut != address(0), "Invalid tokenOut");
                
                // Validate all pools in the route
                for (uint256 j = 0; j < routes[i].pools.length; j++) {
                    require(_isValidPool(routes[i].pools[j]), "Invalid pool in route");
                }
            }
        }
        _;
    }
    
    /**
     * @notice Constructor sets the CDP wallet registry
     * @param _walletRegistry The address of the CDP wallet registry contract
     */
    constructor(address _walletRegistry) {
        require(_walletRegistry != address(0), "Invalid registry address");
        walletRegistry = CDPWalletRegistry(_walletRegistry);
    }
    
    /**
     * @notice Gets the effective slippage to use for an operation
     * @dev Returns user slippage if valid, otherwise returns default
     * @param userSlippageBps The user-provided slippage in basis points
     * @return The effective slippage to use
     */
    function _getEffectiveSlippage(uint256 userSlippageBps) internal pure returns (uint256) {
        if (userSlippageBps == 0) {
            return DEFAULT_SLIPPAGE_BPS;
        }
        require(userSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage too high");
        return userSlippageBps;
    }
    
    /**
     * @notice Swap route configuration
     * @param pools Ordered pool addresses for the swap path
     * @param tokenOut Final output token (must be token0 or token1 of target pool)
     * @param amountIn USDC amount for this route (0 = calculate optimally)
     */
    struct SwapRoute {
        address[] pools;
        address tokenOut;
        uint256 amountIn;
    }
    
    /**
     * @notice Parameters for swap and mint operations
     * @param pool The address of the Aerodrome CL pool
     * @param tickLower The lower tick boundary for the position
     * @param tickUpper The upper tick boundary for the position
     * @param usdcAmount The amount of USDC to swap and add as liquidity
     * @param minLiquidity The minimum amount of liquidity tokens to mint
     * @param deadline The deadline timestamp for the transaction
     * @param stake Whether to stake the position in the gauge after minting
     * @param slippageBps Custom slippage tolerance in basis points (0 = use default)
     * @param routes Array of swap routes (if empty, keeps USDC as is)
     */
    struct SwapMintParams {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint256 usdcAmount;
        uint256 minLiquidity;
        uint256 deadline;
        bool stake;
        uint256 slippageBps;
        SwapRoute[] routes;
    }
    
    /**
     * @notice Parameters for exit operations
     * @param tokenId The ID of the position NFT to exit
     * @param minUsdcOut The minimum amount of USDC to receive (if swapping)
     * @param deadline The deadline timestamp for the transaction
     * @param swapToUsdc Whether to swap all assets to USDC on exit
     * @param slippageBps Custom slippage tolerance in basis points (0 = use default)
     * @param routes Array of swap routes for converting tokens to USDC (if swapping)
     */
    struct ExitParams {
        uint256 tokenId;
        uint256 minUsdcOut;
        uint256 deadline;
        bool swapToUsdc;
        uint256 slippageBps;
        SwapRoute[] routes;
    }
    
    /**
     * @notice Atomically swaps USDC to pool tokens, mints a position, and optionally stakes it
     * @dev Takes USDC from user, swaps to optimal ratio, mints position, and stakes if requested
     * @param params The swap and mint parameters
     * @return tokenId The ID of the minted position NFT
     * @return liquidity The amount of liquidity minted
     */
    function swapMintAndStake(SwapMintParams calldata params) 
        external 
        onlyCDPWallet
        nonReentrant 
        deadlineCheck(params.deadline)
        validAmount(params.usdcAmount)
        returns (uint256 tokenId, uint128 liquidity)
    {
        return _swapMintAndStakeInternal(params);
    }
    
    /**
     * @notice Internal implementation of swap, mint, and stake
     * @dev Shared logic for swapMintAndStake and swapAndMint
     */
    function _swapMintAndStakeInternal(SwapMintParams memory params) 
        internal 
        validateRoutes(params.routes)
        returns (uint256 tokenId, uint128 liquidity)
    {
        _safeTransferFrom(USDC, msg.sender, address(this), params.usdcAmount);
        
        _validatePool(params.pool, address(CL_FACTORY));
        
        ICLPool pool = ICLPool(params.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        int24 tickSpacing = pool.tickSpacing();
        
        _validateTickRange(params.tickLower, params.tickUpper, tickSpacing);
        
        // Get effective slippage for this operation
        uint256 effectiveSlippage = _getEffectiveSlippage(params.slippageBps);
        
        // Calculate optimal amounts if not specified and execute swaps
        uint256[] memory swapAmounts = _calculateSwapAmounts(
            params.routes,
            params.usdcAmount,
            token0,
            token1,
            params.tickLower,
            params.tickUpper,
            params.pool
        );
        
        // Execute swaps based on provided routes
        uint256 actualBalance0 = 0;
        uint256 actualBalance1 = 0;
        
        if (params.routes.length == 0) {
            // No swaps - check if USDC is one of the tokens
            if (token0 == USDC) {
                actualBalance0 = params.usdcAmount;
            } else if (token1 == USDC) {
                actualBalance1 = params.usdcAmount;
            } else {
                revert("No routes provided and USDC is not a pool token");
            }
        } else {
            // Check if we should optimize for single intermediate token
            if (_shouldOptimizeRoute(params.routes, token0, token1)) {
                _executeOptimizedRoute(params.routes, params.usdcAmount, token0, token1, swapAmounts, effectiveSlippage);
            } else {
                // Execute swaps for each route
                for (uint256 i = 0; i < params.routes.length; i++) {
                    require(params.routes[i].tokenOut == token0 || params.routes[i].tokenOut == token1, "Invalid tokenOut");
                    
                    uint256 amountOut = _executeRouteSwap(
                        USDC,
                        params.routes[i],
                        swapAmounts[i],
                        effectiveSlippage
                    );
                    
                    if (params.routes[i].tokenOut == token0) {
                        actualBalance0 += amountOut;
                    } else {
                        actualBalance1 += amountOut;
                    }
                }
            }
            
            // Get final balances
            actualBalance0 = IERC20(token0).balanceOf(address(this));
            actualBalance1 = IERC20(token1).balanceOf(address(this));
        }
        
        console.log("\\n=== Minting position ===");
        console.log("Actual balance0:", actualBalance0);
        console.log("Actual balance1:", actualBalance1);
        
        // Use actual balances instead of desired amounts
        _safeApprove(token0, address(POSITION_MANAGER), actualBalance0);
        _safeApprove(token1, address(POSITION_MANAGER), actualBalance1);
        
        // Calculate the maximum liquidity we can mint with our actual balances
        (uint160 sqrtPriceX96,,,,,) = ICLPool(params.pool).slot0();
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(params.tickUpper);
        
        console.log("Calculating liquidity with:");
        console.log("  sqrtPriceX96:", sqrtPriceX96);
        console.log("  sqrtRatioAX96:", sqrtRatioAX96);
        console.log("  sqrtRatioBX96:", sqrtRatioBX96);
        
        uint256 calculatedLiquidity = _getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            actualBalance0,
            actualBalance1
        );
        
        console.log("Calculated liquidity:", calculatedLiquidity);
        
        // Now calculate the exact amounts needed for this liquidity
        // Apply a small buffer (99%) to avoid rounding issues
        
        // Check if liquidity fits in uint128
        uint256 maxUint128 = type(uint128).max;
        console.log("Max uint128:", maxUint128);
        
        require(calculatedLiquidity <= maxUint128, "Liquidity exceeds uint128 max");
        
        uint128 adjustedLiquidity = uint128((calculatedLiquidity * 99) / 100);
        
        console.log("Adjusted liquidity:", adjustedLiquidity);
        
        (uint256 amount0Exact, uint256 amount1Exact) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            adjustedLiquidity
        );
        
        console.log("Exact amounts needed:");
        console.log("  Amount0:", amount0Exact);
        console.log("  Amount1:", amount1Exact);
        
        // Use the exact amounts (which should be <= our balances)
        uint128 mintedLiquidity;
        
        console.log("Minting with parameters:");
        console.log("  amount0Desired:", amount0Exact);
        console.log("  amount1Desired:", amount1Exact);
        console.log("  amount0Min:", _calculateMinimumOutput(amount0Exact, effectiveSlippage));
        console.log("  amount1Min:", _calculateMinimumOutput(amount1Exact, effectiveSlippage));
        
        try POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickSpacing: tickSpacing,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: amount0Exact,
                amount1Desired: amount1Exact,
                amount0Min: _calculateMinimumOutput(amount0Exact, effectiveSlippage),
                amount1Min: _calculateMinimumOutput(amount1Exact, effectiveSlippage),
                recipient: params.stake ? address(this) : msg.sender,
                deadline: params.deadline,
                sqrtPriceX96: 0
            })
        ) returns (uint256 _tokenId, uint128 _liquidity, uint256 amount0Used, uint256 amount1Used) {
            tokenId = _tokenId;
            mintedLiquidity = _liquidity;
            console.log("Mint successful!");
            console.log("  TokenId:", tokenId);
            console.log("  Liquidity:", mintedLiquidity);
            console.log("  Amount0 used:", amount0Used);
            console.log("  Amount1 used:", amount1Used);
        } catch Error(string memory reason) {
            console.log("Mint failed with reason:", reason);
            revert(reason);
        } catch (bytes memory data) {
            console.log("Mint failed with data length:", data.length);
            if (data.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(data, 0x20))
                }
                console.logBytes4(selector);
            }
            revert("Mint failed");
        }
        
        liquidity = mintedLiquidity;
        require(liquidity >= params.minLiquidity, "Insufficient liquidity minted");
        
        if (params.stake) {
            console.log("\\nStaking position...");
            
            // Try multiple methods to find the gauge
            address gauge = address(0);
            
            // Method 1: Try Voter contract (most reliable)
            try IVoter(VOTER).gauges(params.pool) returns (address g) {
                gauge = g;
                if (gauge != address(0)) {
                    console.log("Found gauge via Voter contract:", gauge);
                }
            } catch {
                console.log("Voter lookup failed");
            }
            
            // Method 2: Try gauge factory as fallback
            if (gauge == address(0)) {
                try IGaugeFactory(GAUGE_FACTORY).gauges(params.pool) returns (address g) {
                    gauge = g;
                    if (gauge != address(0)) {
                        console.log("Found gauge via factory");
                    }
                } catch {
                    console.log("Gauge factory lookup failed");
                }
            }
            
            // If still no gauge found, skip staking
            if (gauge == address(0)) {
                console.log("No gauge found for pool - skipping staking");
                // Don't fail, just skip staking
                emit PositionOpened(msg.sender, tokenId, params.pool, params.usdcAmount, uint128(liquidity), false);
                return (tokenId, liquidity);
            }
            
            console.log("Gauge address:", gauge);
            
            // Verify we own the NFT
            address nftOwner = POSITION_MANAGER.ownerOf(tokenId);
            console.log("NFT owner:", nftOwner);
            console.log("This contract:", address(this));
            require(nftOwner == address(this), "Contract doesn't own the NFT");
            
            console.log("Approving gauge for tokenId:", tokenId);
            POSITION_MANAGER.approve(gauge, tokenId);
            
            console.log("Staking tokenId:", tokenId);
            try IGauge(gauge).deposit(tokenId) {
                console.log("Staking successful!");
            } catch Error(string memory reason) {
                console.log("Staking failed with reason:", reason);
                revert(reason);
            } catch (bytes memory data) {
                console.log("Staking failed with data length:", data.length);
                if (data.length >= 4) {
                    bytes4 selector;
                    assembly {
                        selector := mload(add(data, 0x20))
                    }
                    console.log("Error selector:");
                    console.logBytes4(selector);
                }
                revert("Staking failed");
            }
        }
        
        emit PositionOpened(msg.sender, tokenId, params.pool, params.usdcAmount, uint128(liquidity), params.stake);
    }
    
    /**
     * @notice Atomically swaps USDC to pool tokens and mints a position (without staking)
     * @dev Convenience function that calls swapMintAndStake with stake=false
     * @param params The swap and mint parameters
     * @return tokenId The ID of the minted position NFT
     * @return liquidity The amount of liquidity minted
     */
    function swapAndMint(SwapMintParams calldata params) 
        external 
        onlyCDPWallet
        nonReentrant 
        deadlineCheck(params.deadline)
        validAmount(params.usdcAmount)
        returns (uint256 tokenId, uint128 liquidity)
    {
        SwapMintParams memory modifiedParams = params;
        modifiedParams.stake = false;
        return _swapMintAndStakeInternal(modifiedParams);
    }
    
    /**
     * @notice Atomically exits a position by unstaking, burning, and optionally swapping to USDC
     * @dev Handles both staked and unstaked positions, collects fees and rewards
     * @param params The exit parameters
     * @return usdcOut The amount of USDC received (if swapping)
     * @return aeroRewards The amount of AERO rewards collected
     */
    function fullExit(ExitParams calldata params)
        external
        onlyCDPWallet
        nonReentrant
        deadlineCheck(params.deadline)
        validateRoutes(params.routes)
        returns (uint256 usdcOut, uint256 aeroRewards)
    {
        console.log("fullExit called for tokenId:", params.tokenId);
        console.log("Caller:", msg.sender);
        
        (,, address token0, address token1, int24 tickSpacing,, , uint128 liquidity,,,,) = POSITION_MANAGER.positions(params.tokenId);
        console.log("Position liquidity:", liquidity);
        require(liquidity > 0, "Position has no liquidity");
        
        address pool = CL_FACTORY.getPool(token0, token1, tickSpacing);
        console.log("Pool:", pool);
        
        // Try Voter first, then gauge factory
        address gauge;
        try IVoter(VOTER).gauges(pool) returns (address g) {
            gauge = g;
            console.log("Found gauge via Voter:", gauge);
        } catch {
            gauge = IGaugeFactory(GAUGE_FACTORY).gauges(pool);
            console.log("Found gauge via factory:", gauge);
        }
        
        // Get effective slippage for this operation
        uint256 effectiveSlippage = _getEffectiveSlippage(params.slippageBps);
        
        if (gauge != address(0) && IGauge(gauge).stakedContains(address(this), params.tokenId)) {
            console.log("Position is staked, withdrawing from gauge");
            uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
            IGauge(gauge).withdraw(params.tokenId);
            // Rewards are automatically claimed during withdraw
            aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
            console.log("AERO rewards collected during withdraw:", aeroRewards);
        } else {
            console.log("Position is not staked or gauge not found");
        }
        
        // After unstaking, the position should be owned by either the user or this contract
        address owner = POSITION_MANAGER.ownerOf(params.tokenId);
        console.log("After unstaking, NFT owner:", owner);
        console.log("Expected owner (msg.sender):", msg.sender);
        console.log("Or this contract:", address(this));
        require(owner == msg.sender || owner == address(this), "Not token owner");
        
        // Only transfer if not already owned by this contract
        if (owner != address(this)) {
            POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), params.tokenId);
        }
        
        // Calculate expected amounts based on liquidity and current prices
        ICLPool clPool = ICLPool(pool);
        (uint160 sqrtPriceX96,,,,,) = clPool.slot0();
        
        // Get position tick boundaries
        (,,,,,int24 tickLower, int24 tickUpper,,,,,) = POSITION_MANAGER.positions(params.tokenId);
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        // Calculate expected amounts for the liquidity
        (uint256 expectedAmount0, uint256 expectedAmount1) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );
        
        // Apply slippage protection to expected amounts
        uint256 amount0Min = _calculateMinimumOutput(expectedAmount0, effectiveSlippage);
        uint256 amount1Min = _calculateMinimumOutput(expectedAmount1, effectiveSlippage);
        
        (uint256 amount0, uint256 amount1) = POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: params.tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: params.deadline
            })
        );
        
        POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: params.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        POSITION_MANAGER.burn(params.tokenId);
        
        if (params.swapToUsdc) {
            usdcOut = _swapAllToUsdc(token0, token1, amount0, amount1, aeroRewards, params.routes, effectiveSlippage);
            require(usdcOut >= params.minUsdcOut, "Insufficient USDC output");
            _safeTransfer(USDC, msg.sender, usdcOut);
        } else {
            if (amount0 > 0) _safeTransfer(token0, msg.sender, amount0);
            if (amount1 > 0) _safeTransfer(token1, msg.sender, amount1);
            if (aeroRewards > 0) _safeTransfer(AERO, msg.sender, aeroRewards);
        }
        
        emit PositionClosed(msg.sender, params.tokenId, usdcOut, aeroRewards);
    }
    
    /**
     * @notice Claims AERO rewards from a staked position and optionally swaps to USDC
     * @dev Position remains staked after claiming rewards
     * @param tokenId The ID of the staked position
     * @param minUsdcOut Minimum USDC to receive if swapping (0 to receive AERO)
     * @param deadline The deadline timestamp for the transaction
     * @return aeroAmount The amount of AERO rewards claimed
     * @return usdcReceived The amount of USDC received (if swapped)
     */
    function claimAndSwap(uint256 tokenId, uint256 minUsdcOut, uint256 deadline)
        external
        onlyCDPWallet
        nonReentrant
        deadlineCheck(deadline)
        returns (uint256 aeroAmount, uint256 usdcReceived)
    {
        (,, address token0, address token1, int24 tickSpacing,, ,,,,,) = POSITION_MANAGER.positions(tokenId);
        
        address pool = CL_FACTORY.getPool(token0, token1, tickSpacing);
        
        // Try Voter first, then gauge factory
        address gauge;
        try IVoter(VOTER).gauges(pool) returns (address g) {
            gauge = g;
        } catch {
            gauge = IGaugeFactory(GAUGE_FACTORY).gauges(pool);
        }
        require(gauge != address(0), "No gauge found");
        
        require(IGauge(gauge).stakedContains(address(this), tokenId), "Position not staked");
        
        aeroAmount = IGauge(gauge).earned(tokenId);
        require(aeroAmount > 0, "No rewards to claim");
        
        // For claiming without unstaking, we need to call the address-based getReward
        // The gauge expects the depositor address, which is this contract
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        // Try to call getReward - the gauge might have a different signature
        (bool success,) = gauge.call(abi.encodeWithSelector(0x1c4b774b, address(this)));
        require(success, "Failed to claim rewards");
        
        aeroAmount = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        
        if (minUsdcOut > 0) {
            _safeApprove(AERO, address(UNIVERSAL_ROUTER), aeroAmount);
            usdcReceived = _swapExactInput(AERO, USDC, aeroAmount, minUsdcOut, _getTickSpacingForPair(AERO, USDC));
            _safeTransfer(USDC, msg.sender, usdcReceived);
        } else {
            _safeTransfer(AERO, msg.sender, aeroAmount);
        }
        
        emit RewardsClaimed(msg.sender, tokenId, aeroAmount, usdcReceived);
    }
    
    /**
     * @notice Unstakes and burns a position, returning tokens to user
     * @dev Returns the underlying tokens without swapping to USDC
     * @param tokenId The ID of the position to unstake and burn
     * @param deadline The deadline timestamp for the transaction
     * @param slippageBps Custom slippage tolerance in basis points (0 = use default)
     * @return amount0 The amount of token0 returned
     * @return amount1 The amount of token1 returned
     * @return aeroRewards The amount of AERO rewards collected
     */
    function unstakeAndBurn(uint256 tokenId, uint256 deadline, uint256 slippageBps)
        external
        onlyCDPWallet
        nonReentrant
        deadlineCheck(deadline)
        returns (uint256 amount0, uint256 amount1, uint256 aeroRewards)
    {
        return _unstakeAndBurnInternal(tokenId, deadline, slippageBps);
    }
    
    /**
     * @notice Internal implementation of unstake and burn
     * @dev Shared logic for both unstakeAndBurn signatures
     */
    function _unstakeAndBurnInternal(uint256 tokenId, uint256 deadline, uint256 slippageBps)
        internal
        returns (uint256 amount0, uint256 amount1, uint256 aeroRewards)
    {
        (,, address token0, address token1, int24 tickSpacing,, , uint128 liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
        require(liquidity > 0, "Position has no liquidity");
        
        address pool = CL_FACTORY.getPool(token0, token1, tickSpacing);
        
        // Try Voter first, then gauge factory
        address gauge;
        try IVoter(VOTER).gauges(pool) returns (address g) {
            gauge = g;
        } catch {
            gauge = IGaugeFactory(GAUGE_FACTORY).gauges(pool);
        }
        
        // Get effective slippage for this operation
        uint256 effectiveSlippage = _getEffectiveSlippage(slippageBps);
        
        if (gauge != address(0) && IGauge(gauge).stakedContains(address(this), tokenId)) {
            uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
            IGauge(gauge).withdraw(tokenId);
            // Rewards are automatically claimed during withdraw
            aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        }
        
        require(POSITION_MANAGER.ownerOf(tokenId) == msg.sender, "Not token owner");
        
        POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), tokenId);
        
        // Calculate expected amounts based on liquidity and current prices
        ICLPool clPool = ICLPool(pool);
        (uint160 sqrtPriceX96,,,,,) = clPool.slot0();
        
        // Get position tick boundaries
        (,,,,,int24 tickLower, int24 tickUpper,,,,,) = POSITION_MANAGER.positions(tokenId);
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        // Calculate expected amounts for the liquidity
        (uint256 expectedAmount0, uint256 expectedAmount1) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );
        
        // Apply slippage protection to expected amounts
        uint256 amount0Min = _calculateMinimumOutput(expectedAmount0, effectiveSlippage);
        uint256 amount1Min = _calculateMinimumOutput(expectedAmount1, effectiveSlippage);
        
        (amount0, amount1) = POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );
        
        POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        POSITION_MANAGER.burn(tokenId);
        
        if (aeroRewards > 0) {
            _safeTransfer(AERO, msg.sender, aeroRewards);
        }
    }
    
    /**
     * @notice Backward compatibility wrapper for unstakeAndBurn without slippage
     * @dev Uses default slippage tolerance
     * @param tokenId The ID of the position to unstake and burn
     * @param deadline The deadline timestamp for the transaction
     * @return amount0 The amount of token0 returned
     * @return amount1 The amount of token1 returned
     * @return aeroRewards The amount of AERO rewards collected
     */
    function unstakeAndBurn(uint256 tokenId, uint256 deadline)
        external
        onlyCDPWallet
        nonReentrant
        deadlineCheck(deadline)
        returns (uint256 amount0, uint256 amount1, uint256 aeroRewards)
    {
        return _unstakeAndBurnInternal(tokenId, deadline, 0); // 0 = use default slippage
    }
    
    /**
     * @notice Calculates optimal token amounts for liquidity provision
     * @dev Uses the current pool price to determine the ratio of tokens needed
     * @param token0 The address of token0
     * @param token1 The address of token1
     * @param usdcAmount The total USDC amount to convert
     * @param tickLower The lower tick boundary
     * @param tickUpper The upper tick boundary
     * @param pool The pool address
     * @return amount0 The optimal amount of token0
     * @return amount1 The optimal amount of token1
     */
    function _calculateOptimalAmounts(
        address token0,
        address token1,
        uint256 usdcAmount,
        int24 tickLower,
        int24 tickUpper,
        address pool
    ) internal view returns (uint256 amount0, uint256 amount1) {
        ICLPool clPool = ICLPool(pool);
        (uint160 sqrtPriceX96,,,,,) = clPool.slot0();
        
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        // Calculate token weights based on position in range
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Below range - 100% token0
            // Need to convert all USDC to token0
            amount0 = _quoteUSDCToToken(token0, usdcAmount);
            amount1 = 0;
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // Above range - 100% token1
            // Need to convert all USDC to token1
            amount0 = 0;
            amount1 = _quoteUSDCToToken(token1, usdcAmount);
        } else {
            // In range - calculate optimal split
            uint256 sqrtPrice = uint256(sqrtPriceX96);
            uint256 sqrtPriceLower = uint256(sqrtRatioAX96);
            uint256 sqrtPriceUpper = uint256(sqrtRatioBX96);
            
            // Calculate price ratio in range (0 to 1e18)
            uint256 priceRatioNumerator = sqrtPrice - sqrtPriceLower;
            uint256 priceRatioDenominator = sqrtPriceUpper - sqrtPriceLower;
            uint256 token1Portion = priceRatioNumerator * 1e18 / priceRatioDenominator;
            uint256 token0Portion = 1e18 - token1Portion;
            
            // Calculate USDC allocation for each token
            uint256 usdcForToken0 = usdcAmount * token0Portion / 1e18;
            uint256 usdcForToken1 = usdcAmount * token1Portion / 1e18;
            
            // Quote the amounts we'll get after swap - use simplified approach if quote fails
            if (token0 == USDC) {
                amount0 = usdcForToken0;
            } else {
                // Just use the USDC amount as a rough estimate
                // The actual swap will handle the conversion
                amount0 = usdcForToken0;
            }
            
            if (token1 == USDC) {
                amount1 = usdcForToken1;
            } else {
                // Just use the USDC amount as a rough estimate
                // The actual swap will handle the conversion
                amount1 = usdcForToken1;
            }
        }
    }
    
    /**
     * @notice Performs optimal swaps from USDC to get required tokens for liquidity
     * @dev Calculates optimal split and routes swaps through best paths
     * @param token0 The address of token0
     * @param token1 The address of token1
     * @param usdcAmount The total USDC amount
     * @param tickLower The lower tick
     * @param tickUpper The upper tick
     * @param pool The pool address
     */
    function _performOptimalSwapsForLiquidity(
        address token0,
        address token1,
        uint256 usdcAmount,
        int24 tickLower,
        int24 tickUpper,
        address pool
    ) internal {
        // Log what we're trying to do
        console.log("=== Performing optimal swaps for liquidity ===");
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("USDC amount:", usdcAmount);
        
        // Get pool price to determine optimal split
        ICLPool clPool = ICLPool(pool);
        (uint160 sqrtPriceX96,,,,,) = clPool.slot0();
        
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        uint256 totalUSDC = IERC20(USDC).balanceOf(address(this));
        
        // Handle special cases
        if (token0 == USDC && token1 == USDC) {
            return; // Both are USDC, no swap needed
        }
        
        if (token0 == USDC) {
            // Only swap for token1
            if (sqrtPriceX96 >= sqrtRatioBX96) {
                // Above range, don't need token0 (USDC)
                _executeOptimalSwap(USDC, token1, totalUSDC, 0);
            } else if (sqrtPriceX96 > sqrtRatioAX96) {
                // In range, need both tokens
                uint256 priceRatio = ((uint256(sqrtPriceX96) - uint256(sqrtRatioAX96)) * 1e18) / 
                                     (uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96));
                uint256 amtForToken1 = (totalUSDC * priceRatio) / 1e18;
                if (amtForToken1 > 0) {
                    _executeOptimalSwap(USDC, token1, amtForToken1, 0);
                }
            }
            // If below range, keep all USDC as token0
            return;
        }
        
        if (token1 == USDC) {
            // Only swap for token0
            if (sqrtPriceX96 <= sqrtRatioAX96) {
                // Below range, don't need token1 (USDC)
                _executeOptimalSwap(USDC, token0, totalUSDC, 0);
            } else if (sqrtPriceX96 < sqrtRatioBX96) {
                // In range, need both tokens
                uint256 priceRatio = ((uint256(sqrtPriceX96) - uint256(sqrtRatioAX96)) * 1e18) / 
                                     (uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96));
                uint256 amtForToken0 = totalUSDC - ((totalUSDC * priceRatio) / 1e18);
                if (amtForToken0 > 0) {
                    _executeOptimalSwap(USDC, token0, amtForToken0, 0);
                }
            }
            // If above range, keep all USDC as token1
            return;
        }
        
        // Neither token is USDC - calculate optimal split based on tick position
        uint256 usdcForToken0;
        uint256 usdcForToken1;
        
        // Calculate split based on position in range
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Below range - 100% token0
            usdcForToken0 = totalUSDC;
            usdcForToken1 = 0;
            console.log("Position below range - 100% token0");
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // Above range - 100% token1
            usdcForToken0 = 0;
            usdcForToken1 = totalUSDC;
            console.log("Position above range - 100% token1");
        } else {
            // In range - calculate optimal split
            uint256 sqrtPrice = uint256(sqrtPriceX96);
            uint256 sqrtPriceLower = uint256(sqrtRatioAX96);
            uint256 sqrtPriceUpper = uint256(sqrtRatioBX96);
            
            // Calculate value ratio based on position in range
            // This is a simplified calculation - in production you'd want more sophisticated math
            uint256 priceRatio = ((sqrtPrice - sqrtPriceLower) * 1e18) / (sqrtPriceUpper - sqrtPriceLower);
            
            // Split USDC based on the price ratio
            usdcForToken1 = (totalUSDC * priceRatio) / 1e18;
            usdcForToken0 = totalUSDC - usdcForToken1;
            
            console.log("Position in range - splitting USDC");
            console.log("Price ratio (1e18):", priceRatio);
        }
        
        console.log("USDC for token0:", usdcForToken0);
        console.log("USDC for token1:", usdcForToken1);
        
        // Execute swaps
        if (usdcForToken0 > 0) {
            console.log("\\nSwapping USDC for token0:");
            console.log("  USDC amount:", usdcForToken0);
            _executeOptimalSwap(USDC, token0, usdcForToken0, 0);
        }
        
        if (usdcForToken1 > 0) {
            // Use remaining USDC for token1 to account for any slippage
            uint256 remainingUSDC = IERC20(USDC).balanceOf(address(this));
            console.log("\\nSwapping remaining USDC for token1:");
            console.log("  Remaining USDC:", remainingUSDC);
            if (remainingUSDC > 0) {
                _executeOptimalSwap(USDC, token1, remainingUSDC, 0);
            }
        }
        
        // Log final balances
        console.log("\\n=== Final balances before mint ===");
        console.log("Token0 balance:", IERC20(token0).balanceOf(address(this)));
        console.log("Token1 balance:", IERC20(token1).balanceOf(address(this)));
    }
    
    /**
     * @notice Swaps all tokens to USDC using provided routes with optimization
     * @dev Used during exit to convert all assets to USDC
     * @param token0 The address of token0
     * @param token1 The address of token1
     * @param amount0 The amount of token0 to swap
     * @param amount1 The amount of token1 to swap
     * @param aeroAmount The amount of AERO to swap
     * @param routes Array of swap routes for each token
     * @param slippageBps The slippage tolerance in basis points
     * @return totalUsdc The total USDC received from all swaps
     */
    function _swapAllToUsdc(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 aeroAmount,
        SwapRoute[] memory routes,
        uint256 slippageBps
    ) internal returns (uint256 totalUsdc) {
        // Check if we can optimize the exit route
        if (_shouldOptimizeExitRoute(routes, token0, token1)) {
            return _executeOptimizedExitRoute(
                token0,
                token1,
                amount0,
                amount1,
                aeroAmount,
                routes,
                slippageBps
            );
        }
        // Handle token0
        if (token0 == USDC) {
            totalUsdc += amount0;
        } else if (amount0 > 0) {
            // Find route for token0
            bool foundRoute = false;
            for (uint256 i = 0; i < routes.length; i++) {
                if (routes[i].tokenOut == USDC && _isRouteForToken(routes[i], token0)) {
                    uint256 usdcOut = _executeExitRouteSwap(token0, routes[i], amount0, slippageBps);
                    totalUsdc += usdcOut;
                    foundRoute = true;
                    break;
                }
            }
            require(foundRoute, "No route found for token0");
        }
        
        // Handle token1
        if (token1 == USDC) {
            totalUsdc += amount1;
        } else if (amount1 > 0) {
            // Find route for token1
            bool foundRoute = false;
            for (uint256 i = 0; i < routes.length; i++) {
                if (routes[i].tokenOut == USDC && _isRouteForToken(routes[i], token1)) {
                    uint256 usdcOut = _executeExitRouteSwap(token1, routes[i], amount1, slippageBps);
                    totalUsdc += usdcOut;
                    foundRoute = true;
                    break;
                }
            }
            require(foundRoute, "No route found for token1");
        }
        
        // Handle AERO rewards
        if (aeroAmount > 0) {
            // Find route for AERO
            bool foundRoute = false;
            for (uint256 i = 0; i < routes.length; i++) {
                if (routes[i].tokenOut == USDC && _isRouteForToken(routes[i], AERO)) {
                    uint256 usdcOut = _executeExitRouteSwap(AERO, routes[i], aeroAmount, slippageBps);
                    totalUsdc += usdcOut;
                    foundRoute = true;
                    break;
                }
            }
            require(foundRoute, "No route found for AERO");
        }
    }
    
    /**
     * @notice Checks if exit routes can be optimized through a common intermediate
     * @param routes The exit routes
     * @param token0 Token0 from the position
     * @param token1 Token1 from the position
     * @return True if optimization is possible
     */
    function _shouldOptimizeExitRoute(
        SwapRoute[] memory routes,
        address token0,
        address token1
    ) internal pure returns (bool) {
        // Optimization is possible if:
        // 1. We have exactly 1 route
        // 2. One of the tokens is WETH and the other needs to be swapped through it
        if (routes.length != 1) return false;
        
        // Check if one token is WETH and route is for the other token
        if (token0 == WETH && routes[0].pools.length >= 2) {
            // Route should be: otherToken -> WETH -> USDC
            return true;
        }
        if (token1 == WETH && routes[0].pools.length >= 2) {
            // Route should be: otherToken -> WETH -> USDC
            return true;
        }
        
        return false;
    }
    
    /**
     * @notice Executes optimized exit by combining tokens through WETH
     * @param token0 Token0 from position
     * @param token1 Token1 from position
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @param aeroAmount Amount of AERO rewards
     * @param routes The provided routes
     * @param slippageBps Slippage tolerance
     * @return totalUsdc Total USDC received
     */
    function _executeOptimizedExitRoute(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 aeroAmount,
        SwapRoute[] memory routes,
        uint256 slippageBps
    ) internal returns (uint256 totalUsdc) {
        // Determine which token is WETH and which needs swapping
        address wethToken;
        address otherToken;
        uint256 wethAmount;
        uint256 otherAmount;
        
        if (token0 == WETH) {
            wethToken = token0;
            otherToken = token1;
            wethAmount = amount0;
            otherAmount = amount1;
        } else if (token1 == WETH) {
            wethToken = token1;
            otherToken = token0;
            wethAmount = amount1;
            otherAmount = amount0;
        } else {
            revert("Optimization requires WETH as one token");
        }
        
        // First, swap other token to WETH if amount > 0
        uint256 totalWeth = wethAmount;
        if (otherAmount > 0 && otherToken != USDC) {
            // Use first pool in route (should be otherToken -> WETH)
            address otherToWethPool = routes[0].pools[0];
            _safeApprove(otherToken, address(UNIVERSAL_ROUTER), otherAmount);
            
            int24 tickSpacing = ICLPool(otherToWethPool).tickSpacing();
            uint256 wethFromOther = _swapExactInput(
                otherToken,
                WETH,
                otherAmount,
                0,
                tickSpacing
            );
            totalWeth += wethFromOther;
        } else if (otherToken == USDC) {
            // If other token is USDC, add it directly to total
            totalUsdc += otherAmount;
        }
        
        // Handle AERO rewards if any
        if (aeroAmount > 0) {
            // Check if we have a direct AERO -> WETH pool in routes
            bool foundAeroRoute = false;
            for (uint256 i = 0; i < routes[0].pools.length; i++) {
                ICLPool pool = ICLPool(routes[0].pools[i]);
                if ((pool.token0() == AERO || pool.token1() == AERO) && 
                    (pool.token0() == WETH || pool.token1() == WETH)) {
                    // Found AERO/WETH pool
                    _safeApprove(AERO, address(UNIVERSAL_ROUTER), aeroAmount);
                    int24 tickSpacing = pool.tickSpacing();
                    uint256 wethFromAero = _swapExactInput(
                        AERO,
                        WETH,
                        aeroAmount,
                        0,
                        tickSpacing
                    );
                    totalWeth += wethFromAero;
                    foundAeroRoute = true;
                    break;
                }
            }
            
            if (!foundAeroRoute) {
                // If no AERO -> WETH route, try direct AERO -> USDC
                // This would need a separate route provided by SDK
                revert("No AERO route found for optimization");
            }
        }
        
        // Now swap all WETH to USDC in one transaction
        if (totalWeth > 0) {
            // Use the WETH -> USDC pool (should be last pool in route)
            address wethToUsdcPool = routes[0].pools[routes[0].pools.length - 1];
            _safeApprove(WETH, address(UNIVERSAL_ROUTER), totalWeth);
            
            int24 tickSpacing = ICLPool(wethToUsdcPool).tickSpacing();
            uint256 usdcFromWeth = _swapExactInput(
                WETH,
                USDC,
                totalWeth,
                0,
                tickSpacing
            );
            totalUsdc += usdcFromWeth;
        }
        
        return totalUsdc;
    }
    
    /**
     * @notice Swaps an exact amount of input token for output token
     * @dev Uses Universal Router V3_SWAP_EXACT_IN command (0x00)
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountIn The exact input amount
     * @param minAmountOut The minimum output amount
     * @param tickSpacing The tick spacing of the pool to use
     * @return amountOut The actual output amount received
     */
    function _swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        int24 tickSpacing
    ) internal returns (uint256 amountOut) {
        // Get the specific pool
        address pool = CL_FACTORY.getPool(tokenIn, tokenOut, tickSpacing);
        require(pool != address(0), "Pool not found");
        
        // Try direct pool swap first for problematic pools
        ICLPool clPool = ICLPool(pool);
        uint24 fee = clPool.fee();
        
        // Check if this is a problematic pool (fee doesn't match expected mapping)
        uint24 expectedFee = CL_FACTORY.tickSpacingToFee(tickSpacing);
        if (fee != expectedFee || tickSpacing == 100) {
            console.log("Using direct pool swap for problematic pool");
            console.log("Pool:", pool);
            console.log("Expected fee:", expectedFee);
            console.log("Actual fee:", fee);
            return _directPoolSwap(tokenIn, tokenOut, amountIn, minAmountOut, pool);
        }
        
        // Otherwise use Universal Router
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), amountIn);
        
        // V3_SWAP_EXACT_IN command
        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs = new bytes[](1);
        
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            abi.encodePacked(tokenIn, fee, tokenOut),  // path with fee
            true,           // payerIsUser (we already have tokens)
            true            // useSlipstreamPools (true = use Slipstream/Aerodrome pools)
        );
        
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp + 300);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
    }
    
    /**
     * @notice Swaps input token for an exact amount of output token
     * @dev Uses Universal Router V3_SWAP_EXACT_OUT command (0x01)
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountOut The exact output amount desired
     * @param maxAmountIn The maximum input amount allowed
     * @return amountIn The actual input amount used
     */
    function _swapExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn
    ) internal returns (uint256 amountIn) {
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), maxAmountIn);
        
        // V3_SWAP_EXACT_OUT command
        bytes memory commands = abi.encodePacked(bytes1(0x01));
        bytes[] memory inputs = new bytes[](1);
        
        // Get pool and its actual fee
        int24 tickSpacing = _getTickSpacingForPair(tokenIn, tokenOut);
        address pool = CL_FACTORY.getPool(tokenIn, tokenOut, tickSpacing);
        require(pool != address(0), "Pool not found");
        uint24 fee = ICLPool(pool).fee(); // Use actual fee from pool
        
        // For exact output, path is reversed (tokenOut -> tokenIn)
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountOut,      // amountOut
            maxAmountIn,    // amountInMaximum
            abi.encodePacked(tokenOut, fee, tokenIn),  // reversed path with fee
            true,           // payerIsUser
            true            // useSlipstreamPools (true = use Slipstream/Aerodrome pools)
        );
        
        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp + 300);
        amountIn = balanceBefore - IERC20(tokenIn).balanceOf(address(this));
    }
    
    /**
     * @notice Gets the tick spacing for a token pair
     * @dev Tries common tick spacings to find the pool
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return tickSpacing The tick spacing of the pool
     */
    function _getTickSpacingForPair(address tokenA, address tokenB) internal view returns (int24 tickSpacing) {
        // All tick spacings on Aerodrome: 1, 10, 50, 100, 200, 2000
        int24[6] memory commonTickSpacings = [int24(1), int24(10), int24(50), int24(100), int24(200), int24(2000)];
        
        for (uint256 i = 0; i < commonTickSpacings.length; i++) {
            address pool = CL_FACTORY.getPool(tokenA, tokenB, commonTickSpacings[i]);
            if (pool != address(0)) {
                return commonTickSpacings[i];
            }
        }
        
        // Default to tick spacing 100 if no pool found
        revert("No pool found for token pair");
    }
    
    /**
     * @notice Calculates sqrt(1.0001^tick) * 2^96
     * @dev See Uniswap V3 whitepaper for math details
     * @param tick The tick value
     * @return sqrtPriceX96 The sqrt price as a Q64.96 fixed point number
     */
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(887272), "Tick out of bounds");
        
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
        
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
    
    /**
     * @notice Computes liquidity amount from token amounts and price range
     * @dev Handles cases where current price is inside/outside the range
     * @param sqrtRatioX96 The current sqrt price
     * @param sqrtRatioAX96 The sqrt price at lower tick
     * @param sqrtRatioBX96 The sqrt price at upper tick
     * @param amount0 The amount of token0
     * @param amount1 The amount of token1
     * @return liquidity The liquidity amount
     */
    function _getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint256 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = _getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint256 liquidity0 = _getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint256 liquidity1 = _getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = _getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }
    
    function _getLiquidityForAmount0(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0
    ) internal pure returns (uint256 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        
        // Check for underflow
        require(sqrtRatioBX96 > sqrtRatioAX96, "Invalid sqrt ratios");
        
        uint256 intermediate = mulDiv(uint256(sqrtRatioAX96), uint256(sqrtRatioBX96), 1 << 96);
        liquidity = mulDiv(amount0, intermediate, uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96));
    }
    
    function _getLiquidityForAmount1(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount1
    ) internal pure returns (uint256 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        liquidity = mulDiv(amount1, 1 << 96, sqrtRatioBX96 - sqrtRatioAX96);
    }
    
    function _getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal view returns (uint256 amount0, uint256 amount1) {
        console.log("_getAmountsForLiquidity called with:");
        console.log("  liquidity:", liquidity);
        
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            console.log("Price below range - calculating amount0 only");
            amount0 = _getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            console.log("Price in range - calculating both amounts");
            amount0 = _getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            // Note: sqrtRatioX96 is the upper bound for amount1 calculation when in range
            amount1 = _getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            console.log("Price above range - calculating amount1 only");
            amount1 = _getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
        
        console.log("Calculated amounts:");
        console.log("  amount0:", amount0);
        console.log("  amount1:", amount1);
    }
    
    function _getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        
        // Calculate amount0 = liquidity * (sqrtRatioBX96 - sqrtRatioAX96) / (sqrtRatioAX96 * sqrtRatioBX96 / 2^96)
        // Rearranged to avoid overflow: amount0 = (liquidity * 2^96 * (sqrtRatioBX96 - sqrtRatioAX96)) / (sqrtRatioAX96 * sqrtRatioBX96)
        
        uint256 numerator1 = uint256(liquidity);
        uint256 numerator2 = uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96);
        uint256 denominator = uint256(sqrtRatioAX96);
        
        // First divide by sqrtRatioAX96 to prevent overflow
        amount0 = mulDiv(numerator1, numerator2, denominator);
        // Then multiply by 2^96 and divide by sqrtRatioBX96
        amount0 = mulDiv(amount0, 1 << 96, uint256(sqrtRatioBX96));
    }
    
    function _getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        
        // Check for underflow
        require(sqrtRatioBX96 >= sqrtRatioAX96, "Invalid sqrt ratio order");
        
        amount1 = mulDiv(uint256(liquidity), uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96), 1 << 96);
    }
    
    /**
     * @notice Calculates (a * b) / denominator with full precision
     * @dev Handles intermediate overflow and underflow
     * @param a First multiplicand
     * @param b Second multiplicand
     * @param denominator Divisor
     * @return result The result of (a * b) / denominator
     */
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        
        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }
        
        require(denominator > prod1);
        
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }
        
        uint256 twos = (type(uint256).max - denominator + 1) & denominator;
        assembly {
            denominator := div(denominator, twos)
        }
        
        assembly {
            prod0 := div(prod0, twos)
        }
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;
        
        uint256 inv = (3 * denominator) ^ 2;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        
        result = prod0 * inv;
    }
    
    /**
     * @notice Quotes the amount of USDC received for a given token amount
     * @dev Uses the quoter to simulate swaps and get expected outputs
     * @param token The token to swap from
     * @param tokenAmount The amount of token to swap
     * @return usdcOut The expected amount of USDC received
     */
    function _quoteUSDCFromToken(address token, uint256 tokenAmount) internal view returns (uint256 usdcOut) {
        if (token == USDC) {
            return tokenAmount;
        }
        
        // Try direct token -> USDC swap
        address directPool = _findBestPool(token, USDC);
        if (directPool != address(0)) {
            // Use staticcall to maintain view function
            bytes memory data = abi.encodeWithSelector(
                IMixedQuoter.quoteExactInputSingle.selector,
                IMixedQuoter.QuoteExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: USDC,
                    amountIn: tokenAmount,
                    tickSpacing: ICLPool(directPool).tickSpacing(),
                    sqrtPriceLimitX96: 0
                })
            );
            
            (bool success, bytes memory result) = address(QUOTER).staticcall(data);
            if (success && result.length >= 32) {
                (usdcOut,,,) = abi.decode(result, (uint256, uint160, uint32, uint256));
                return usdcOut;
            }
        }
        
        // Try multi-hop through common intermediate tokens
        address[5] memory intermediates = [
            WETH,
            USDC, 
            AERO,
            0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA, // USDbC
            0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22  // cbETH
        ];
        
        for (uint256 i = 0; i < intermediates.length; i++) {
            address intermediate = intermediates[i];
            if (intermediate == USDC || intermediate == token) {
                continue;
            }
            
            address pool1 = _findBestPool(token, intermediate);
            address pool2 = _findBestPool(intermediate, USDC);
            
            if (pool1 != address(0) && pool2 != address(0)) {
                bytes memory path = abi.encodePacked(
                    token,
                    CL_FACTORY.tickSpacingToFee(ICLPool(pool1).tickSpacing()),
                    intermediate,
                    CL_FACTORY.tickSpacingToFee(ICLPool(pool2).tickSpacing()),
                    USDC
                );
                
                bytes memory data = abi.encodeWithSelector(
                    IMixedQuoter.quoteExactInput.selector,
                    path,
                    tokenAmount
                );
                
                (bool success, bytes memory result) = address(QUOTER).staticcall(data);
                if (success && result.length >= 32) {
                    (usdcOut,,,) = abi.decode(result, (uint256, uint160[], uint32[], uint256));
                    return usdcOut;
                }
            }
        }
        
        // If quote fails, return a conservative estimate (50% of input amount)
        // This ensures we still have slippage protection even if quoter fails
        return tokenAmount / 2;
    }

    /**
     * @notice Quotes the amount of tokens received for a given USDC amount
     * @dev Uses the quoter to simulate swaps and get expected outputs
     * @param token The token to receive
     * @param usdcAmount The amount of USDC to swap
     * @return amountOut The expected amount of tokens received
     */
    function _quoteUSDCToToken(address token, uint256 usdcAmount) internal view returns (uint256 amountOut) {
        if (token == USDC) {
            return usdcAmount;
        }
        
        // Try direct USDC -> token swap
        address directPool = _findBestPool(USDC, token);
        if (directPool != address(0)) {
            // Use staticcall to maintain view function
            bytes memory data = abi.encodeWithSelector(
                IMixedQuoter.quoteExactInputSingle.selector,
                IMixedQuoter.QuoteExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: token,
                    amountIn: usdcAmount,
                    tickSpacing: ICLPool(directPool).tickSpacing(),
                    sqrtPriceLimitX96: 0
                })
            );
            
            (bool success, bytes memory result) = address(QUOTER).staticcall(data);
            if (success && result.length >= 32) {
                (amountOut,,,) = abi.decode(result, (uint256, uint160, uint32, uint256));
                return amountOut;
            }
        }
        
        // Try multi-hop through common intermediate tokens
        // Add more common tokens for better routing
        address[5] memory intermediates = [
            WETH,
            USDC, 
            AERO,
            0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA, // USDbC
            0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22  // cbETH
        ];
        
        for (uint256 i = 0; i < intermediates.length; i++) {
            address intermediate = intermediates[i];
            if (intermediate == USDC || intermediate == token) {
                continue; // Skip if intermediate is same as USDC or target token
            }
            
            address pool1 = _findBestPool(USDC, intermediate);
            address pool2 = _findBestPool(intermediate, token);
            
            if (pool1 != address(0) && pool2 != address(0)) {
                bytes memory path = abi.encodePacked(
                    USDC,
                    CL_FACTORY.tickSpacingToFee(ICLPool(pool1).tickSpacing()),
                    intermediate,
                    CL_FACTORY.tickSpacingToFee(ICLPool(pool2).tickSpacing()),
                    token
                );
                
                bytes memory data = abi.encodeWithSelector(
                    IMixedQuoter.quoteExactInput.selector,
                    path,
                    usdcAmount
                );
                
                (bool success, bytes memory result) = address(QUOTER).staticcall(data);
                if (success && result.length >= 32) {
                    (amountOut,,,) = abi.decode(result, (uint256, uint160[], uint32[], uint256));
                    return amountOut;
                }
            }
        }
        
        revert("No valid swap path found");
    }
    
    /**
     * @notice Calculates USDC needed to get a specific token amount
     * @dev Uses quoter to determine input needed for exact output
     * @param token The token to receive
     * @param tokenAmount The desired amount of tokens
     * @return usdcNeeded The amount of USDC needed
     */
    function _getUSDCNeededForToken(address token, uint256 tokenAmount) internal view returns (uint256 usdcNeeded) {
        if (token == USDC) {
            return tokenAmount;
        }
        
        // Try direct USDC -> token swap
        address directPool = _findBestPool(USDC, token);
        if (directPool != address(0)) {
            bytes memory data = abi.encodeWithSelector(
                IMixedQuoter.quoteExactOutputSingle.selector,
                IMixedQuoter.QuoteExactOutputSingleParams({
                    tokenIn: USDC,
                    tokenOut: token,
                    amountOut: tokenAmount,
                    tickSpacing: ICLPool(directPool).tickSpacing(),
                    sqrtPriceLimitX96: 0
                })
            );
            
            (bool success, bytes memory result) = address(QUOTER).staticcall(data);
            if (success && result.length >= 32) {
                (usdcNeeded,,,) = abi.decode(result, (uint256, uint160, uint32, uint256));
                return usdcNeeded;
            }
        }
        
        // Try multi-hop through common intermediate tokens
        // Add more common tokens for better routing
        address[5] memory intermediates = [
            WETH,
            USDC, 
            AERO,
            0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA, // USDbC
            0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22  // cbETH
        ];
        
        for (uint256 i = 0; i < intermediates.length; i++) {
            address intermediate = intermediates[i];
            if (intermediate == USDC || intermediate == token) {
                continue; // Skip if intermediate is same as USDC or target token
            }
            
            address pool1 = _findBestPool(USDC, intermediate);
            address pool2 = _findBestPool(intermediate, token);
            
            if (pool1 != address(0) && pool2 != address(0)) {
                // For exact output multi-hop, path is reversed
                bytes memory path = abi.encodePacked(
                    token,
                    CL_FACTORY.tickSpacingToFee(ICLPool(pool2).tickSpacing()),
                    intermediate,
                    CL_FACTORY.tickSpacingToFee(ICLPool(pool1).tickSpacing()),
                    USDC
                );
                
                bytes memory data = abi.encodeWithSelector(
                    IMixedQuoter.quoteExactOutput.selector,
                    path,
                    tokenAmount
                );
                
                (bool success, bytes memory result) = address(QUOTER).staticcall(data);
                if (success && result.length >= 32) {
                    (usdcNeeded,,,) = abi.decode(result, (uint256, uint160[], uint32[], uint256));
                    return usdcNeeded;
                }
            }
        }
        
        // Fallback: estimate with a 20% buffer for safety
        revert("Cannot determine USDC amount needed");
    }
    
    /**
     * @notice Executes optimal swap route from tokenIn to tokenOut
     * @dev Automatically chooses between direct, 2-hop, and 3-hop swaps
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @param minAmountOut The minimum output amount
     */
    function _executeOptimalSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal {
        console.log("\n=== Execute optimal swap ===");
        console.log("TokenIn:", tokenIn);
        console.log("TokenOut:", tokenOut);
        console.log("AmountIn:", amountIn);
        if (tokenIn == tokenOut || amountIn == 0) {
            return;
        }
        
        // Try direct swap first
        address directPool = _findBestPool(tokenIn, tokenOut);
        console.log("Direct pool found:", directPool);
        if (directPool != address(0)) {
            console.log("Using direct swap");
            int24 poolTickSpacing = ICLPool(directPool).tickSpacing();
            uint256 outputAmount = _swapExactInput(tokenIn, tokenOut, amountIn, minAmountOut, poolTickSpacing);
            console.log("Swap output:", outputAmount);
            return;
        }
        
        // Try 2-hop through common intermediate tokens
        address[5] memory intermediates = [
            WETH,
            USDC, 
            AERO,
            0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA, // USDbC
            0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22  // cbETH
        ];
        
        for (uint256 i = 0; i < intermediates.length; i++) {
            address intermediate = intermediates[i];
            if (intermediate == tokenIn || intermediate == tokenOut) {
                continue;
            }
            
            address pool1 = _findBestPool(tokenIn, intermediate);
            address pool2 = _findBestPool(intermediate, tokenOut);
            
            if (pool1 != address(0) && pool2 != address(0)) {
                console.log("Found 2-hop route through:", intermediate);
                console.log("  Pool1:", pool1);
                console.log("  Pool2:", pool2);
                _swapExactInputMultihop(tokenIn, intermediate, tokenOut, amountIn, minAmountOut);
                return;
            }
        }
        
        // Try 3-hop routes for complex cases
        // Common patterns: tokenIn -> intermediate1 -> intermediate2 -> tokenOut
        for (uint256 i = 0; i < intermediates.length; i++) {
            for (uint256 j = 0; j < intermediates.length; j++) {
                if (i == j) continue;
                
                address int1 = intermediates[i];
                address int2 = intermediates[j];
                
                if (int1 == tokenIn || int1 == tokenOut || int2 == tokenIn || int2 == tokenOut) {
                    continue;
                }
                
                address pool1 = _findBestPool(tokenIn, int1);
                address pool2 = _findBestPool(int1, int2);
                address pool3 = _findBestPool(int2, tokenOut);
                
                if (pool1 != address(0) && pool2 != address(0) && pool3 != address(0)) {
                    _swapExactInputThreeHop(tokenIn, int1, int2, tokenOut, amountIn, minAmountOut);
                    return;
                }
            }
        }
        
        revert("No valid swap path found");
    }
    
    /**
     * @notice Executes a multi-hop swap through WETH
     * @dev Swaps tokenIn -> WETH -> tokenOut
     * @param tokenIn The input token
     * @param tokenIntermediate The intermediate token (WETH)
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @param minAmountOut The minimum output amount
     * @return amountOut The actual output amount
     */
    function _swapExactInputMultihop(
        address tokenIn,
        address tokenIntermediate,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        console.log("\n=== Multi-hop swap ===");
        console.log("Path: TokenIn -> Intermediate -> TokenOut");
        console.log("TokenIn:", tokenIn);
        console.log("Intermediate:", tokenIntermediate);
        console.log("TokenOut:", tokenOut);
        console.log("AmountIn:", amountIn);
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), amountIn);
        
        // V3_SWAP_EXACT_IN command
        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs = new bytes[](1);
        
        // Get pool fees
        address pool1 = _findBestPool(tokenIn, tokenIntermediate);
        address pool2 = _findBestPool(tokenIntermediate, tokenOut);
        uint24 fee1 = CL_FACTORY.tickSpacingToFee(ICLPool(pool1).tickSpacing());
        uint24 fee2 = CL_FACTORY.tickSpacingToFee(ICLPool(pool2).tickSpacing());
        
        console.log("Pool1:", pool1);
        console.log("Pool1 fee:", fee1);
        console.log("Pool2:", pool2);
        console.log("Pool2 fee:", fee2);
        
        // Encode multi-hop path
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            abi.encodePacked(tokenIn, fee1, tokenIntermediate, fee2, tokenOut),  // multi-hop path
            true,           // payerIsUser
            true            // useSlipstreamPools (true = use Slipstream/Aerodrome pools)
        );
        
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp + 300);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
    }
    
    /**
     * @notice Finds the best pool for a token pair
     * @dev Checks multiple tick spacings and returns pool with best liquidity
     * @param tokenA First token
     * @param tokenB Second token
     * @return pool The address of the best pool (or zero if none found)
     */
    function _findBestPool(address tokenA, address tokenB) internal view returns (address pool) {
        // All tick spacings on Aerodrome: 1, 10, 50, 100, 200, 2000
        int24[6] memory tickSpacings = [int24(1), int24(10), int24(50), int24(100), int24(200), int24(2000)];
        
        address bestPool = address(0);
        uint128 bestLiquidity = 0;
        
        for (uint256 i = 0; i < tickSpacings.length; i++) {
            address candidatePool = CL_FACTORY.getPool(tokenA, tokenB, tickSpacings[i]);
            if (candidatePool != address(0)) {
                try ICLPool(candidatePool).liquidity() returns (uint128 liquidity) {
                    if (liquidity > bestLiquidity) {
                        bestLiquidity = liquidity;
                        bestPool = candidatePool;
                    }
                } catch {}
            }
        }
        
        return bestPool;
    }
    
    /**
     * @notice Executes a three-hop swap
     * @dev Swaps tokenIn -> intermediate1 -> intermediate2 -> tokenOut
     * @param tokenIn The input token
     * @param intermediate1 The first intermediate token
     * @param intermediate2 The second intermediate token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @param minAmountOut The minimum output amount
     * @return amountOut The actual output amount
     */
    function _swapExactInputThreeHop(
        address tokenIn,
        address intermediate1,
        address intermediate2,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), amountIn);
        
        // V3_SWAP_EXACT_IN command
        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs = new bytes[](1);
        
        // Get pool fees
        address pool1 = _findBestPool(tokenIn, intermediate1);
        address pool2 = _findBestPool(intermediate1, intermediate2);
        address pool3 = _findBestPool(intermediate2, tokenOut);
        
        uint24 fee1 = CL_FACTORY.tickSpacingToFee(ICLPool(pool1).tickSpacing());
        uint24 fee2 = CL_FACTORY.tickSpacingToFee(ICLPool(pool2).tickSpacing());
        uint24 fee3 = CL_FACTORY.tickSpacingToFee(ICLPool(pool3).tickSpacing());
        
        // Encode three-hop path
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            abi.encodePacked(tokenIn, fee1, intermediate1, fee2, intermediate2, fee3, tokenOut),  // three-hop path
            true,           // payerIsUser
            true            // useSlipstreamPools (true = use Slipstream/Aerodrome pools)
        );
        
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp + 300);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
    }
    
    /**
     * @notice Estimates how to split USDC between two tokens
     * @dev External function to enable try/catch
     * @param token0 First token
     * @param token1 Second token  
     * @param amount0 Amount of token0 needed
     * @param amount1 Amount of token1 needed
     * @param totalUSDC Total USDC available
     * @return usdcForToken0 USDC to use for token0
     * @return usdcForToken1 USDC to use for token1
     */
    function estimateUSDCSplit(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 totalUSDC
    ) external view returns (uint256 usdcForToken0, uint256 usdcForToken1) {
        // Try to get quotes for each token
        uint256 quote0 = 0;
        uint256 quote1 = 0;
        
        // Estimate USDC needed for token0
        if (amount0 > 0) {
            try this.estimateUSDCForToken(token0, amount0) returns (uint256 estimate) {
                quote0 = estimate;
            } catch {
                quote0 = totalUSDC / 2; // Fallback to half
            }
        }
        
        // Estimate USDC needed for token1
        if (amount1 > 0) {
            try this.estimateUSDCForToken(token1, amount1) returns (uint256 estimate) {
                quote1 = estimate;
            } catch {
                quote1 = totalUSDC / 2; // Fallback to half
            }
        }
        
        // Adjust if total exceeds available USDC
        if (quote0 + quote1 > totalUSDC) {
            uint256 ratio0 = (quote0 * 1e18) / (quote0 + quote1);
            usdcForToken0 = (totalUSDC * ratio0) / 1e18;
            usdcForToken1 = totalUSDC - usdcForToken0;
        } else {
            usdcForToken0 = quote0;
            usdcForToken1 = quote1;
        }
    }
    
    /**
     * @notice Estimates USDC needed for a token amount
     * @dev Simplified estimation that tries different methods
     * @param token The token to estimate for
     * @param amount The amount of token needed
     * @return The estimated USDC needed
     */
    function estimateUSDCForToken(address token, uint256 amount) external view returns (uint256) {
        if (token == USDC) {
            return amount;
        }
        
        // Try to use the quoter - this might fail for complex routes
        try this.getUSDCNeededForTokenPublic(token, amount) returns (uint256 usdcNeeded) {
            return usdcNeeded;
        } catch {
            // If quoter fails, return a reasonable estimate
            // This is a very rough estimate - in production you'd want better logic
            return amount * 2; // Assume we need 2x the amount in USDC (very conservative)
        }
    }
    
    /**
     * @notice Public wrapper for _getUSDCNeededForToken to enable try/catch
     * @param token The token to get quote for
     * @param tokenAmount The amount of token
     * @return The USDC needed
     */
    function getUSDCNeededForTokenPublic(address token, uint256 tokenAmount) external view returns (uint256) {
        return _getUSDCNeededForToken(token, tokenAmount);
    }
    
    /**
     * @notice Direct pool swap bypassing Universal Router
     * @dev Used when Universal Router doesn't handle specific pools correctly
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @param minAmountOut The minimum output amount
     * @param pool The specific pool to use
     * @return amountOut The output amount received
     */
    function _directPoolSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address pool
    ) internal returns (uint256 amountOut) {
        ICLPool clPool = ICLPool(pool);
        
        // Determine if tokenIn is token0 or token1
        bool zeroForOne = tokenIn == clPool.token0();
        require(zeroForOne ? tokenOut == clPool.token1() : tokenOut == clPool.token0(), "Invalid token pair for pool");
        
        // Approve pool to spend tokenIn
        _safeApprove(tokenIn, pool, amountIn);
        
        // Prepare swap callback data
        bytes memory data = abi.encode(tokenIn, tokenOut, amountIn);
        
        // Calculate sqrt price limit based on swap direction
        uint160 sqrtPriceLimitX96 = zeroForOne 
            ? 4295128739 + 1  // MIN_SQRT_RATIO + 1
            : 1461446703485210103287273052203988822378723970342 - 1; // MAX_SQRT_RATIO - 1
        
        // Execute swap directly on the pool
        try clPool.swap(
            address(this), // recipient
            zeroForOne,    // direction
            int256(amountIn), // amount specified (positive for exact input)
            sqrtPriceLimitX96, // price limit
            data          // callback data
        ) returns (int256 amount0, int256 amount1) {
            amountOut = uint256(-(zeroForOne ? amount1 : amount0));
            require(amountOut >= minAmountOut, "Insufficient output amount");
        } catch Error(string memory reason) {
            console.log("Direct pool swap failed:", reason);
            revert(reason);
        } catch (bytes memory) {
            revert("Direct pool swap failed");
        }
    }
    
    /**
     * @notice Callback for CL pool swaps
     * @dev Called by the pool during swap execution
     */
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode callback data
        (address tokenIn, address tokenOut, uint256 expectedAmountIn) = abi.decode(data, (address, address, uint256));
        
        // Verify callback is from a valid pool
        address pool = CL_FACTORY.getPool(
            tokenIn < tokenOut ? tokenIn : tokenOut,
            tokenIn < tokenOut ? tokenOut : tokenIn,
            ICLPool(msg.sender).tickSpacing()
        );
        require(msg.sender == pool, "Invalid callback");
        
        // Determine amount to pay
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        address tokenToPay = amount0Delta > 0 ? ICLPool(msg.sender).token0() : ICLPool(msg.sender).token1();
        
        // Verify token and amount
        require(tokenToPay == tokenIn, "Invalid token to pay");
        require(amountToPay <= expectedAmountIn, "Amount exceeds expected");
        
        // Transfer tokens to pool
        _safeTransfer(tokenToPay, msg.sender, amountToPay);
    }
    
    /**
     * @notice Emergency withdrawal function for stuck tokens
     * @dev Can only be called by the contract itself (requires governance or upgrade)
     * @param token The token address to withdraw
     */
    function emergencyWithdraw(address token) external {
        require(msg.sender == address(this), "Only contract can call");
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            _safeTransfer(token, msg.sender, balance);
            emit EmergencyWithdraw(msg.sender, token, balance);
        }
    }
    
    /**
     * @notice Handle receipt of NFT
     * @dev Required for receiving NFT positions via safeTransferFrom
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
     * @notice Validates if a pool is from the official factory
     * @param pool The pool address to validate
     * @return isValid True if the pool is valid
     */
    function _isValidPool(address pool) internal view returns (bool isValid) {
        if (pool == address(0)) return false;
        
        try ICLPool(pool).factory() returns (address factory) {
            return factory == address(CL_FACTORY);
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Calculates optimal swap amounts for provided routes
     * @param routes The swap routes
     * @param totalUSDC Total USDC amount available
     * @param token0 Token0 of the target pool
     * @param token1 Token1 of the target pool
     * @param tickLower Lower tick of the position
     * @param tickUpper Upper tick of the position
     * @param pool The target pool address
     * @return swapAmounts Array of amounts to swap for each route
     */
    function _calculateSwapAmounts(
        SwapRoute[] memory routes,
        uint256 totalUSDC,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        address pool
    ) internal view returns (uint256[] memory swapAmounts) {
        swapAmounts = new uint256[](routes.length);
        
        // If no routes, no swaps needed
        if (routes.length == 0) {
            return swapAmounts;
        }
        
        // Check if amounts are pre-specified
        uint256 totalSpecified = 0;
        for (uint256 i = 0; i < routes.length; i++) {
            totalSpecified += routes[i].amountIn;
        }
        
        if (totalSpecified > 0) {
            // Use specified amounts
            require(totalSpecified <= totalUSDC, "Specified amounts exceed total USDC");
            for (uint256 i = 0; i < routes.length; i++) {
                swapAmounts[i] = routes[i].amountIn;
            }
            return swapAmounts;
        }
        
        // Calculate optimal split based on tick position
        (uint160 sqrtPriceX96,,,,,) = ICLPool(pool).slot0();
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        // Determine how much we need of each token
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Below range - need 100% token0
            for (uint256 i = 0; i < routes.length; i++) {
                if (routes[i].tokenOut == token0) {
                    swapAmounts[i] = totalUSDC;
                }
            }
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // Above range - need 100% token1
            for (uint256 i = 0; i < routes.length; i++) {
                if (routes[i].tokenOut == token1) {
                    swapAmounts[i] = totalUSDC;
                }
            }
        } else {
            // In range - calculate split
            uint256 priceRatio = ((uint256(sqrtPriceX96) - uint256(sqrtRatioAX96)) * 1e18) / 
                                 (uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96));
            
            uint256 amountForToken1 = (totalUSDC * priceRatio) / 1e18;
            uint256 amountForToken0 = totalUSDC - amountForToken1;
            
            // Distribute to routes based on output token
            for (uint256 i = 0; i < routes.length; i++) {
                if (routes[i].tokenOut == token0) {
                    swapAmounts[i] = amountForToken0;
                } else if (routes[i].tokenOut == token1) {
                    swapAmounts[i] = amountForToken1;
                }
            }
        }
        
        return swapAmounts;
    }
    
    /**
     * @notice Executes a swap using the provided route
     * @param tokenIn The input token (USDC)
     * @param route The swap route to execute
     * @param amountIn The amount to swap
     * @param slippageBps Slippage tolerance in basis points
     * @return amountOut The amount received from the swap
     */
    function _executeRouteSwap(
        address tokenIn,
        SwapRoute memory route,
        uint256 amountIn,
        uint256 slippageBps
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) {
            return 0;
        }
        
        require(route.pools.length > 0, "Empty route");
        
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), amountIn);
        
        if (route.pools.length == 1) {
            // Direct swap
            int24 tickSpacing = ICLPool(route.pools[0]).tickSpacing();
            return _swapExactInput(tokenIn, route.tokenOut, amountIn, 0, tickSpacing);
        } else {
            // Multi-hop swap
            bytes memory commands = abi.encodePacked(bytes1(0x00)); // V3_SWAP_EXACT_IN
            bytes[] memory inputs = new bytes[](1);
            
            // Build path
            bytes memory path = abi.encodePacked(tokenIn);
            address currentToken = tokenIn;
            
            for (uint256 i = 0; i < route.pools.length; i++) {
                ICLPool pool = ICLPool(route.pools[i]);
                uint24 fee = pool.fee(); // Use actual fee from pool, not factory mapping
                
                // Determine next token
                address token0 = pool.token0();
                address token1 = pool.token1();
                address nextToken;
                
                if (i == route.pools.length - 1) {
                    // Last hop - must end with route.tokenOut
                    nextToken = route.tokenOut;
                    require(nextToken == token0 || nextToken == token1, "Invalid final token");
                } else {
                    // Intermediate hop - find common token with next pool
                    ICLPool nextPool = ICLPool(route.pools[i + 1]);
                    address nextToken0 = nextPool.token0();
                    address nextToken1 = nextPool.token1();
                    
                    if ((token0 == nextToken0 || token0 == nextToken1) && token0 != currentToken) {
                        nextToken = token0;
                    } else if ((token1 == nextToken0 || token1 == nextToken1) && token1 != currentToken) {
                        nextToken = token1;
                    } else {
                        revert("No common token between pools");
                    }
                }
                
                path = abi.encodePacked(path, fee, nextToken);
                currentToken = nextToken;
            }
            
            // Calculate minimum output with slippage
            uint256 expectedOut = _quoteMultihopSwap(path, amountIn);
            uint256 minOut = _calculateMinimumOutput(expectedOut, slippageBps);
            
            inputs[0] = abi.encode(
                address(this),  // recipient
                amountIn,       // amountIn
                minOut,         // amountOutMinimum
                path,           // multi-hop path
                true,           // payerIsUser
                true            // useSlipstreamPools
            );
            
            uint256 balanceBefore = IERC20(route.tokenOut).balanceOf(address(this));
            UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp + 300);
            amountOut = IERC20(route.tokenOut).balanceOf(address(this)) - balanceBefore;
        }
    }
    
    /**
     * @notice Quotes a multi-hop swap
     * @param path The encoded swap path
     * @param amountIn The input amount
     * @return amountOut The expected output amount
     */
    function _quoteMultihopSwap(bytes memory path, uint256 amountIn) internal returns (uint256 amountOut) {
        try QUOTER.quoteExactInput(path, amountIn) returns (
            uint256 _amountOut,
            uint160[] memory,
            uint32[] memory,
            uint256
        ) {
            return _amountOut;
        } catch {
            // If quote fails, return conservative estimate
            return (amountIn * 90) / 100; // 90% of input as fallback
        }
    }
    
    /**
     * @notice Checks if routes can be optimized through a common intermediate token
     * @param routes The swap routes
     * @param token0 Token0 of the pool
     * @param token1 Token1 of the pool
     * @return True if optimization is possible
     */
    function _shouldOptimizeRoute(
        SwapRoute[] memory routes,
        address token0,
        address token1
    ) internal pure returns (bool) {
        // Optimization is possible if:
        // 1. We have exactly 1 route
        // 2. One of the pool tokens (WETH typically) can be used as intermediate
        if (routes.length != 1) return false;
        
        // Check if the route ends with a token that's not in the pool
        // and one of the pool tokens could be an intermediate
        address targetToken = routes[0].tokenOut;
        
        // If we're routing to a pool token and the other token is WETH, we can optimize
        if (targetToken == token1 && token0 == WETH) return true;
        if (targetToken == token0 && token1 == WETH) return true;
        
        return false;
    }
    
    /**
     * @notice Executes optimized route through intermediate token
     * @param routes The swap routes
     * @param usdcAmount Total USDC amount
     * @param token0 Token0 of the pool
     * @param token1 Token1 of the pool
     * @param swapAmounts Calculated swap amounts
     * @param slippageBps Slippage tolerance
     */
    function _executeOptimizedRoute(
        SwapRoute[] memory routes,
        uint256 usdcAmount,
        address token0,
        address token1,
        uint256[] memory swapAmounts,
        uint256 slippageBps
    ) internal {
        // Determine intermediate token (usually WETH)
        address intermediateToken = token0 == WETH ? token0 : token1;
        address targetToken = routes[0].tokenOut;
        
        require(intermediateToken == WETH, "Optimization only supported for WETH");
        require(targetToken == token0 || targetToken == token1, "Invalid target token");
        
        // First, swap all USDC to intermediate token (WETH)
        address usdcToIntermediatePool = routes[0].pools[0];
        _safeApprove(USDC, address(UNIVERSAL_ROUTER), usdcAmount);
        
        int24 tickSpacing = ICLPool(usdcToIntermediatePool).tickSpacing();
        uint256 intermediateAmount = _swapExactInput(
            USDC,
            intermediateToken,
            usdcAmount,
            0,
            tickSpacing
        );
        
        // Now we have all funds in intermediate token
        // Calculate how much to keep vs swap
        uint256 amountToSwap = 0;
        
        if (targetToken != intermediateToken) {
            // Need to swap some intermediate token to target token
            // The swapAmounts array tells us how much USDC worth to swap
            // We need to calculate the proportional amount of intermediate token
            
            if (swapAmounts[0] > 0 && usdcAmount > 0) {
                amountToSwap = (intermediateAmount * swapAmounts[0]) / usdcAmount;
            }
            
            if (amountToSwap > 0 && amountToSwap < intermediateAmount) {
                // Execute the swap from intermediate to target
                address intermediateToTargetPool = routes[0].pools[1];
                _safeApprove(intermediateToken, address(UNIVERSAL_ROUTER), amountToSwap);
                
                tickSpacing = ICLPool(intermediateToTargetPool).tickSpacing();
                _swapExactInput(
                    intermediateToken,
                    targetToken,
                    amountToSwap,
                    0,
                    tickSpacing
                );
            }
        }
    }
    
    /**
     * @notice Checks if a route is valid for a given input token
     * @param route The swap route
     * @param tokenIn The input token to check
     * @return True if route starts with tokenIn
     */
    function _isRouteForToken(SwapRoute memory route, address tokenIn) internal view returns (bool) {
        if (route.pools.length == 0) return false;
        
        // Check if first pool contains tokenIn
        ICLPool firstPool = ICLPool(route.pools[0]);
        return firstPool.token0() == tokenIn || firstPool.token1() == tokenIn;
    }
    
    /**
     * @notice Executes a swap route for exit (token -> USDC)
     * @param tokenIn The input token
     * @param route The swap route
     * @param amountIn The amount to swap
     * @param slippageBps Slippage tolerance
     * @return amountOut The USDC received
     */
    function _executeExitRouteSwap(
        address tokenIn,
        SwapRoute memory route,
        uint256 amountIn,
        uint256 slippageBps
    ) internal returns (uint256 amountOut) {
        require(route.tokenOut == USDC, "Exit routes must end with USDC");
        
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), amountIn);
        
        if (route.pools.length == 1) {
            // Direct swap
            int24 tickSpacing = ICLPool(route.pools[0]).tickSpacing();
            return _swapExactInput(tokenIn, USDC, amountIn, 0, tickSpacing);
        } else {
            // Multi-hop swap
            bytes memory commands = abi.encodePacked(bytes1(0x00)); // V3_SWAP_EXACT_IN
            bytes[] memory inputs = new bytes[](1);
            
            // Build path
            bytes memory path = abi.encodePacked(tokenIn);
            address currentToken = tokenIn;
            
            for (uint256 i = 0; i < route.pools.length; i++) {
                ICLPool pool = ICLPool(route.pools[i]);
                uint24 fee = pool.fee(); // Use actual fee from pool, not factory mapping
                
                // Determine next token
                address token0 = pool.token0();
                address token1 = pool.token1();
                address nextToken;
                
                if (i == route.pools.length - 1) {
                    // Last hop must end with USDC
                    nextToken = USDC;
                    require(nextToken == token0 || nextToken == token1, "Invalid final token");
                } else {
                    // Find common token with next pool
                    ICLPool nextPool = ICLPool(route.pools[i + 1]);
                    address nextToken0 = nextPool.token0();
                    address nextToken1 = nextPool.token1();
                    
                    if ((token0 == nextToken0 || token0 == nextToken1) && token0 != currentToken) {
                        nextToken = token0;
                    } else if ((token1 == nextToken0 || token1 == nextToken1) && token1 != currentToken) {
                        nextToken = token1;
                    } else {
                        revert("No common token between pools");
                    }
                }
                
                path = abi.encodePacked(path, fee, nextToken);
                currentToken = nextToken;
            }
            
            // Quote the swap for slippage protection
            uint256 expectedOut = _quoteMultihopSwap(path, amountIn);
            uint256 minOut = _calculateMinimumOutput(expectedOut, slippageBps);
            
            inputs[0] = abi.encode(
                address(this),  // recipient
                amountIn,       // amountIn
                minOut,         // amountOutMinimum
                path,           // multi-hop path
                true,           // payerIsUser
                true            // useSlipstreamPools
            );
            
            uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));
            UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp + 300);
            amountOut = IERC20(USDC).balanceOf(address(this)) - balanceBefore;
        }
    }
}