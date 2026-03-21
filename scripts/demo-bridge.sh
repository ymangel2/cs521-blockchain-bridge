#!/bin/bash
#
# SETUP (do once before running, or after any full restart):
#   1. Install Foundry (for cast): curl -L https://foundry.paradigm.xyz | bash && foundryup (source ~/.zshenv if already in path)
#   2. Start all containers: docker compose up -d --build
#   3. Deploy contracts: npm run deploy  (relayer waits for config, then starts)
#   4. Load addresses (run once in your shell):
#      export TOKEN=$(jq -r '.chainA.token' relayer/config.json) VAULT=$(jq -r '.chainA.vault' relayer/config.json) WRAPPED=$(jq -r '.chainB.wrappedToken' relayer/config.json) USER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
#
# Monitor relayer output: docker logs -f relayer (do not run "docker exec relayer node index.js" - that starts a 2nd relayer and causes double mint)
# =============================================================================

# --- STEP 0: Fund test user with BRG (deployer has all 1M from deploy) ---
cast send $TOKEN "transfer(address,uint256)" $USER 1000000000000000000000000 \
  --private-key $DEPLOYER_KEY --rpc-url http://localhost:8545 > /dev/null 2>&1

# --- STEP 1: Initial state ---
# User BRG balance on chain-a (source). Expect: 1000000.0 BRG
echo -n "User BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# Vault BRG balance on chain-a. Expect: 0.0 (nothing locked yet)
echo -n "Vault BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $VAULT --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# User wBRG balance on chain-b (destination). Expect: 0.0
echo -n "User wBRG (chain-b): "; cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 2: Approve Vault to spend 100 BRG ---
# Grants allowance. Expect: tx hash
cast send $TOKEN "approve(address,uint256)" $VAULT 100000000000000000000 \
  --private-key $KEY --rpc-url http://localhost:8545

# Verify allowance. Expect: 100.0 BRG
echo -n "Allowance (user→vault): "; cast call $TOKEN "allowance(address,address)(uint256)" $USER $VAULT --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 3: Deposit (lock) 100 BRG into Vault ---
# Locks tokens on source chain. Expect: tx hash
cast send $VAULT "deposit(uint256)" 100000000000000000000 \
  --private-key $KEY --rpc-url http://localhost:8545

# User BRG balance after lock. Expect: 999900.0 (decreased by 100)
echo -n "User BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# Vault BRG balance. Expect: 100.0 (tokens are locked here)
echo -n "Vault BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $VAULT --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 4: Wait for relayer to mint (poll chain-b) ---
# Wait ~15s for relayer to process Deposit event and mint on chain-b
sleep 15

# User wBRG balance on chain-b. Expect: 100.0 (100 wBRG minted)
echo -n "User wBRG (chain-b): "; cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 5: Burn 100 wBRG on chain-b (reverse bridge) ---
# Burns wBRG. Expect: tx hash
cast send $WRAPPED "burn(uint256)" 100000000000000000000 \
  --private-key $KEY --rpc-url http://localhost:8547

# User wBRG after burn. Expect: 0.0
echo -n "User wBRG (chain-b): "; cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# --- STEP 6: Wait for relayer to release (poll chain-a) ---
# Wait ~15s for relayer to process Burn event and release BRG on chain-a
sleep 15

# User BRG after release. Expect: 1000000.0 (100 BRG returned)
echo -n "User BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether

# Vault BRG after release. Expect: 0.0
echo -n "Vault BRG (chain-a): "; cast call $TOKEN "balanceOf(address)(uint256)" $VAULT --rpc-url http://localhost:8545 | cut -d' ' -f1 | xargs -I {} cast --to-unit {} ether
