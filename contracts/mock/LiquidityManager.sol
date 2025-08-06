// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./WalletRegistry.sol";
import "@interfaces/IUniversalRouter.sol";
import "@interfaces/INonfungiblePositionManager.sol";
import "@interfaces/IGauge.sol";
import "@interfaces/ICLPool.sol";
import "@interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LiquidityManager
 * @notice Automated liquidity management protocol
 * @dev Handles liquidity operations on decentralized exchanges
 */
contract LiquidityManager is ReentrancyGuard, IERC721Receiver {
    WalletRegistry public immutable walletRegistry;
    
    IUniversalRouter public constant UNIVERSAL_ROUTER = IUniversalRouter(0x01D40099fCD87C018969B0e8D4aB1633Fb34763C);
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0xF67721f255bF1A821A2e5cC7fE504428CbEFe957);
    address public constant GAUGE_FACTORY = 0x6cCC30De5E7290c8b7B97b5a9a7Ca3a0c3437F5E;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    
    uint256 private constant SLIPPAGE_BASE = 10000;
    uint256 private constant DEFAULT_SLIPPAGE = 100;
    
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
    
    event PositionCreated(uint256 indexed tokenId, address indexed pool, uint128 liquidity);
    event PositionClosed(uint256 indexed tokenId, uint256 usdcOut, uint256 rewards);
    
    constructor(address _walletRegistry) {
        walletRegistry = WalletRegistry(_walletRegistry);
    }
    
    modifier onlyAuthorized() {
        require(walletRegistry.isWallet(msg.sender), "Unauthorized");
        _;
    }
    
    modifier deadlineCheck(uint256 deadline) {
        require(block.timestamp <= deadline, "Expired");
        _;
    }
    
    function createPosition(PositionParams calldata params)
        external
        nonReentrant
        deadlineCheck(params.deadline)
        onlyAuthorized
        returns (uint256 tokenId, uint128 liquidity)
    {
        require(params.usdcAmount > 0, "Invalid amount");
        
        ICLPool pool = ICLPool(params.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        IERC20(USDC).transferFrom(msg.sender, address(this), params.usdcAmount);
        
        uint256 halfAmount = params.usdcAmount / 2;
        
        uint256 amount0 = _swapFromUSDC(token0, halfAmount, params.slippageBps);
        uint256 amount1 = _swapFromUSDC(token1, halfAmount, params.slippageBps);
        
        (tokenId, liquidity) = _mintPosition(
            token0,
            token1,
            pool.tickSpacing(),
            params.tickLower,
            params.tickUpper,
            amount0,
            amount1,
            params.slippageBps
        );
        
        if (params.stake) {
            address gauge = _getGaugeAddress(params.pool);
            if (gauge != address(0)) {
                POSITION_MANAGER.safeTransferFrom(address(this), gauge, tokenId);
            }
        } else {
            POSITION_MANAGER.safeTransferFrom(address(this), msg.sender, tokenId);
        }
        
        _returnExcessTokens(token0, token1);
        
        emit PositionCreated(tokenId, params.pool, liquidity);
    }
    
    function closePosition(ExitParams calldata params)
        external
        nonReentrant
        deadlineCheck(params.deadline)
        onlyAuthorized
        returns (uint256 usdcOut, uint256 rewards)
    {
        (,, address token0, address token1, ,, , uint128 liquidity,,,,) = POSITION_MANAGER.positions(params.tokenId);
        require(liquidity > 0, "No liquidity");
        
        address gauge = _getGaugeAddress(params.pool);
        
        if (gauge != address(0)) {
            rewards = IGauge(gauge).earned(params.tokenId);
            if (rewards > 0) {
                IGauge(gauge).getReward(params.tokenId);
            }
            IGauge(gauge).withdraw(params.tokenId);
        } else {
            POSITION_MANAGER.safeTransferFrom(msg.sender, address(this), params.tokenId);
        }
        
        (uint256 amount0, uint256 amount1) = _burnPosition(params.tokenId, liquidity);
        
        uint256 usdc0 = _swapToUSDC(token0, amount0, params.slippageBps);
        uint256 usdc1 = _swapToUSDC(token1, amount1, params.slippageBps);
        
        usdcOut = usdc0 + usdc1;
        
        if (params.minUsdcOut > 0) {
            require(usdcOut >= params.minUsdcOut, "Slippage");
        }
        
        IERC20(USDC).transfer(msg.sender, usdcOut);
        
        if (rewards > 0) {
            IERC20(AERO).transfer(msg.sender, rewards);
        }
        
        emit PositionClosed(params.tokenId, usdcOut, rewards);
    }
    
    function _swapFromUSDC(
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps
    ) private returns (uint256) {
        if (tokenOut == USDC) {
            return amountIn;
        }
        
        return _executeSwap(USDC, tokenOut, amountIn, slippageBps);
    }
    
    function _swapToUSDC(
        address tokenIn,
        uint256 amountIn,
        uint256 slippageBps
    ) private returns (uint256) {
        if (tokenIn == USDC || amountIn == 0) {
            return amountIn;
        }
        
        return _executeSwap(tokenIn, USDC, amountIn, slippageBps);
    }
    
    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps
    ) private returns (uint256 amountOut) {
        _ensureApproval(tokenIn, address(UNIVERSAL_ROUTER), amountIn);
        
        bytes memory path = abi.encodePacked(tokenIn, uint24(500), int24(10), tokenOut);
        uint256 minAmountOut = _calculateMinAmount(amountIn, slippageBps);
        
        bytes memory commands = abi.encodePacked(bytes1(0x01));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(this), amountIn, minAmountOut, path, false);
        
        UNIVERSAL_ROUTER.execute(commands, inputs);
        
        amountOut = IERC20(tokenOut).balanceOf(address(this));
    }
    
    function _mintPosition(
        address token0,
        address token1,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        uint256 slippageBps
    ) private returns (uint256 tokenId, uint128 liquidity) {
        _ensureApproval(token0, address(POSITION_MANAGER), amount0);
        _ensureApproval(token1, address(POSITION_MANAGER), amount1);
        
        uint256 amount0Min = _calculateMinAmount(amount0, slippageBps);
        uint256 amount1Min = _calculateMinAmount(amount1, slippageBps);
        
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });
        
        (tokenId, liquidity,,) = POSITION_MANAGER.mint(mintParams);
    }
    
    function _burnPosition(
        uint256 tokenId,
        uint128 liquidity
    ) private returns (uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        
        (amount0, amount1) = POSITION_MANAGER.decreaseLiquidity(params);
        
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        
        POSITION_MANAGER.collect(collectParams);
        POSITION_MANAGER.burn(tokenId);
    }
    
    function _getGaugeAddress(address pool) private view returns (address) {
        (bool success, bytes memory data) = GAUGE_FACTORY.staticcall(
            abi.encodeWithSignature("gauges(address)", pool)
        );
        
        if (success && data.length == 32) {
            address gauge = abi.decode(data, (address));
            if (gauge != address(0)) {
                return gauge;
            }
        }
        
        return address(0);
    }
    
    function _calculateMinAmount(uint256 amount, uint256 slippageBps) private pure returns (uint256) {
        uint256 slippage = slippageBps > 0 ? slippageBps : DEFAULT_SLIPPAGE;
        return (amount * (SLIPPAGE_BASE - slippage)) / SLIPPAGE_BASE;
    }
    
    function _returnExcessTokens(address token0, address token1) private {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        
        if (balance0 > 0) {
            IERC20(token0).transfer(msg.sender, balance0);
        }
        if (balance1 > 0) {
            IERC20(token1).transfer(msg.sender, balance1);
        }
    }
    
    function _ensureApproval(address token, address spender, uint256 amount) private {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance < amount) {
            IERC20(token).approve(spender, type(uint256).max);
        }
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
        require(msg.sender == walletRegistry.owner(), "Unauthorized");
        IERC20(token).transfer(msg.sender, amount);
    }
}