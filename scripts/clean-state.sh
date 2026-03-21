#!/bin/bash
#
# Puts the bridge in a clean state: fresh chains, fresh contracts.
# Use after testing mishaps (e.g. double mint, odd balances) or when you want
# to start over.
#
# Steps:
#   1. Stop and remove containers (ephemeral chain data is lost)
#   2. Rebuild and start chain-a, chain-b, relayer
#   3. Redeploy Token, Vault, WrappedToken (config.json is updated)
#
# After this, re-export addresses and run the demo:
#   export TOKEN=$(jq -r '.chainA.token' relayer/config.json) VAULT=$(jq -r '.chainA.vault' relayer/config.json) WRAPPED=$(jq -r '.chainB.wrappedToken' relayer/config.json) USER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
#   ./scripts/demo-bridge.sh
#

set -e

echo "Stopping containers..."
docker compose down

echo "Rebuilding relayer (--no-cache to pick up code changes) and starting..."
docker compose build --no-cache relayer
docker compose up -d

echo "Waiting for chains to be ready..."
sleep 5

echo "Deploying fresh contracts..."
npm run deploy

echo ""
echo "Clean state complete. Re-export and run demo:"
echo "  export TOKEN=\$(jq -r '.chainA.token' relayer/config.json) VAULT=\$(jq -r '.chainA.vault' relayer/config.json) WRAPPED=\$(jq -r '.chainB.wrappedToken' relayer/config.json) USER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
echo "  ./scripts/demo-bridge.sh"
