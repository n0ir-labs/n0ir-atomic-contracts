// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IVoter {
    function gauges(address pool) external view returns (address gauge);
    function isGauge(address gauge) external view returns (bool);
    function isAlive(address gauge) external view returns (bool);
}