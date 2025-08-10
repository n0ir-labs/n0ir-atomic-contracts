// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LiquidityManager} from "../contracts/LiquidityManager.sol";

contract OraclePriceTest is Test {
    LiquidityManager public liquidityManager;
    
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant cbBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant UNKNOWN_TOKEN = 0xc0634090F2Fe6c6d75e61Be2b949464aBB498973;
    
    function setUp() public {
        // Deploy LiquidityManager without wallet registry and route finder for testing
        liquidityManager = new LiquidityManager(address(0), address(0));
    }
    
    function testGetTokenPriceViaOracle() public view {
        // Test USDC price (should always be 1e6)
        uint256 usdcPrice = liquidityManager.getTokenPriceViaOracle(USDC);
        assertEq(usdcPrice, 1e6, "USDC price should be 1e6");
        console2.log("USDC price:", usdcPrice);
        
        // Test WETH price (should be around 3000-4000 USDC)
        uint256 wethPrice = liquidityManager.getTokenPriceViaOracle(WETH);
        console2.log("WETH price in USDC:", wethPrice);
        assertGt(wethPrice, 2000e6, "WETH price should be > 2000 USDC");
        assertLt(wethPrice, 5000e6, "WETH price should be < 5000 USDC");
        
        // Test AERO price (should be around 1-3 USDC)
        uint256 aeroPrice = liquidityManager.getTokenPriceViaOracle(AERO);
        console2.log("AERO price in USDC:", aeroPrice);
        assertGt(aeroPrice, 0.5e6, "AERO price should be > 0.5 USDC");
        assertLt(aeroPrice, 10e6, "AERO price should be < 10 USDC");
        
        // Test cbBTC price (should be around 90000-110000 USDC)
        uint256 btcPrice = liquidityManager.getTokenPriceViaOracle(cbBTC);
        console2.log("cbBTC price in USDC:", btcPrice);
        assertGt(btcPrice, 50000e6, "cbBTC price should be > 50000 USDC");
        assertLt(btcPrice, 150000e6, "cbBTC price should be < 150000 USDC");
    }
    
    function testSpecificTokenPrice() public view {
        // Test the specific token 0xc0634090F2Fe6c6d75e61Be2b949464aBB498973
        uint256 tokenPrice = liquidityManager.getTokenPriceViaOracle(UNKNOWN_TOKEN);
        console2.log("Token 0xc0634090F2Fe6c6d75e61Be2b949464aBB498973 price in USDC:", tokenPrice);
        
        // Just log the price, don't assert since we don't know expected range
        assertGt(tokenPrice, 0, "Token price should be greater than 0");
    }
}