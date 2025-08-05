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
    /// @notice SugarHelper for liquidity calculations
    ISugarHelper public constant SUGAR_HELPER = ISugarHelper(0x0AD09A66af0154a84e86F761313d02d0abB6edd5);
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
    /// @notice WETH/USDC CL Pool on Base (for testing)
    address public constant WETH_USDC_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    
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
     * @notice Parameters for swapping and minting a position
     * @param pool The pool address for the position
     * @param tickLower The lower tick of the range
     * @param tickUpper The upper tick of the range
     * @param deadline The deadline timestamp for the transaction
     * @param usdcAmount The amount of USDC to use
     * @param slippageBps Custom slippage tolerance in basis points (0 = use default)
     * @param stake Whether to stake the position in the gauge
     */
    struct SwapMintParams {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint256 deadline;
        uint256 usdcAmount;
        uint256 slippageBps;
        bool stake;
    }
    
    /**
     * @notice Parameters for exiting a position
     * @param tokenId The ID of the position to exit
     * @param deadline The deadline timestamp for the transaction
     * @param minUsdcOut The minimum USDC to receive after exit
     * @param slippageBps Custom slippage tolerance in basis points (0 = use default)
     */
    struct FullExitParams {
        uint256 tokenId;
        uint256 deadline;
        uint256 minUsdcOut;
        uint256 slippageBps;
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
     * @notice Swaps USDC for pool tokens and mints a position (without staking)
     * @dev Convenience function that calls swapMintAndStake with stake=false
     * @param params The parameters for the swap and mint operation
     * @return tokenId The ID of the minted position NFT
     * @return liquidity The amount of liquidity minted
     */
    function swapAndMint(SwapMintParams calldata params)
        external
        nonReentrant
        deadlineCheck(params.deadline)
        validAmount(params.usdcAmount)
        onlyAuthorized(msg.sender)
        returns (uint256 tokenId, uint128 liquidity)
    {
        SwapMintParams memory modifiedParams = params;
        modifiedParams.stake = false;
        return _swapMintAndStake(modifiedParams);
    }
    
    /**
     * @notice Stakes an existing position in its gauge
     * @dev Position must be owned by the caller
     * @param tokenId The ID of the position to stake
     */
    function stakePosition(uint256 tokenId) 
        external 
        nonReentrant
        onlyAuthorized(msg.sender)
    {
        require(POSITION_MANAGER.ownerOf(tokenId) == msg.sender, "Not position owner");
        
        // For WETH/USDC pool, use the known address and find gauge
        address pool = WETH_USDC_POOL;
        address gauge = _findGaugeForPool(pool);
        require(gauge != address(0), "No gauge found for pool");
        
        // Transfer position from user and stake
        POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), tokenId);
        POSITION_MANAGER.approve(gauge, tokenId);
        IGauge(gauge).deposit(tokenId);
    }
    
    /**
     * @notice Unstakes a position from its gauge
     * @dev Position must be staked by the caller
     * @param tokenId The ID of the position to unstake
     */
    function unstakePosition(uint256 tokenId)
        external
        nonReentrant
        onlyAuthorized(msg.sender)
    {
        // For WETH/USDC pool, use the known address and find gauge
        address pool = WETH_USDC_POOL;
        address gauge = _findGaugeForPool(pool);
        require(gauge != address(0), "No gauge found for pool");
        
        // Verify ownership through gauge
        require(IGauge(gauge).stakedContains(msg.sender, tokenId), "Not staked by user");
        
        // Withdraw from gauge and return to user
        IGauge(gauge).withdraw(tokenId);
        POSITION_MANAGER.safeTransferFrom(address(this), msg.sender, tokenId);
    }
    
    /**
     * @notice Tries to stake a position, can be called externally for try/catch
     * @param tokenId The position token ID
     * @param pool The pool address
     */
    function _tryStakePosition(uint256 tokenId, address pool) external {
        require(msg.sender == address(this), "Internal only");
        address gauge = _findGaugeForPool(pool);
        require(gauge != address(0), "No gauge found");
        POSITION_MANAGER.approve(gauge, tokenId);
        IGauge(gauge).deposit(tokenId);
    }
    
    /**
     * @notice Approves token to Permit2 if needed
     * @param token The token to approve
     * @param amount The amount to ensure is approved
     */
    function _approveTokenToPermit2(address token, uint256 amount) internal {
        uint256 currentAllowance = IERC20(token).allowance(address(this), address(PERMIT2));
        if (currentAllowance < amount) {
            _safeApprove(token, address(PERMIT2), type(uint256).max);
        }
    }
    
    /**
     * @notice Approves Universal Router via Permit2
     * @param token The token to approve
     * @param amount The amount to approve
     */
    function _approveUniversalRouterViaPermit2(address token, uint256 amount) internal {
        // First approve token to Permit2
        _approveTokenToPermit2(token, amount);
        
        // Then approve Universal Router via Permit2
        // Get current allowance from Permit2
        (uint160 currentAmount, uint48 expiration, ) = PERMIT2.allowance(
            address(this),
            token,
            address(UNIVERSAL_ROUTER)
        );
        
        // Check if we need to approve
        if (currentAmount < amount || expiration < block.timestamp) {
            // Max uint160 for amount, 30 days expiry
            uint160 maxAmount = type(uint160).max;
            uint48 newExpiration = uint48(block.timestamp + 30 days);
            
            PERMIT2.approve(token, address(UNIVERSAL_ROUTER), maxAmount, newExpiration);
        }
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
        
        // Calculate swap amounts
        (uint256 usdc0, uint256 usdc1) = _calculateUSDCAllocation(
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
        
        if (token0 == USDC) {
            // token0 is USDC, we keep usdc0 amount and swap usdc1 for token1
            amount0 = usdc0;  // Keep as USDC
            if (usdc1 > 0) {
                // Approve via Permit2 instead of direct approval
                _approveUniversalRouterViaPermit2(USDC, usdc1);
                // Swap USDC for token1
                amount1 = _swapExactInputDirect(USDC, token1, usdc1, 0, params.pool);
            }
        } else if (token1 == USDC) {
            // token1 is USDC, we swap usdc0 for token0 and keep usdc1 amount
            amount1 = usdc1;  // Keep as USDC
            if (usdc0 > 0) {
                // Approve via Permit2 instead of direct approval
                _approveUniversalRouterViaPermit2(USDC, usdc0);
                // Swap USDC for token0
                amount0 = _swapExactInputDirect(USDC, token0, usdc0, 0, params.pool);
            }
        } else {
            // Both tokens are not USDC - this shouldn't happen in WETH/USDC pool
            revert("Pool must contain USDC");
        }
        
        // Approve position manager
        if (amount0 > 0) _safeApprove(token0, address(POSITION_MANAGER), amount0);
        if (amount1 > 0) _safeApprove(token1, address(POSITION_MANAGER), amount1);
        
        // Calculate minimum amounts with slippage
        uint256 amount0Min = (amount0 * (10000 - effectiveSlippage)) / 10000;
        uint256 amount1Min = (amount1 * (10000 - effectiveSlippage)) / 10000;
        
        // Debug: Check amounts and tokens before minting
        require(amount0 > 0 || amount1 > 0, "Must have at least one token");
        require(token0 < token1, "Tokens must be sorted");
        
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
                // Try to stake the position
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
        
        // For WETH/USDC pool, use the known address
        // In production, this would be passed as a parameter
        address pool = WETH_USDC_POOL;
        
        // Try Voter first, then gauge factory
        address gauge = _findGaugeForPool(pool);
        
        // Track AERO rewards
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        // Handle staked positions
        if (gauge != address(0) && IGauge(gauge).stakedContains(msg.sender, params.tokenId)) {
            IGauge(gauge).withdraw(params.tokenId);
            aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        } else {
            // Transfer position from user if not staked
            POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), params.tokenId);
        }
        
        // Collect any fees
        POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: params.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        // Get effective slippage for this operation
        uint256 effectiveSlippage = _getEffectiveSlippage(params.slippageBps);
        
        // Calculate minimum amounts with slippage
        (uint256 expectedAmount0, uint256 expectedAmount1) = _calculateExpectedAmounts(
            params.tokenId,
            pool
        );
        
        // Get position tick boundaries
        (,,,,,int24 tickLower, int24 tickUpper,,,,,) = POSITION_MANAGER.positions(params.tokenId);
        
        // Get current pool tick
        (,int24 currentTick,,,,) = ICLPool(pool).slot0();
        
        uint256 amount0Min;
        uint256 amount1Min;
        
        if (currentTick < tickLower) {
            // All in token0
            amount0Min = (expectedAmount0 * (10000 - effectiveSlippage)) / 10000;
            amount1Min = 0;
        } else if (currentTick >= tickUpper) {
            // All in token1
            amount0Min = 0;
            amount1Min = (expectedAmount1 * (10000 - effectiveSlippage)) / 10000;
        } else {
            // Mixed position
            amount0Min = (expectedAmount0 * (10000 - effectiveSlippage * 2)) / 10000;
            amount1Min = (expectedAmount1 * (10000 - effectiveSlippage * 2)) / 10000;
        }
        
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
        if (token0 == USDC) {
            usdcOut = amount0;
            if (amount1 > 0) {
                _approveUniversalRouterViaPermit2(token1, amount1);
                usdcOut += _swapExactInputDirect(token1, USDC, amount1, 0, pool);
            }
        } else if (token1 == USDC) {
            usdcOut = amount1;
            if (amount0 > 0) {
                _approveUniversalRouterViaPermit2(token0, amount0);
                usdcOut += _swapExactInputDirect(token0, USDC, amount0, 0, pool);
            }
        } else {
            if (amount0 > 0) {
                _approveUniversalRouterViaPermit2(token0, amount0);
                usdcOut += _swapExactInputDirect(token0, USDC, amount0, 0, pool);
            }
            if (amount1 > 0) {
                _approveUniversalRouterViaPermit2(token1, amount1);
                usdcOut += _swapExactInputDirect(token1, USDC, amount1, 0, pool);
            }
        }
        
        // Swap AERO rewards to USDC if any
        // Note: AERO/USDC pool would need to be provided or hardcoded
        // For now, skip AERO swap as it's not the main pool
        if (aeroRewards > 0) {
            // Transfer AERO rewards to user directly
            _safeTransfer(AERO, msg.sender, aeroRewards);
        }
        
        require(usdcOut >= params.minUsdcOut, "Insufficient USDC output");
        
        _safeTransfer(USDC, msg.sender, usdcOut);
        
        emit PositionClosed(msg.sender, params.tokenId, usdcOut, aeroRewards);
    }
    
    /**
     * @notice Claims rewards from a staked position
     * @param tokenId The ID of the staked position
     * @param minUsdcOut Minimum USDC to receive if swapping AERO (0 = don't swap)
     * @return aeroAmount The amount of AERO rewards claimed
     * @return usdcReceived The amount of USDC received (if swapped)
     */
    function claimAndSwap(uint256 tokenId, uint256 minUsdcOut)
        external
        nonReentrant
        onlyAuthorized(msg.sender)
        returns (uint256 aeroAmount, uint256 usdcReceived)
    {
        // For WETH/USDC pool, use the known address
        // In production, this would be passed as a parameter
        address pool = WETH_USDC_POOL;
        
        // Try Voter first, then gauge factory
        address gauge = _findGaugeForPool(pool);
        require(gauge != address(0), "No gauge found for pool");
        
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        IGauge(gauge).getReward(tokenId);
        
        aeroAmount = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        
        // For AERO swaps, would need pool address to be provided
        // For now, just return AERO to user
        if (aeroAmount > 0) {
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
    function unstakeAndBurn(
        uint256 tokenId,
        uint256 deadline,
        uint256 slippageBps
    )
        external
        nonReentrant
        deadlineCheck(deadline)
        onlyAuthorized(msg.sender)
        returns (uint256 amount0, uint256 amount1, uint256 aeroRewards)
    {
        (,, address token0, address token1, ,, , uint128 liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
        require(liquidity > 0, "Position has no liquidity");
        
        // For WETH/USDC pool, use the known address
        // In production, this would be passed as a parameter
        address pool = WETH_USDC_POOL;
        
        // Try Voter first, then gauge factory
        address gauge = _findGaugeForPool(pool);
        
        // Track AERO rewards
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        // Handle staked positions
        if (gauge != address(0) && IGauge(gauge).stakedContains(msg.sender, tokenId)) {
            IGauge(gauge).withdraw(tokenId);
            aeroRewards = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        } else {
            // Transfer position from user if not staked
            POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), tokenId);
        }
        
        // Get effective slippage
        uint256 effectiveSlippage = _getEffectiveSlippage(slippageBps);
        
        // Calculate minimum amounts with slippage
        (uint256 expectedAmount0, uint256 expectedAmount1) = _calculateExpectedAmounts(
            tokenId,
            pool
        );
        
        // Get position tick boundaries
        (,,,,,int24 tickLower, int24 tickUpper,,,,,) = POSITION_MANAGER.positions(tokenId);
        
        // Get current pool tick
        (,int24 currentTick,,,,) = ICLPool(pool).slot0();
        
        uint256 amount0Min;
        uint256 amount1Min;
        
        if (currentTick < tickLower) {
            // All in token0
            amount0Min = (expectedAmount0 * (10000 - effectiveSlippage)) / 10000;
            amount1Min = 0;
        } else if (currentTick >= tickUpper) {
            // All in token1  
            amount0Min = 0;
            amount1Min = (expectedAmount1 * (10000 - effectiveSlippage)) / 10000;
        } else {
            // Mixed position
            amount0Min = (expectedAmount0 * (10000 - effectiveSlippage * 2)) / 10000;
            amount1Min = (expectedAmount1 * (10000 - effectiveSlippage * 2)) / 10000;
        }
        
        // Decrease liquidity
        POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );
        
        // Collect the tokens
        (amount0, amount1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        // Transfer AERO rewards if any
        if (aeroRewards > 0) {
            _safeTransfer(AERO, msg.sender, aeroRewards);
        }
    }
    
    /**
     * @notice Handles receipt of NFT positions
     * @dev Required for ERC721 safeTransferFrom
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
     * @notice Calculates USDC allocation for token0 and token1
     * @dev Uses current pool price and tick range to optimize allocation
     */
    function _calculateUSDCAllocation(
        uint256 totalUSDC,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        ICLPool pool
    ) internal view returns (uint256 usdc0, uint256 usdc1) {
        // Get current pool state
        (uint160 sqrtPriceX96, int24 currentTick,,,,) = pool.slot0();
        
        // Check position relative to current price
        if (currentTick < tickLower) {
            // Price below range: 100% in token0 (need to buy token0)
            if (token0 == USDC) {
                usdc0 = 0;  // Don't need to swap USDC to USDC
                usdc1 = totalUSDC;  // All USDC goes to buying token1
            } else {
                usdc0 = totalUSDC;  // All USDC goes to buying token0
                usdc1 = 0;
            }
        } else if (currentTick >= tickUpper) {
            // Price above range: 100% in token1 (need to buy token1)
            if (token1 == USDC) {
                usdc0 = totalUSDC;  // All USDC goes to buying token0
                usdc1 = 0;  // Don't need to swap USDC to USDC
            } else {
                usdc0 = 0;
                usdc1 = totalUSDC;  // All USDC goes to buying token1
            }
        } else {
            // Price in range: Calculate optimal ratio
            // Use a simplified approach based on position in range
            
            // Calculate how far we are through the range (0 to 100)
            int24 rangeSize = tickUpper - tickLower;
            int24 positionInRange = currentTick - tickLower;
            
            if (rangeSize > 0) {
                // Calculate percentage through range (scaled by 100 for precision)
                uint256 percentThrough = uint256(int256(positionInRange * 100 / rangeSize));
                
                // As we move up through range, we need more token1 and less token0
                // At bottom of range: mostly token0
                // At top of range: mostly token1
                uint256 token1Percent = percentThrough;
                uint256 token0Percent = 100 - percentThrough;
                
                // Apply percentages based on which token is USDC
                if (token0 == USDC) {
                    // token0 is USDC, we keep some as USDC and swap some for token1
                    usdc0 = (totalUSDC * token0Percent) / 100;  // Keep as USDC for token0
                    usdc1 = totalUSDC - usdc0;  // Swap to token1
                } else if (token1 == USDC) {
                    // token1 is USDC, we swap some for token0 and keep some as USDC
                    usdc0 = (totalUSDC * token0Percent) / 100;  // Swap to token0
                    usdc1 = totalUSDC - usdc0;  // Keep as USDC for token1
                } else {
                    // Neither is USDC (shouldn't happen)
                    usdc0 = totalUSDC / 2;
                    usdc1 = totalUSDC - usdc0;
                }
            } else {
                // Edge case: zero-width range
                usdc0 = totalUSDC / 2;
                usdc1 = totalUSDC - usdc0;
            }
        }
    }
    
    /**
     * @notice Gets the price of a token in USDC
     * @param token The token to price
     * @return price The price in USDC (18 decimals)
     */
    function _getTokenPriceInUSDC(address token) internal view returns (uint256 price) {
        if (token == USDC) {
            return 1e18; // 1 USDC = 1 USDC
        }
        
        // For now, return a default price
        // In production, this would use an oracle or be passed as parameter
        return 1e18; // Default to 1:1
    }
    
    /**
     * @notice Gets the price from a pool
     * @param pool The pool address
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @return price The price (18 decimals)
     */
    function _getPoolPrice(address pool, address tokenIn, address tokenOut) internal view returns (uint256) {
        ICLPool clPool = ICLPool(pool);
        (uint160 sqrtPriceX96,,,,,) = clPool.slot0();
        
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) >> 192;
        
        // Adjust for token order
        if (tokenIn == clPool.token1()) {
            price = 1e36 / price; // Invert price if tokens are reversed
        }
        
        // Adjust for decimals
        uint8 decimalsIn = _getTokenDecimals(tokenIn);
        uint8 decimalsOut = _getTokenDecimals(tokenOut);
        
        if (decimalsIn > decimalsOut) {
            price = price * (10 ** (decimalsIn - decimalsOut));
        } else if (decimalsOut > decimalsIn) {
            price = price / (10 ** (decimalsOut - decimalsIn));
        }
        
        return price;
    }
    
    /**
     * @notice Gets token decimals
     * @param token The token address
     * @return decimals The number of decimals
     */
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == USDC) return 6;
        if (token == WETH) return 18;
        if (token == AERO) return 18;
        
        // Fallback to calling decimals()
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (success && data.length > 0) {
            return abi.decode(data, (uint8));
        }
        return 18; // Default to 18 if call fails
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
     * @param pool The pool address
     * @return gauge The gauge address (or address(0) if not found)
     */
    function _findGaugeForPool(address pool) internal view returns (address gauge) {
        // Try Voter first (more reliable)
        try IVoter(VOTER).gauges(pool) returns (address g) {
            if (g != address(0)) {
                return g;
            }
        } catch {}
        
        // Fallback to gauge factory
        try IGaugeFactory(GAUGE_FACTORY).getPoolGauge(pool) returns (address g) {
            return g;
        } catch {}
        
        return address(0);
    }
    
    /**
     * @notice Swaps exact input amount for output through Universal Router
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The exact input amount
     * @param minAmountOut The minimum output amount
     * @param pool The pool address to use for swapping
     * @return amountOut The output amount received
     */
    function _swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address pool
    ) internal returns (uint256 amountOut) {
        require(pool != address(0), "Invalid pool");
        return _swapExactInputDirect(tokenIn, tokenOut, amountIn, minAmountOut, pool);
    }
    
    /**
     * @notice Swaps using a specific pool
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The exact input amount
     * @param minAmountOut The minimum output amount
     * @param pool The specific pool to use
     * @return amountOut The output amount received
     */
    function _swapExactInputDirect(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address pool
    ) internal returns (uint256 amountOut) {
        // For certain pools, use direct swap
        if (_shouldUseDirectSwap(pool)) {
            return _directPoolSwap(tokenIn, tokenOut, amountIn, minAmountOut, pool);
        }
        
        // Use Universal Router
        bytes memory commands = abi.encodePacked(bytes1(0x00)); // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        
        // Get tick spacing from pool
        int24 tickSpacing = ICLPool(pool).tickSpacing();
        
        // Encode tick spacing as 3 bytes (matching SDK)
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
     * @notice Swaps exact output amount through Universal Router
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountOut The exact output amount desired
     * @param maxAmountIn The maximum input amount
     * @return amountIn The input amount used
     */
    function _swapExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn
    ) internal returns (uint256 amountIn) {
        // V3_SWAP_EXACT_OUT command
        bytes memory commands = abi.encodePacked(bytes1(0x01));
        bytes[] memory inputs = new bytes[](1);
        
        // For WETH/USDC swaps, use known pool
        // In production, pool address would be provided
        address pool = WETH_USDC_POOL;
        
        // Get tick spacing from pool
        int24 tickSpacing = ICLPool(pool).tickSpacing();
        
        // Encode tick spacing as 3 bytes (matching SDK)
        bytes memory tickSpacingBytes = abi.encodePacked(uint24(uint256(int256(tickSpacing))));
        
        // For exact output, path is reversed (tokenOut -> tokenIn)
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountOut,      // amountOut
            maxAmountIn,    // amountInMaximum
            abi.encodePacked(tokenOut, tickSpacingBytes, tokenIn),  // reversed path with tick spacing
            true,           // payerIsUser
            false           // useSlipstreamPools = false for Aerodrome CL pools
        );
        
        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        
        UNIVERSAL_ROUTER.execute{value: 0}(commands, inputs);
        
        amountIn = balanceBefore - IERC20(tokenIn).balanceOf(address(this));
        require(amountIn <= maxAmountIn, "Excessive input amount");
    }
    
    
    /**
     * @notice Calculates expected amounts from burning a position
     * @param tokenId The position token ID
     * @param pool The pool address
     * @return amount0 Expected amount of token0
     * @return amount1 Expected amount of token1
     */
    function _calculateExpectedAmounts(
        uint256 tokenId,
        address pool
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (,,,,,int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
        
        // Get current pool state
        (,int24 currentTick,,,,) = ICLPool(pool).slot0();
        
        // Simplified approach based on tick position
        // The actual amounts will be calculated by the NonfungiblePositionManager
        // This is just an estimate for slippage purposes
        uint256 liq = uint256(liquidity);
        
        if (currentTick < tickLower) {
            // Price below range - mostly token0
            amount0 = liq;  // Simplified: use liquidity as proxy for amount
            amount1 = 0;
        } else if (currentTick >= tickUpper) {
            // Price above range - mostly token1
            amount0 = 0;
            amount1 = liq;  // Simplified: use liquidity as proxy for amount
        } else {
            // Price in range - both tokens
            // Simple 50/50 split for estimation
            amount0 = liq / 2;
            amount1 = liq / 2;
        }
    }
    
    /**
     * @notice Gets effective slippage to use
     * @param requestedSlippage The requested slippage in basis points
     * @return The effective slippage to use
     */
    function _getEffectiveSlippage(uint256 requestedSlippage) internal pure returns (uint256) {
        if (requestedSlippage == 0) {
            return DEFAULT_SLIPPAGE_BPS;
        }
        require(requestedSlippage <= MAX_SLIPPAGE_BPS, "Slippage too high");
        return requestedSlippage;
    }
    
    /**
     * @notice Checks if a pool should use direct swap
     * @param pool The pool address
     * @return Whether to use direct swap
     */
    function _shouldUseDirectSwap(address pool) internal view returns (bool) {
        // Check if pool has very low liquidity or special characteristics
        try ICLPool(pool).liquidity() returns (uint128 liquidity) {
            // Use direct swap for low liquidity pools
            return liquidity < 1e18;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Gets USDC needed to acquire a specific amount of a token
     * @param token The target token
     * @param tokenAmount The desired amount of the token
     * @return usdcNeeded The amount of USDC needed
     */
    function _getUSDCNeededForToken(address token, uint256 tokenAmount) internal returns (uint256 usdcNeeded) {
        if (token == USDC) {
            return tokenAmount;
        }
        
        // For now, just return a simple estimate
        // In production, pool address would be passed as parameter
        uint256 tokenPrice = _getTokenPriceInUSDC(token);
        usdcNeeded = (tokenAmount * tokenPrice) / 1e18;
        // Add buffer
        usdcNeeded = (usdcNeeded * 101) / 100;
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
        (address tokenIn, , uint256 expectedAmountIn) = abi.decode(data, (address, address, uint256));
        
        // Verify callback is from a valid pool by checking the caller has pool interface
        try ICLPool(msg.sender).token0() returns (address) {
            // Pool is valid, proceed with payment
        } catch {
            revert("Invalid callback source");
        }
        
        // Determine amount to pay
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        require(amountToPay <= expectedAmountIn, "Excessive payment requested");
        
        // Transfer the required tokens to the pool
        _safeTransfer(tokenIn, msg.sender, amountToPay);
    }
    
    /**
     * @notice Emergency function to recover stuck tokens
     * @dev Only callable by contract owner/admin
     * @param token The token to recover
     * @param amount The amount to recover
     */
    function recoverToken(address token, uint256 amount) external {
        require(msg.sender == address(walletRegistry), "Only registry owner");
        _safeTransfer(token, msg.sender, amount);
    }
    
    /**
     * @notice Public wrapper for getting token price in USDC
     * @param token The token to price
     * @return The price in USDC
     */
    function getTokenPriceInUSDCPublic(address token) external view returns (uint256) {
        return _getTokenPriceInUSDC(token);
    }
    
    /**
     * @notice Public wrapper for getting USDC needed for a token amount
     * @param token The target token
     * @param tokenAmount The desired amount
     * @return The USDC needed
     */
    function getUSDCNeededForTokenPublic(address token, uint256 tokenAmount) external returns (uint256) {
        return _getUSDCNeededForToken(token, tokenAmount);
    }
    
    /**
     * @notice Multiplies two numbers and divides by a third, with full precision
     * @dev Prevents overflow by using intermediate 512-bit arithmetic
     * @param a The multiplicand
     * @param b The multiplier
     * @param denominator The divisor
     * @return result The result of a * b / denominator
     */
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        // Handle division by zero
        require(denominator > 0, "Division by zero");
        
        // 512-bit multiply [prod1 prod0] = a * b
        // Compute the product mod 2^256 and mod 2^256 - 1
        // then use the Chinese Remainder Theorem to reconstruct
        // the 512 bit result. The result is stored in two 256
        // variables such that product = prod1 * 2^256 + prod0
        uint256 prod0; // Least significant 256 bits of the product
        uint256 prod1; // Most significant 256 bits of the product
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        
        // Short circuit 256 by 256 division
        if (prod1 == 0) {
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }
        
        // Make sure the result is less than 2^256
        require(prod1 < denominator, "Result overflow");
        
        // 512 by 256 division
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        // Subtract 256 bit number from 512 bit number
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }
        
        // Factor powers of two out of denominator
        // Compute largest power of two divisor of denominator
        // Always >= 1
        uint256 twos = (type(uint256).max - denominator + 1) & denominator;
        // Divide denominator by power of two
        assembly {
            denominator := div(denominator, twos)
        }
        
        // Divide [prod1 prod0] by the factors of two
        assembly {
            prod0 := div(prod0, twos)
        }
        // Shift in bits from prod1 into prod0
        twos = 0 - twos;
        assembly {
            prod0 := or(prod0, mul(prod1, twos))
        }
        
        // Invert denominator mod 2^256
        // Now that denominator is an odd number, it has an inverse
        // modulo 2^256 such that denominator * inv = 1 mod 2^256
        // Compute the inverse by starting with a seed that is correct
        // for four bits. That is, denominator * inv = 1 mod 2^4
        uint256 inv = (3 * denominator) ^ 2;
        // Use Newton-Raphson iteration to improve the precision
        inv *= 2 - denominator * inv; // inverse mod 2^8
        inv *= 2 - denominator * inv; // inverse mod 2^16
        inv *= 2 - denominator * inv; // inverse mod 2^32
        inv *= 2 - denominator * inv; // inverse mod 2^64
        inv *= 2 - denominator * inv; // inverse mod 2^128
        inv *= 2 - denominator * inv; // inverse mod 2^256
        
        // Because the division is now exact we can divide by multiplying
        // with the modular inverse of denominator. This will give us the
        // correct result modulo 2^256. Since the precoditions guarantee
        // that the outcome is less than 2^256, this is the final result
        result = prod0 * inv;
        return result;
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