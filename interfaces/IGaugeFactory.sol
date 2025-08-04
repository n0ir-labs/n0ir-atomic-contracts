// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IGaugeFactory {
    function createGauge(
        address poolFactory,
        address pool
    ) external returns (address gauge);
    
    function gauges(address pool) external view returns (address gauge);
    
    function isGauge(address gauge) external view returns (bool);
    
    function isGaugeFactory(address gaugeFactory) external view returns (bool);
    
    function poolGauges(address pool) external view returns (address[] memory);
    
    function getPoolGauge(address pool) external view returns (address);
}