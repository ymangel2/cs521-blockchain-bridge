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

CHAIN_A_RPC="${CHAIN_A_RPC:-http://127.0.0.1:8545}"
CHAIN_B_RPC="${CHAIN_B_RPC:-http://127.0.0.1:8547}"

# --- STEP 0: Fund USER from deployer (up to 1M BRG); skip if deployer is empty ---
CHAIN_A_RPC="$CHAIN_A_RPC" python3 <<'PY'
import os, subprocess, sys
rpc = os.environ["CHAIN_A_RPC"]
fund = int("1000000000000000000000000")
token = os.environ["TOKEN"]
deployer = os.environ["DEPLOYER"]
user = os.environ["USER"]
key = os.environ["DEPLOYER_KEY"]
raw = subprocess.check_output(
    ["cast", "call", token, "balanceOf(address)(uint256)", deployer, "--rpc-url", rpc],
    text=True,
).split()[0]
bal = int(raw, 16) if raw.startswith("0x") else int(raw)
amt = min(bal, fund)
if amt == 0:
    print("Step 0: deployer BRG is 0 — skipping transfer (OK on repeat runs if USER already has BRG).")
    sys.exit(0)
subprocess.check_call(
    ["cast", "send", token, "transfer(address,uint256)", user, str(amt),
     "--private-key", key, "--rpc-url", rpc],
)
print(f"Step 0: transferred {amt} wei BRG deployer → USER (cap 1M tokens).")
PY

# Command to directly transfer funds from deployer to user:
# cast send --private-key "$DEPLOYER_KEY" --rpc-url "$CHAIN_A_RPC" \
#   "$TOKEN" "transfer(address,uint256)" "$USER" "1000000000000000000000000"

# --- STEP 1: Initial state ---
echo -n "User BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url "$CHAIN_A_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo -n "Vault BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $VAULT --rpc-url "$CHAIN_A_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo -n "User wBRG (chain-b): "; cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url "$CHAIN_B_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 2: Approve Vault to spend 100 BRG ---
cast send $TOKEN "approve(address,uint256)" $VAULT 100000000000000000000 \
  --private-key $KEY --rpc-url "$CHAIN_A_RPC"

echo -n "Allowance (user→vault): "; cast call $TOKEN "allowance(address,address)(uint256)" $USER $VAULT --rpc-url "$CHAIN_A_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 3: Deposit (lock) 100 BRG into Vault ---
cast send $VAULT "deposit(uint256)" 100000000000000000000 \
  --private-key $KEY --rpc-url "$CHAIN_A_RPC"

echo -n "User BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url "$CHAIN_A_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo -n "Vault BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $VAULT --rpc-url "$CHAIN_A_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# Validators need confirmation depth + time to write .sig files; relayer then mints.
echo "Waiting for confirmations + 2-of-3 validator signatures + relayer mint..."
sleep 12

# --- STEP 4: Mint path (wBRG on chain-b) ---
echo -n "User wBRG (chain-b): "; cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url "$CHAIN_B_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 5: Burn 100 wBRG on chain-b (reverse bridge) ---
cast send $WRAPPED "burn(uint256)" 100000000000000000000 \
  --private-key $KEY --rpc-url "$CHAIN_B_RPC"

echo -n "User wBRG (chain-b): "; cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url "$CHAIN_B_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo "Waiting for confirmations + validator signatures + relayer release..."
sleep 12

echo -n "User BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url "$CHAIN_A_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

echo -n "Vault BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $VAULT --rpc-url "$CHAIN_A_RPC" | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether