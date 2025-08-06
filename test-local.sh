#!/bin/bash

# n0ir Protocol - Local Testing Script
# This script sets up a local Anvil fork and deploys the protocol for testing

set -e

echo "================================================"
echo "   n0ir Protocol - Local Fork Testing"
echo "================================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
FORK_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
FORK_BLOCK="${FORK_BLOCK:-latest}"
PORT="${ANVIL_PORT:-8545}"

echo -e "${YELLOW}Configuration:${NC}"
echo "  Fork URL: $FORK_URL"
echo "  Fork Block: $FORK_BLOCK"
echo "  Local Port: $PORT"
echo ""

# Check if anvil is installed
if ! command -v anvil &> /dev/null; then
    echo -e "${RED}Error: Anvil is not installed${NC}"
    echo "Install with: curl -L https://foundry.paradigm.xyz | bash"
    exit 1
fi

# Check if forge is installed
if ! command -v forge &> /dev/null; then
    echo -e "${RED}Error: Forge is not installed${NC}"
    echo "Install with: curl -L https://foundry.paradigm.xyz | bash"
    exit 1
fi

# Kill any existing anvil instance
echo -e "${YELLOW}Stopping any existing Anvil instance...${NC}"
pkill anvil 2>/dev/null || true
sleep 2

# Start Anvil fork in the background
echo -e "${GREEN}Starting Anvil fork of Base mainnet...${NC}"
anvil \
    --fork-url $FORK_URL \
    --fork-block-number $FORK_BLOCK \
    --port $PORT \
    --accounts 10 \
    --balance 10000 \
    --chain-id 8453 \
    --block-time 2 \
    --no-mining \
    --steps-tracing \
    > anvil.log 2>&1 &

ANVIL_PID=$!
echo "Anvil PID: $ANVIL_PID"

# Wait for Anvil to start
echo -e "${YELLOW}Waiting for Anvil to start...${NC}"
sleep 5

# Check if Anvil is running
if ! curl -s -X POST http://localhost:$PORT \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' > /dev/null 2>&1; then
    echo -e "${RED}Error: Anvil failed to start${NC}"
    echo "Check anvil.log for details"
    exit 1
fi

echo -e "${GREEN}Anvil is running!${NC}"
echo ""

# Deploy contracts
echo -e "${GREEN}Deploying n0ir Protocol to local fork...${NC}"
forge script script/LocalTest.s.sol:LocalTest \
    --rpc-url http://localhost:$PORT \
    --broadcast \
    -vvv

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   Local deployment successful!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

echo "Anvil is running on: http://localhost:$PORT"
echo "Chain ID: 8453 (Base fork)"
echo ""

echo "Test wallet addresses (10,000 ETH each):"
echo "  Wallet 1: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
echo "  Wallet 2: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
echo "  Wallet 3: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
echo ""

echo "Private keys for testing:"
echo "  Key 1: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
echo "  Key 2: 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
echo "  Key 3: 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
echo ""

echo -e "${YELLOW}To interact with the contracts:${NC}"
echo "  export RPC_URL=http://localhost:$PORT"
echo "  cast call <CONTRACT_ADDRESS> \"USDC()\""
echo ""

echo -e "${YELLOW}To stop Anvil:${NC}"
echo "  kill $ANVIL_PID"
echo "  # or"
echo "  pkill anvil"
echo ""

echo -e "${GREEN}Happy testing! 🚀${NC}"

# Keep script running
echo ""
echo "Press Ctrl+C to stop Anvil and exit..."
wait $ANVIL_PID