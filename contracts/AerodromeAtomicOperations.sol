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

/**
 * @title AerodromeAtomicOperations
 * @author N0IR
 * @notice Atomic operations for Aerodrome Finance concentrated liquidity positions
 * @dev Provides atomic swap, mint, stake, and exit operations for Aerodrome CL pools
 */
contract AerodromeAtomicOperations is AtomicBase {
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
     * @notice Constructor sets the CDP wallet registry
     * @param _walletRegistry The address of the CDP wallet registry contract
     */
    constructor(address _walletRegistry) {
        require(_walletRegistry != address(0), "Invalid registry address");
        walletRegistry = CDPWalletRegistry(_walletRegistry);
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
     */
    struct SwapMintParams {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint256 usdcAmount;
        uint256 minLiquidity;
        uint256 deadline;
        bool stake;
    }
    
    /**
     * @notice Parameters for exit operations
     * @param tokenId The ID of the position NFT to exit
     * @param minUsdcOut The minimum amount of USDC to receive (if swapping)
     * @param deadline The deadline timestamp for the transaction
     * @param swapToUsdc Whether to swap all assets to USDC on exit
     */
    struct ExitParams {
        uint256 tokenId;
        uint256 minUsdcOut;
        uint256 deadline;
        bool swapToUsdc;
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
        _safeTransferFrom(USDC, msg.sender, address(this), params.usdcAmount);
        
        _validatePool(params.pool, address(CL_FACTORY));
        
        ICLPool pool = ICLPool(params.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        int24 tickSpacing = pool.tickSpacing();
        
        _validateTickRange(params.tickLower, params.tickUpper, tickSpacing);
        
        (uint256 amount0Desired, uint256 amount1Desired) = _calculateOptimalAmounts(
            token0,
            token1,
            params.usdcAmount,
            params.tickLower,
            params.tickUpper,
            params.pool
        );
        
        _performSwapsForLiquidity(
            token0,
            token1,
            amount0Desired,
            amount1Desired
        );
        
        _safeApprove(token0, address(POSITION_MANAGER), amount0Desired);
        _safeApprove(token1, address(POSITION_MANAGER), amount1Desired);
        
        (tokenId, liquidity,,) = POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickSpacing: tickSpacing,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: _calculateMinimumOutput(amount0Desired, DEFAULT_SLIPPAGE_BPS),
                amount1Min: _calculateMinimumOutput(amount1Desired, DEFAULT_SLIPPAGE_BPS),
                recipient: params.stake ? address(this) : msg.sender,
                deadline: params.deadline,
                sqrtPriceX96: 0
            })
        );
        
        require(liquidity >= params.minLiquidity, "Insufficient liquidity minted");
        
        if (params.stake) {
            address gauge = IGaugeFactory(GAUGE_FACTORY).gauges(params.pool);
            require(gauge != address(0), "No gauge found for pool");
            
            POSITION_MANAGER.approve(gauge, tokenId);
            IGauge(gauge).stake(tokenId);
        }
        
        emit PositionOpened(msg.sender, tokenId, params.pool, params.usdcAmount, liquidity, params.stake);
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
        return this.swapMintAndStake(modifiedParams);
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
        returns (uint256 usdcOut, uint256 aeroRewards)
    {
        (,, address token0, address token1, int24 tickSpacing,, , uint128 liquidity,,,,) = POSITION_MANAGER.positions(params.tokenId);
        require(liquidity > 0, "Position has no liquidity");
        
        address pool = CL_FACTORY.getPool(token0, token1, tickSpacing);
        address gauge = IGaugeFactory(GAUGE_FACTORY).gauges(pool);
        
        if (gauge != address(0) && IGauge(gauge).stakedContains(msg.sender, params.tokenId)) {
            IGauge(gauge).unstake(params.tokenId);
            aeroRewards = IERC20(AERO).balanceOf(address(this));
            IGauge(gauge).getReward(params.tokenId);
            aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroRewards;
        }
        
        require(POSITION_MANAGER.ownerOf(params.tokenId) == msg.sender, "Not token owner");
        
        POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), params.tokenId);
        
        (uint256 amount0, uint256 amount1) = POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: params.tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
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
            usdcOut = _swapAllToUsdc(token0, token1, amount0, amount1, aeroRewards);
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
        address gauge = IGaugeFactory(GAUGE_FACTORY).gauges(pool);
        require(gauge != address(0), "No gauge found");
        
        require(IGauge(gauge).stakedContains(msg.sender, tokenId), "Position not staked");
        
        aeroAmount = IGauge(gauge).earned(tokenId);
        require(aeroAmount > 0, "No rewards to claim");
        
        IGauge(gauge).getReward(tokenId);
        
        if (minUsdcOut > 0) {
            _safeApprove(AERO, address(UNIVERSAL_ROUTER), aeroAmount);
            usdcReceived = _swapExactInput(AERO, USDC, aeroAmount, minUsdcOut);
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
        (,, address token0, address token1, int24 tickSpacing,, , uint128 liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
        require(liquidity > 0, "Position has no liquidity");
        
        address pool = CL_FACTORY.getPool(token0, token1, tickSpacing);
        address gauge = IGaugeFactory(GAUGE_FACTORY).gauges(pool);
        
        if (gauge != address(0) && IGauge(gauge).stakedContains(msg.sender, tokenId)) {
            IGauge(gauge).unstake(tokenId);
            aeroRewards = IERC20(AERO).balanceOf(address(this));
            IGauge(gauge).getReward(tokenId);
            aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroRewards;
        }
        
        require(POSITION_MANAGER.ownerOf(tokenId) == msg.sender, "Not token owner");
        
        POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), tokenId);
        
        (amount0, amount1) = POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
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
     * @notice Performs necessary swaps from USDC to get required token amounts
     * @dev Intelligently routes swaps through optimal paths
     * @param token0 The address of token0
     * @param token1 The address of token1
     * @param amount0Needed The amount of token0 needed
     * @param amount1Needed The amount of token1 needed
     */
    function _performSwapsForLiquidity(
        address token0,
        address token1,
        uint256 amount0Needed,
        uint256 amount1Needed
    ) internal {
        uint256 totalUSDC = IERC20(USDC).balanceOf(address(this));
        
        // Handle special cases
        if (token0 == USDC && token1 == USDC) {
            return; // Both are USDC, no swap needed
        }
        
        if (token0 == USDC) {
            // Only swap for token1
            if (amount1Needed > 0) {
                // Use most of the USDC for token1, keeping some for token0
                uint256 usdcForToken1 = (totalUSDC * amount1Needed) / (amount0Needed + amount1Needed);
                _executeOptimalSwap(USDC, token1, usdcForToken1, 0);
            }
            return;
        }
        
        if (token1 == USDC) {
            // Only swap for token0
            if (amount0Needed > 0) {
                // Use most of the USDC for token0, keeping some for token1
                uint256 usdcForToken0 = (totalUSDC * amount0Needed) / (amount0Needed + amount1Needed);
                _executeOptimalSwap(USDC, token0, usdcForToken0, 0);
            }
            return;
        }
        
        // Neither token is USDC - need to swap for both
        // First, check what portion of USDC we need for each token based on the amounts
        uint256 usdcForToken0;
        uint256 usdcForToken1;
        
        // Try to quote amounts needed - if it fails, use a simple split
        try this.estimateUSDCSplit(token0, token1, amount0Needed, amount1Needed, totalUSDC) 
            returns (uint256 usdc0, uint256 usdc1) {
            usdcForToken0 = usdc0;
            usdcForToken1 = usdc1;
        } catch {
            // Fallback: split proportionally based on amounts needed
            if (amount0Needed == 0) {
                usdcForToken0 = 0;
                usdcForToken1 = totalUSDC;
            } else if (amount1Needed == 0) {
                usdcForToken0 = totalUSDC;
                usdcForToken1 = 0;
            } else {
                // Split 50/50 as a simple fallback
                usdcForToken0 = totalUSDC / 2;
                usdcForToken1 = totalUSDC - usdcForToken0;
            }
        }
        
        // Execute swaps
        if (usdcForToken0 > 0 && amount0Needed > 0) {
            _executeOptimalSwap(USDC, token0, usdcForToken0, 0);
        }
        
        if (usdcForToken1 > 0 && amount1Needed > 0) {
            // Use remaining USDC for token1
            uint256 remainingUSDC = IERC20(USDC).balanceOf(address(this));
            if (remainingUSDC > 0) {
                _executeOptimalSwap(USDC, token1, remainingUSDC, 0);
            }
        }
    }
    
    /**
     * @notice Swaps all tokens to USDC
     * @dev Used during exit to convert all assets to USDC
     * @param token0 The address of token0
     * @param token1 The address of token1
     * @param amount0 The amount of token0 to swap
     * @param amount1 The amount of token1 to swap
     * @param aeroAmount The amount of AERO to swap
     * @return totalUsdc The total USDC received from all swaps
     */
    function _swapAllToUsdc(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 aeroAmount
    ) internal returns (uint256 totalUsdc) {
        if (token0 == USDC) {
            totalUsdc += amount0;
        } else if (amount0 > 0) {
            totalUsdc += _swapExactInput(token0, USDC, amount0, 0);
        }
        
        if (token1 == USDC) {
            totalUsdc += amount1;
        } else if (amount1 > 0) {
            totalUsdc += _swapExactInput(token1, USDC, amount1, 0);
        }
        
        if (aeroAmount > 0) {
            totalUsdc += _swapExactInput(AERO, USDC, aeroAmount, 0);
        }
    }
    
    /**
     * @notice Swaps an exact amount of input token for output token
     * @dev Uses Universal Router V3_SWAP_EXACT_IN command (0x00)
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountIn The exact input amount
     * @param minAmountOut The minimum output amount
     * @return amountOut The actual output amount received
     */
    function _swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), amountIn);
        
        // V3_SWAP_EXACT_IN command
        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs = new bytes[](1);
        
        // Get pool fee from factory
        int24 tickSpacing = _getTickSpacingForPair(tokenIn, tokenOut);
        uint24 fee = CL_FACTORY.tickSpacingToFee(tickSpacing);
        
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            abi.encodePacked(tokenIn, fee, tokenOut),  // path with fee
            true,           // payerIsUser (we already have tokens)
            false           // useSlipstreamPools (false = use UniV3 pools, which is what Aerodrome CL pools are)
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
        
        // Get pool fee from factory
        int24 tickSpacing = _getTickSpacingForPair(tokenIn, tokenOut);
        uint24 fee = CL_FACTORY.tickSpacingToFee(tickSpacing);
        
        // For exact output, path is reversed (tokenOut -> tokenIn)
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountOut,      // amountOut
            maxAmountIn,    // amountInMaximum
            abi.encodePacked(tokenOut, fee, tokenIn),  // reversed path with fee
            true,           // payerIsUser
            false           // useSlipstreamPools (false = use UniV3 pools)
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
        // Common tick spacings on Aerodrome as per routing spec: 1, 10, 60, 200
        int24[4] memory commonTickSpacings = [int24(1), int24(10), int24(60), int24(200)];
        
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
        uint256 intermediate = mulDiv(sqrtRatioAX96, sqrtRatioBX96, 1 << 96);
        liquidity = mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96);
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
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = _getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = _getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = _getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = _getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }
    
    function _getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        amount0 = mulDiv(
            uint256(liquidity) << 96,
            sqrtRatioBX96 - sqrtRatioAX96,
            sqrtRatioBX96
        ) / sqrtRatioAX96;
    }
    
    function _getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        amount1 = mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96);
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
        if (tokenIn == tokenOut || amountIn == 0) {
            return;
        }
        
        // Try direct swap first
        address directPool = _findBestPool(tokenIn, tokenOut);
        if (directPool != address(0)) {
            _swapExactInput(tokenIn, tokenOut, amountIn, minAmountOut);
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
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), amountIn);
        
        // V3_SWAP_EXACT_IN command
        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs = new bytes[](1);
        
        // Get pool fees
        address pool1 = _findBestPool(tokenIn, tokenIntermediate);
        address pool2 = _findBestPool(tokenIntermediate, tokenOut);
        uint24 fee1 = CL_FACTORY.tickSpacingToFee(ICLPool(pool1).tickSpacing());
        uint24 fee2 = CL_FACTORY.tickSpacingToFee(ICLPool(pool2).tickSpacing());
        
        // Encode multi-hop path
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            abi.encodePacked(tokenIn, fee1, tokenIntermediate, fee2, tokenOut),  // multi-hop path
            true,           // payerIsUser
            false           // useSlipstreamPools (false = use UniV3 pools)
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
        // Common tick spacings on Aerodrome as per routing spec: 1, 10, 60, 200
        int24[4] memory tickSpacings = [int24(1), int24(10), int24(60), int24(200)];
        
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
            false           // useSlipstreamPools (false = use UniV3 pools)
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
}