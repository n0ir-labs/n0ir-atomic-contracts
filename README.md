# Aerodrome Atomic Operations Contract

A smart contract for performing atomic operations on Aerodrome Finance V3 Slipstream pools, enabling users to open and close concentrated liquidity positions in single transactions.

## Features

- **Atomic Position Opening**: Swap USDC to tokens and mint LP positions in one transaction
- **Automatic Staking**: Option to stake positions directly in gauge contracts
- **Complete Position Exit**: Unstake, claim rewards, burn positions, and swap to USDC atomically
- **Reward Harvesting**: Claim and optionally swap AERO rewards to USDC
- **Gas Optimized**: Uses Permit2 for gasless approvals and multicall patterns
- **Security Focused**: Comprehensive slippage protection and reentrancy guards

## Contract Architecture

### Core Components

1. **AtomicBase.sol**: Abstract contract with safety modifiers and validation functions
   - Reentrancy protection
   - Deadline checks
   - Slippage validation
   - Safe transfer helpers

2. **AerodromeAtomicOperations.sol**: Main contract implementing atomic operations
   - Integrates with Aerodrome's Universal Router, Position Manager, and Gauge contracts
   - Handles all swap, mint, stake, and exit operations

### Key Functions

#### Opening Positions
- `swapMintAndStake()`: Swap USDC → tokens → mint position → stake in gauge
- `swapAndMint()`: Swap USDC → tokens → mint position (no staking)

#### Closing Positions
- `fullExit()`: Unstake → claim rewards → decrease liquidity → burn → swap to USDC
- `unstakeAndBurn()`: Exit position without final swap to USDC
- `claimAndSwap()`: Harvest AERO rewards and optionally swap to USDC

## Deployment

### Prerequisites
- Foundry installed
- Base mainnet RPC URL
- Private key for deployment

### Environment Setup
```bash
cp .env.example .env
# Edit .env with your values:
# BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
# PRIVATE_KEY=your_private_key
# ETHERSCAN_API_KEY=your_etherscan_key
```

### Deploy
```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url $BASE_RPC_URL --broadcast --verify
```

## Testing

Run the test suite:
```bash
forge test --fork-url $BASE_RPC_URL
```

Run with coverage:
```bash
forge coverage --fork-url $BASE_RPC_URL
```

## Security Considerations

1. **Slippage Protection**: All operations include minimum output requirements
2. **Reentrancy Guards**: NonReentrant modifier on all external functions
3. **Input Validation**: Comprehensive checks for tick ranges, amounts, and pool validity
4. **Deadline Protection**: All operations must complete before specified deadline
5. **Access Control**: Only position owners can perform operations on their positions

## Gas Optimization

- Uses Permit2 for gasless token approvals
- Leverages Position Manager's multicall functionality
- Optimized math operations using assembly
- Efficient storage patterns

## Integration Example

```solidity
// Open a position
AerodromeAtomicOperations.SwapMintParams memory params = AerodromeAtomicOperations.SwapMintParams({
    token0: USDC < WETH ? USDC : WETH,
    token1: USDC > WETH ? USDC : WETH,
    tickSpacing: 100,
    tickLower: -887200,
    tickUpper: 887200,
    usdcAmount: 1000e6,
    minLiquidity: 1000,
    deadline: block.timestamp + 300,
    stake: true
});

(uint256 tokenId, uint128 liquidity) = atomic.swapMintAndStake(params);
```

## Audits

This contract has not been audited. Use at your own risk.

## License

MIT