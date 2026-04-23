#!/bin/bash
#
# =============================================================================
# SETUP (once, or after a full restart)
# =============================================================================
# 1. Install Foundry (for cast): https://book.getfoundry.sh/getting-started/installation
# 2. Start chains + relayer:
#      docker compose up -d --build
# 3. Deploy contracts:
#      npm run deploy
# 4. Start THREE validator processes on the host (e.g. three terminals). Each one
#    MUST set VALIDATOR_INDEX to 0, 1, or 2. If you omit it, every process is
#    validator 0 — you will only get v0.sig and the relayer will stay stuck (2-of-3).
#    They write under relayer/attestations/ (Docker relayer mounts that folder).
#
#    validator.js loads relayer/config.json via its own file path, so you can run
#    `node /full/path/to/.../relayer/validator.js` from any cwd after deploy.
#    Optional if RPCs in config differ from your setup:
#      export CHAIN_A_RPC=http://127.0.0.1:8545 CHAIN_B_RPC=http://127.0.0.1:8547
#
#      VALIDATOR_INDEX=0 node relayer/validator.js
#      VALIDATOR_INDEX=1 node relayer/validator.js
#      VALIDATOR_INDEX=2 node relayer/validator.js
#
#    (from repo root, or pass an absolute path to validator.js.)
# 5. Load addresses (run once in the shell that will run the casts below):
#      export TOKEN=$(jq -r '.chainA.token' relayer/config.json) \
#             VAULT=$(jq -r '.chainA.vault' relayer/config.json) \
#             WRAPPED=$(jq -r '.chainB.wrappedToken' relayer/config.json) \
#             USER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
#             KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
#             DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
#             DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
#
# Monitor relayer: docker logs -f relayer

# The lines below (set -e / cd) apply only to THIS script when you run
#   bash scripts/demo-bridge.sh
set -e
cd "$(dirname "$0")/.."

# gas calculation init + helper functions
APPROVE_GAS=0
DEPOSIT_GAS=0
MINT_GAS=0
BURN_GAS=0
RELEASE_GAS=0

get_gas () {
  cast receipt "$1" --rpc-url "$2" | awk '/gasUsed/ {print $2}'
}

to_wei () {
  echo "$1"
}

get_gas_from_tx () {
  local TX_HASH=$1
  local RPC=$2
  cast receipt "$TX_HASH" --rpc-url "$RPC" | awk '/gasUsed/ {print $2}'
}

# --- STEP 0: Fund test user with BRG (deployer has all 1M from deploy) --- ONLY RUN DURING FIRST ITERATION
# cast send $TOKEN "transfer(address,uint256)" $USER 1000000000000000000000000 \
#   --private-key $DEPLOYER_KEY --rpc-url http://localhost:8545 > /dev/null

# --- STEP 1: Initial state ---
echo "Initial state:"
echo ""

echo -n "User BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo -n "Vault BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $VAULT --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo -n "User wBRG (chain-b): "; cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether


# --- STEP 2: Approve Vault to spend 100 BRG ---
echo ""
echo "Approving Vault to spend 100 BRG..." 
echo ""

