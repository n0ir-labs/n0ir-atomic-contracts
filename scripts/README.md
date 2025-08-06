# n0ir Protocol Deployment Scripts

This directory contains deployment scripts for the n0ir Protocol smart contracts.

## Available Scripts

### 1. Deploy.s.sol
Basic deployment script for n0ir Protocol and CDPWalletRegistry.

**Usage:**
```bash
forge script scripts/Deploy.s.sol:Deploy \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify
```

### 2. DeployWithVerification.s.sol
Enhanced deployment script with automatic contract verification and advanced configuration options.

**Usage:**
```bash
forge script scripts/DeployWithVerification.s.sol:DeployWithVerification \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY
```

## Environment Configuration

Before deploying, create a `.env` file in the project root:

```bash
cp .env.example .env
```

Then edit `.env` with your configuration:

### Required Variables
- `PRIVATE_KEY`: Deployer's private key (without 0x prefix)
- `BASE_RPC_URL`: Base network RPC endpoint

### Optional Variables
- `OWNER_ADDRESS`: Contract owner (defaults to deployer)
- `CDP_WALLETS`: Comma-separated list of initial CDP wallets to register
- `BASESCAN_API_KEY`: API key for contract verification on Basescan
- `SKIP_VERIFICATION`: Set to `true` to skip contract verification
- `VERIFIER_URL`: Custom verification API URL (defaults to Basescan)

## Deployment Process

### 1. Test Deployment (Dry Run)
First, test the deployment without broadcasting:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $BASE_RPC_URL
```

### 2. Deploy to Testnet
Deploy to Base Sepolia testnet:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://sepolia.base.org \
  --broadcast
```

### 3. Deploy to Mainnet
Deploy to Base mainnet with verification:

```bash
forge script script/DeployWithVerification.s.sol:DeployWithVerification \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  --slow
```

## Post-Deployment

### 1. Verify Contracts
If verification wasn't done during deployment:

```bash
# Verify CDPWalletRegistry
forge verify-contract \
  --chain-id 8453 \
  --constructor-args $(cast abi-encode "constructor(address)" "$OWNER_ADDRESS") \
  $REGISTRY_ADDRESS \
  contracts/CDPWalletRegistry.sol:CDPWalletRegistry

# Verify n0ir Protocol
forge verify-contract \
  --chain-id 8453 \
  --constructor-args $(cast abi-encode "constructor(address)" "$REGISTRY_ADDRESS") \
  $N0IR_ADDRESS \
  contracts/N0irProtocol.sol:N0irProtocol
```

### 2. Register CDP Wallets
After deployment, register additional CDP wallets:

```bash
cast send $REGISTRY_ADDRESS "registerWallet(address)" $WALLET_ADDRESS \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 3. Transfer Ownership
Transfer ownership to a multisig or governance contract:

```bash
cast send $REGISTRY_ADDRESS "transferOwnership(address)" $NEW_OWNER \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY
```

## Deployment Artifacts

Deployment information is automatically saved to:
- `deployments/n0ir-{chainId}-{timestamp}.json`: Timestamped deployment record
- `deployments/n0ir-{chainId}-latest.json`: Latest deployment for the chain

## Network Information

### Base Mainnet
- Chain ID: 8453
- RPC URLs:
  - https://mainnet.base.org
  - https://base.llamarpc.com
  - https://base.meowrpc.com
- Explorer: https://basescan.org

### Base Sepolia (Testnet)
- Chain ID: 84532
- RPC URL: https://sepolia.base.org
- Explorer: https://sepolia.basescan.org
- Faucet: https://www.alchemy.com/faucets/base-sepolia

## Troubleshooting

### Common Issues

1. **"Insufficient funds"**: Ensure deployer has enough ETH for gas
2. **"Nonce too low"**: Reset nonce with `cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL`
3. **"Contract verification failed"**: Check API key and constructor arguments
4. **"Transaction underpriced"**: Increase gas price with `--with-gas-price` flag

### Gas Estimation

Approximate gas costs for deployment:
- CDPWalletRegistry: ~500,000 gas
- n0ir Protocol: ~3,000,000 gas

Total deployment cost: ~3.5M gas (check current gas prices on Base)

## Security Checklist

Before mainnet deployment:
- [ ] Audit deployment scripts
- [ ] Test on testnet first
- [ ] Verify owner address is correct
- [ ] Use hardware wallet or secure key management
- [ ] Have emergency pause plan ready
- [ ] Document all deployed addresses
- [ ] Transfer ownership to multisig after deployment