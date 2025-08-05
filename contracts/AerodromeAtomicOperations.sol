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
        
        // Get position details
        (,, address token0, address token1, int24 tickSpacing,, ,,,,,) = POSITION_MANAGER.positions(tokenId);
        
        address pool = _derivePoolAddress(token0, token1, tickSpacing);
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
        // Get position details
        (,, address token0, address token1, int24 tickSpacing,, ,,,,,) = POSITION_MANAGER.positions(tokenId);
        
        address pool = _derivePoolAddress(token0, token1, tickSpacing);
        address gauge = _findGaugeForPool(pool);
        require(gauge != address(0), "No gauge found for pool");
        
        // Verify ownership through gauge
        require(IGauge(gauge).stakedContains(msg.sender, tokenId), "Not staked by user");
        
        // Withdraw from gauge and return to user
        IGauge(gauge).withdraw(tokenId);
        POSITION_MANAGER.safeTransferFrom(address(this), msg.sender, tokenId);
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
            amount0 = usdc0;
            if (usdc1 > 0) {
                _safeApprove(USDC, address(UNIVERSAL_ROUTER), usdc1);
                amount1 = _swapExactInputDirect(USDC, token1, usdc1, 0, params.pool);
            }
        } else if (token1 == USDC) {
            amount1 = usdc1;
            if (usdc0 > 0) {
                _safeApprove(USDC, address(UNIVERSAL_ROUTER), usdc0);
                amount0 = _swapExactInputDirect(USDC, token0, usdc0, 0, params.pool);
            }
        } else {
            if (usdc0 > 0) {
                _safeApprove(USDC, address(UNIVERSAL_ROUTER), usdc0);
                amount0 = _swapExactInputDirect(USDC, token0, usdc0, 0, params.pool);
            }
            if (usdc1 > 0) {
                _safeApprove(USDC, address(UNIVERSAL_ROUTER), usdc1);
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
                deadline: params.deadline
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
        
        (,, address token0, address token1, int24 tickSpacing,, , uint128 liquidity,,,,) = POSITION_MANAGER.positions(params.tokenId);
        require(liquidity > 0, "Position has no liquidity");
        
        address pool = _derivePoolAddress(token0, token1, tickSpacing);
        
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
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        // Get current pool price
        (uint160 sqrtPriceX96,,,,,,) = ICLPool(pool).slot0();
        
        uint256 amount0Min;
        uint256 amount1Min;
        
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // All in token0
            amount0Min = (expectedAmount0 * (10000 - effectiveSlippage)) / 10000;
            amount1Min = 0;
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // All in token1
            amount0Min = 0;
            amount1Min = (expectedAmount1 * (10000 - effectiveSlippage)) / 10000;
        } else {
            // Mixed position
            amount0Min = (expectedAmount0 * (10000 - effectiveSlippage * 2)) / 10000;
            amount1Min = (expectedAmount1 * (10000 - effectiveSlippage * 2)) / 10000;
        }
        
        // Burn position
        (uint256 amount0, uint256 amount1) = POSITION_MANAGER.burn(
            INonfungiblePositionManager.BurnParams({
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
                _safeApprove(token1, address(UNIVERSAL_ROUTER), amount1);
                usdcOut += _swapExactInputDirect(token1, USDC, amount1, 0, pool);
            }
        } else if (token1 == USDC) {
            usdcOut = amount1;
            if (amount0 > 0) {
                _safeApprove(token0, address(UNIVERSAL_ROUTER), amount0);
                usdcOut += _swapExactInputDirect(token0, USDC, amount0, 0, pool);
            }
        } else {
            if (amount0 > 0) {
                _safeApprove(token0, address(UNIVERSAL_ROUTER), amount0);
                usdcOut += _swapExactInputDirect(token0, USDC, amount0, 0, pool);
            }
            if (amount1 > 0) {
                _safeApprove(token1, address(UNIVERSAL_ROUTER), amount1);
                usdcOut += _swapExactInputDirect(token1, USDC, amount1, 0, pool);
            }
        }
        
        // Swap AERO rewards to USDC if any
        if (aeroRewards > 0) {
            _safeApprove(AERO, address(UNIVERSAL_ROUTER), aeroRewards);
            // Find best pool for AERO/USDC swap
            address aeroUsdcPool = _findBestPool(AERO, USDC);
            if (aeroUsdcPool != address(0)) {
                usdcOut += _swapExactInputDirect(AERO, USDC, aeroRewards, 0, aeroUsdcPool);
            }
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
        (,, address token0, address token1, int24 tickSpacing,, ,,,,,) = POSITION_MANAGER.positions(tokenId);
        
        address pool = _derivePoolAddress(token0, token1, tickSpacing);
        
        // Try Voter first, then gauge factory
        address gauge = _findGaugeForPool(pool);
        require(gauge != address(0), "No gauge found for pool");
        
        uint256 aeroBefore = IERC20(AERO).balanceOf(address(this));
        
        IGauge(gauge).collectReward(tokenId);
        
        aeroAmount = IERC20(AERO).balanceOf(address(this)) - aeroBefore;
        
        if (minUsdcOut > 0) {
            _safeApprove(AERO, address(UNIVERSAL_ROUTER), aeroAmount);
            address aeroUsdcPool = _findBestPool(AERO, USDC);
            require(aeroUsdcPool != address(0), "No AERO/USDC pool found");
            usdcReceived = _swapExactInputDirect(AERO, USDC, aeroAmount, minUsdcOut, aeroUsdcPool);
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
        (,, address token0, address token1, int24 tickSpacing,, , uint128 liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
        require(liquidity > 0, "Position has no liquidity");
        
        address pool = _derivePoolAddress(token0, token1, tickSpacing);
        
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
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        // Get current pool price
        (uint160 sqrtPriceX96,,,,,,) = ICLPool(pool).slot0();
        
        uint256 amount0Min;
        uint256 amount1Min;
        
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // All in token0
            amount0Min = (expectedAmount0 * (10000 - effectiveSlippage)) / 10000;
            amount1Min = 0;
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // All in token1  
            amount0Min = 0;
            amount1Min = (expectedAmount1 * (10000 - effectiveSlippage)) / 10000;
        } else {
            // Mixed position
            amount0Min = (expectedAmount0 * (10000 - effectiveSlippage * 2)) / 10000;
            amount1Min = (expectedAmount1 * (10000 - effectiveSlippage * 2)) / 10000;
        }
        
        // Burn position
        POSITION_MANAGER.burn(
            INonfungiblePositionManager.BurnParams({
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
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        
        // Calculate sqrt prices at tick boundaries
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        // Determine allocation based on current price relative to range
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Current price is below range - all in token0
            usdc0 = totalUSDC;
            usdc1 = 0;
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // Current price is above range - all in token1
            usdc0 = 0;
            usdc1 = totalUSDC;
        } else {
            // Current price is within range - calculate optimal ratio
            uint256 liquidity0 = uint256(sqrtRatioBX96 - sqrtPriceX96) << 96 / (sqrtPriceX96 * sqrtRatioBX96 >> 96);
            uint256 liquidity1 = uint256(sqrtPriceX96 - sqrtRatioAX96);
            
            // Get token prices in USDC
            uint256 token0PriceInUSDC = _getTokenPriceInUSDC(token0);
            uint256 token1PriceInUSDC = _getTokenPriceInUSDC(token1);
            
            // Calculate USDC value of each liquidity component
            uint256 value0 = liquidity0 * token0PriceInUSDC / 1e18;
            uint256 value1 = liquidity1 * token1PriceInUSDC / 1e18;
            
            // Allocate USDC proportionally
            uint256 totalValue = value0 + value1;
            if (totalValue > 0) {
                usdc0 = (totalUSDC * value0) / totalValue;
                usdc1 = totalUSDC - usdc0;
            } else {
                // Fallback to 50/50 if calculation fails
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
        
        // Find best pool for pricing
        address pool = _findBestPool(token, USDC);
        if (pool == address(0)) {
            // Try through WETH if direct pool doesn't exist
            address tokenWethPool = _findBestPool(token, WETH);
            address wethUsdcPool = _findBestPool(WETH, USDC);
            
            if (tokenWethPool != address(0) && wethUsdcPool != address(0)) {
                uint256 tokenPriceInWeth = _getPoolPrice(tokenWethPool, token, WETH);
                uint256 wethPriceInUsdc = _getPoolPrice(wethUsdcPool, WETH, USDC);
                return (tokenPriceInWeth * wethPriceInUsdc) / 1e18;
            }
            return 1e18; // Default to 1:1 if no pricing available
        }
        
        return _getPoolPrice(pool, token, USDC);
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
        (uint160 sqrtPriceX96,,,,,,) = clPool.slot0();
        
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
        try IGaugeFactory(GAUGE_FACTORY).getGauge(pool) returns (address g) {
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
     * @param tickSpacing The tick spacing for the pool
     * @return amountOut The output amount received
     */
    function _swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        int24 tickSpacing
    ) internal returns (uint256 amountOut) {
        // Find the pool for this pair
        address pool = _findPoolWithTickSpacing(tokenIn, tokenOut, tickSpacing);
        require(pool != address(0), "Pool not found");
        
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
        
        uint24 fee = ICLPool(pool).fee();
        
        inputs[0] = abi.encode(
            address(this),  // recipient
            amountIn,       // amountIn
            minAmountOut,   // amountOutMinimum
            abi.encodePacked(tokenIn, fee, tokenOut), // path with fee
            true,           // payerIsUser
            true            // useSlipstreamPools
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
        
        // Find best pool for swap
        address pool = _findBestPool(tokenIn, tokenOut);
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
        
        UNIVERSAL_ROUTER.execute{value: 0}(commands, inputs);
        
        amountIn = balanceBefore - IERC20(tokenIn).balanceOf(address(this));
        require(amountIn <= maxAmountIn, "Excessive input amount");
    }
    
    /**
     * @notice Finds a pool with specific tick spacing
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param tickSpacing The desired tick spacing
     * @return pool The pool address (or address(0) if not found)
     */
    function _findPoolWithTickSpacing(address tokenA, address tokenB, int24 tickSpacing) internal view returns (address) {
        // We need to check if a pool exists by trying to interact with it
        // This is a simplified approach - in production, you'd want to use a registry or factory
        address potentialPool = _derivePoolAddress(tokenA, tokenB, tickSpacing);
        
        // Verify it's a valid pool by checking if it has the expected interface
        if (potentialPool.code.length > 0) {
            try ICLPool(potentialPool).token0() returns (address) {
                return potentialPool;
            } catch {}
        }
        
        return address(0);
    }
    
    /**
     * @notice Derives pool address from tokens and tick spacing
     * @dev This is a placeholder - actual implementation would use CREATE2 prediction or registry lookup
     * @param token0 First token (sorted)
     * @param token1 Second token (sorted)
     * @param tickSpacing The tick spacing
     * @return The likely pool address
     */
    function _derivePoolAddress(address token0, address token1, int24 tickSpacing) internal pure returns (address) {
        // In production, this would calculate the CREATE2 address or look up in a registry
        // For now, we return a deterministic address based on inputs
        return address(uint160(uint256(keccak256(abi.encodePacked(token0, token1, tickSpacing)))));
    }
    
    /**
     * @notice Calculates sqrt(1.0001^tick) * 2^96
     * @dev See Uniswap V3 whitepaper for math details
     */
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
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
        
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
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
        (uint160 sqrtPriceX96,,,,,,) = ICLPool(pool).slot0();
        
        // Calculate sqrt prices at tick boundaries
        uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Current price is below range
            amount0 = uint256(liquidity) << 96 / sqrtRatioBX96 - uint256(liquidity) << 96 / sqrtRatioAX96;
            amount1 = 0;
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // Current price is above range
            amount0 = 0;
            amount1 = uint256(liquidity) * (sqrtRatioBX96 - sqrtRatioAX96) >> 96;
        } else {
            // Current price is within range
            amount0 = uint256(liquidity) << 96 / sqrtPriceX96 - uint256(liquidity) << 96 / sqrtRatioBX96;
            amount1 = uint256(liquidity) * (sqrtPriceX96 - sqrtRatioAX96) >> 96;
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
     * @notice Finds the best pool for a token pair
     * @dev Checks multiple tick spacings and returns pool with highest liquidity
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return bestPool The best pool address (or address(0) if none found)
     */
    function _findBestPool(address tokenA, address tokenB) internal view returns (address bestPool) {
        // Common tick spacings on Aerodrome
        int24[6] memory tickSpacings = [int24(1), int24(10), int24(50), int24(100), int24(200), int24(2000)];
        uint128 highestLiquidity = 0;
        
        for (uint256 i = 0; i < tickSpacings.length; i++) {
            address candidatePool = _findPoolWithTickSpacing(tokenA, tokenB, tickSpacings[i]);
            if (candidatePool != address(0)) {
                try ICLPool(candidatePool).liquidity() returns (uint128 liquidity) {
                    if (liquidity > highestLiquidity) {
                        highestLiquidity = liquidity;
                        bestPool = candidatePool;
                    }
                } catch {}
            }
        }
        
        return bestPool;
    }
    
    /**
     * @notice Gets USDC needed to acquire a specific amount of a token
     * @param token The target token
     * @param tokenAmount The desired amount of the token
     * @return usdcNeeded The amount of USDC needed
     */
    function _getUSDCNeededForToken(address token, uint256 tokenAmount) internal view returns (uint256 usdcNeeded) {
        if (token == USDC) {
            return tokenAmount;
        }
        
        // Find best pool for pricing
        address pool = _findBestPool(USDC, token);
        require(pool != address(0), "No USDC pool for token");
        
        // Quote the swap
        try QUOTER.quoteExactOutputSingle(
            IMixedQuoter.QuoteExactOutputSingleParams({
                tokenIn: USDC,
                tokenOut: token,
                amountOut: tokenAmount,
                tickSpacing: ICLPool(pool).tickSpacing(),
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountIn, uint160, uint32, uint256) {
            // Add 1% buffer for slippage
            usdcNeeded = (amountIn * 101) / 100;
        } catch {
            // Fallback calculation using price
            uint256 tokenPrice = _getTokenPriceInUSDC(token);
            usdcNeeded = (tokenAmount * tokenPrice) / 1e18;
            // Add buffer
            usdcNeeded = (usdcNeeded * 101) / 100;
        }
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
    function getUSDCNeededForTokenPublic(address token, uint256 tokenAmount) external view returns (uint256) {
        return _getUSDCNeededForToken(token, tokenAmount);
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