TX=$(cast send $TOKEN "approve(address,uint256)" $VAULT 100000000000000000000 \
  --private-key $KEY --rpc-url http://localhost:8545 --json)

APPROVE_HASH=$(echo "$TX" | jq -r '.transactionHash')
APPROVE_GAS=$(get_gas "$APPROVE_HASH" "http://localhost:8545")

echo -n "Allowance (user→vault): "; cast call $TOKEN "allowance(address,address)(uint256)" $USER $VAULT --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 3: Deposit (lock) 100 BRG into Vault ---

echo ""
echo "Depositing 100 BRG into Vault..."
echo ""

TX=$(cast send $VAULT "deposit(uint256)" 100000000000000000000 \
  --private-key $KEY --rpc-url http://localhost:8545 --json)

DEPOSIT_HASH=$(echo "$TX" | jq -r '.transactionHash')
DEPOSIT_GAS=$(get_gas "$DEPOSIT_HASH" "http://localhost:8545")

echo -n "User BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo -n "Vault BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $VAULT --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# Validators need confirmation depth + time to write .sig files; relayer then mints.
echo ""
echo "Waiting for confirmations + 2-of-3 validator signatures + relayer mint..."
echo ""

# sleep 12

START=$(date +%s%3N)

EXPECTED="100000000000000000000"

while true; do
  BAL=$(cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547 \
    | awk '{print $1}')

  if [ "$BAL" = "$EXPECTED" ]; then
    break
  fi

  sleep 1
done

END=$(date +%s%3N)
MINT_LATENCY=$((END - START))

MINT_TX=$(docker logs relayer 2>&1 | grep "MINTED" | tail -1 | sed -n 's/.*tx: \(0x[a-fA-F0-9]\+\).*/\1/p')

if [ ! -z "$MINT_TX" ]; then
  MINT_GAS=$(get_gas_from_tx "$MINT_TX" "http://localhost:8547")
else
  MINT_GAS=0
fi

# --- STEP 4: Mint path (wBRG on chain-b) ---
echo -n "User wBRG (chain-b): "; cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 5: Burn 100 wBRG on chain-b (reverse bridge) ---
echo ""
echo "Burning the 100 wBRG..."
echo ""
TX=$(cast send $WRAPPED "burn(uint256)" 100000000000000000000 \
  --private-key $KEY --rpc-url http://localhost:8547 --json)

BURN_HASH=$(echo "$TX" | jq -r '.transactionHash')
BURN_GAS=$(get_gas "$BURN_HASH" "http://localhost:8547")

echo -n "User wBRG (chain-b): "; cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo ""
echo "Waiting for confirmations + validator signatures + relayer release..."
echo ""

# sleep 12

START=$(date +%s%3N)

EXPECTED="1000000"  # adjust if your release amount differs

while true; do
  RAW=$(cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545)

  BAL=$(echo "$RAW" \
    | cut -d' ' -f1 \
    | xargs -I {} cast --to-unit {} ether)
    
  if [ "$BAL" = "$EXPECTED" ]; then
    break
  fi

  sleep 1
done

END=$(date +%s%3N)
RELEASE_LATENCY=$((END - START))

RELEASE_TX=$(docker logs relayer 2>&1 | grep "RELEASED" | tail -1 | sed -n 's/.*tx: \(0x[a-fA-F0-9]\+\).*/\1/p')

if [ ! -z "$RELEASE_TX" ]; then
  RELEASE_GAS=$(get_gas_from_tx "$RELEASE_TX" "http://localhost:8545")
else
  RELEASE_GAS=0
fi

echo -n "User BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo -n "Vault BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $VAULT --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

TOTAL_FORWARD=$((APPROVE_GAS + DEPOSIT_GAS + MINT_GAS))
TOTAL_REVERSE=$((BURN_GAS + RELEASE_GAS))
TOTAL_ROUNDTRIP=$((TOTAL_FORWARD + TOTAL_REVERSE))
echo ""
echo "================== LATENCY SUMMARY =================="
echo ""
echo "Mint latency (ms): $MINT_LATENCY"
echo "Release latency (ms): $RELEASE_LATENCY"
echo "Total round-trip latency (ms): $((MINT_LATENCY + $RELEASE_LATENCY))"
echo ""
echo "==================== GAS SUMMARY ===================="
echo ""
echo "Approve gas: $APPROVE_GAS"
echo "Deposit gas: $DEPOSIT_GAS"
echo "Mint gas: $MINT_GAS"
echo "Burn gas: $BURN_GAS"
echo "Release gas: $RELEASE_GAS"
echo ""
echo "Total forward gas: $TOTAL_FORWARD"
echo "Total reverse gas: $TOTAL_REVERSE"
echo "Total round-trip gas: $TOTAL_ROUNDTRIP"
echo ""
echo "====================================================="
