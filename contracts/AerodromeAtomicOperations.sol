// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./AtomicBase.sol";
import "@interfaces/IUniversalRouter.sol";
import "@interfaces/IPermit2.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IGauge.sol";
import "@interfaces/ICLFactory.sol";
import "@interfaces/ICLPool.sol";
import "@interfaces/IMixedQuoter.sol";
import "@interfaces/IERC20.sol";

contract AerodromeAtomicOperations is AtomicBase {
    IUniversalRouter public constant UNIVERSAL_ROUTER = IUniversalRouter(0x01D40099fCD87C018969B0e8D4aB1633Fb34763C);
    IPermit2 public constant PERMIT2 = IPermit2(0x494bbD8a3302AcA833D307D11838F18DbAdA9C25);
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    IMixedQuoter public constant QUOTER = IMixedQuoter(0x254cF9E1E6e233aa1AC962CB9B05b2cfeAaE15b0);
    ICLFactory public constant CL_FACTORY = ICLFactory(0x31832f2a97Fd20664D76Cc421207669b55CE4BC0);
    
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    
    uint256 private constant SQRT_PRICE_LIMIT_X96 = 0;
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 100; // 1%
    
    event PositionOpened(
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
    
    event RewardsClaimed(
        address indexed user,
        uint256 indexed tokenId,
        uint256 aeroAmount,
        uint256 usdcReceived
    );
    
    event EmergencyWithdraw(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    
    struct SwapMintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 usdcAmount;
        uint256 minLiquidity;
        uint256 deadline;
        bool stake;
    }
    
    struct ExitParams {
        uint256 tokenId;
        uint256 minUsdcOut;
        uint256 deadline;
        bool swapToUsdc;
    }
    
    function swapMintAndStake(SwapMintParams calldata params) 
        external 
        nonReentrant 
        deadlineCheck(params.deadline)
        validAmount(params.usdcAmount)
        returns (uint256 tokenId, uint128 liquidity)
    {
        _safeTransferFrom(USDC, msg.sender, address(this), params.usdcAmount);
        
        _validateTickRange(params.tickLower, params.tickUpper, params.tickSpacing);
        
        address pool = CL_FACTORY.getPool(params.token0, params.token1, params.tickSpacing);
        _validatePool(pool, address(CL_FACTORY));
        
        (uint256 amount0Desired, uint256 amount1Desired) = _calculateOptimalAmounts(
            params.token0,
            params.token1,
            params.usdcAmount,
            params.tickLower,
            params.tickUpper,
            pool
        );
        
        _performSwapsForLiquidity(
            params.token0,
            params.token1,
            amount0Desired,
            amount1Desired
        );
        
        _safeApprove(params.token0, address(POSITION_MANAGER), amount0Desired);
        _safeApprove(params.token1, address(POSITION_MANAGER), amount1Desired);
        
        (tokenId, liquidity,,) = POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: params.token0,
                token1: params.token1,
                tickSpacing: params.tickSpacing,
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
            address gauge = CL_FACTORY.gauge(pool);
            require(gauge != address(0), "No gauge found for pool");
            
            POSITION_MANAGER.approve(gauge, tokenId);
            IGauge(gauge).stake(tokenId);
        }
        
        emit PositionOpened(msg.sender, tokenId, pool, params.usdcAmount, liquidity, params.stake);
    }
    
    function swapAndMint(SwapMintParams calldata params) 
        external 
        nonReentrant 
        deadlineCheck(params.deadline)
        validAmount(params.usdcAmount)
        returns (uint256 tokenId, uint128 liquidity)
    {
        params.stake = false;
        return swapMintAndStake(params);
    }
    
    function fullExit(ExitParams calldata params)
        external
        nonReentrant
        deadlineCheck(params.deadline)
        returns (uint256 usdcOut, uint256 aeroRewards)
    {
        (,, address token0, address token1,,,, uint128 liquidity,,,,) = POSITION_MANAGER.positions(params.tokenId);
        require(liquidity > 0, "Position has no liquidity");
        
        address pool = CL_FACTORY.getPool(token0, token1, 0);
        address gauge = CL_FACTORY.gauge(pool);
        
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
    
    function claimAndSwap(uint256 tokenId, uint256 minUsdcOut, uint256 deadline)
        external
        nonReentrant
        deadlineCheck(deadline)
        returns (uint256 aeroAmount, uint256 usdcReceived)
    {
        (,, address token0, address token1,,,,,,,) = POSITION_MANAGER.positions(tokenId);
        
        address pool = CL_FACTORY.getPool(token0, token1, 0);
        address gauge = CL_FACTORY.gauge(pool);
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
    
    function unstakeAndBurn(uint256 tokenId, uint256 deadline)
        external
        nonReentrant
        deadlineCheck(deadline)
        returns (uint256 amount0, uint256 amount1, uint256 aeroRewards)
    {
        ExitParams memory params = ExitParams({
            tokenId: tokenId,
            minUsdcOut: 0,
            deadline: deadline,
            swapToUsdc: false
        });
        
        (uint256 usdcOut, uint256 rewards) = fullExit(params);
        return (amount0, amount1, rewards);
    }
    
    function _calculateOptimalAmounts(
        address token0,
        address token1,
        uint256 usdcAmount,
        int24 tickLower,
        int24 tickUpper,
        address pool
    ) internal view returns (uint256 amount0, uint256 amount1) {
        ICLPool clPool = ICLPool(pool);
        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = clPool.slot0();
        
        uint256 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
        uint256 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);
        
        uint256 liquidity = _getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            usdcAmount / 2,
            usdcAmount / 2
        );
        
        (amount0, amount1) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            uint128(liquidity)
        );
    }
    
    function _performSwapsForLiquidity(
        address token0,
        address token1,
        uint256 amount0Needed,
        uint256 amount1Needed
    ) internal {
        if (token0 != USDC && amount0Needed > 0) {
            _swapExactOutput(USDC, token0, amount0Needed, IERC20(USDC).balanceOf(address(this)));
        }
        
        if (token1 != USDC && amount1Needed > 0) {
            _swapExactOutput(USDC, token1, amount1Needed, IERC20(USDC).balanceOf(address(this)));
        }
    }
    
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
    
    function _swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), amountIn);
        
        bytes memory commands = abi.encodePacked(bytes1(0x00));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(this),
            amountIn,
            minAmountOut,
            _encodePath(tokenIn, tokenOut),
            true
        );
        
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
    }
    
    function _swapExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn
    ) internal returns (uint256 amountIn) {
        _safeApprove(tokenIn, address(UNIVERSAL_ROUTER), maxAmountIn);
        
        bytes memory commands = abi.encodePacked(bytes1(0x01));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(this),
            amountOut,
            maxAmountIn,
            _encodePath(tokenOut, tokenIn),
            true
        );
        
        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp);
        amountIn = balanceBefore - IERC20(tokenIn).balanceOf(address(this));
    }
    
    function _encodePath(address tokenA, address tokenB) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenA, uint24(3000), tokenB);
    }
    
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
    
    function emergencyWithdraw(address token) external {
        require(msg.sender == address(this), "Only contract can call");
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            _safeTransfer(token, msg.sender, balance);
            emit EmergencyWithdraw(msg.sender, token, balance);
        }
    }
}