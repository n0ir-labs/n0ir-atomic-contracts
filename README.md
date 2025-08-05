# Aerodrome Atomic Operations

Smart contracts for atomic operations on Aerodrome Finance concentrated liquidity pools.

## Overview

This repository contains optimized smart contracts for performing atomic operations on Aerodrome CL pools, including:
- Swapping USDC for pool tokens and minting concentrated liquidity positions
- Staking positions in gauges for AERO rewards
- Exiting positions and converting back to USDC
- Oracle-based price discovery for accurate position calculations

## Key Features

### 🔮 Oracle Integration
- Uses 1inch Offchain Oracle (0x288a124CB87D7c95656Ad7512B7Da733Bb60A432) for accurate USD price discovery
- Calculates optimal token ratios based on real market prices
- Works with any token pair, not limited to USDC pairs

### ⚡ Atomic Operations
- Single-transaction position entry (swap + mint + stake)
- Single-transaction position exit (unstake + burn + swap)
- Minimizes MEV exposure and gas costs

### 📊 Optimized Liquidity Calculations
- Uses Aerodrome's SugarHelper for precise liquidity math
- Calculates optimal token amounts for in-range positions
- Handles out-of-range positions correctly

## Contracts

### AerodromeAtomicOperations.sol
Main contract providing atomic operations for Aerodrome CL positions.

**Key Functions:**
- `swapMintAndStake`: Swap USDC to tokens, mint position, and optionally stake
- `fullExit`: Exit position completely and convert to USDC
- `calculateOptimalUSDCAllocation`: Calculate optimal token amounts using oracle prices

### AtomicBase.sol
Base contract with common functionality for atomic operations.

### CDPWalletRegistry.sol
Optional registry for CDP wallet access control.

## Testing

Run tests with Forge:
```bash
forge test --fork-url https://base.llamarpc.com -vv
```

## Gas Costs

Typical gas usage on Base network:
- Swap + Mint + Stake: ~1.3M gas ($0.05-0.25 at typical Base prices)
- Full Exit: ~1.6M gas ($0.06-0.30 at typical Base prices)

## Dependencies

- Aerodrome Finance contracts
- 1inch Offchain Oracle
- OpenZeppelin contracts
- Forge/Foundry for development

## License

MIT