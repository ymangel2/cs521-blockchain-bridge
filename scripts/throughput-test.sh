#!/bin/bash
#
# Sequential (synchronous) bridge benchmark: for each run, approve → deposit →
# wait mint → burn → wait release. Captures gas, attestation-segment latencies,
# and full round-trip wall time per run.
#
# Prerequisites: docker chains + relayer, npm run deploy, three validators,
# env: TOKEN VAULT WRAPPED USER KEY (same as demo-bridge.sh).
# For auto-funding USER with BRG (recommended): DEPLOYER + DEPLOYER_KEY (Anvil account #0).
#
# Usage: from repo root, with env loaded:
#   bash scripts/throughput-test.sh
#
# Optional: NUM_RUNS=5 AMOUNT=100000000000000000000 bash scripts/throughput-test.sh
#
set -e
cd "$(dirname "$0")/.."

CHAIN_A_RPC="${CHAIN_A_RPC:-http://127.0.0.1:8545}"
CHAIN_B_RPC="${CHAIN_B_RPC:-http://127.0.0.1:8547}"

# ms since epoch (macOS-safe; GNU date %3N is not portable)
ms_now() {
  python3 -c "import time; print(int(time.time() * 1000))"
}

# First field from cast call (uint256)
call_u256() {
  cast call "$1" "$2" "$3" --rpc-url "$4" | awk '{print $1}'
}

# int(wbrg_before) + AMOUNT as decimal string
expected_wbrg_after_mint() {
  python3 -c "w='$1'; a=$2; wi=int(w, 16) if w.startswith('0x') else int(w); print(wi + a)"
}

# normalize uint string to decimal for compare
to_dec_str() {
  python3 -c "x='$1'; print(int(x, 16) if x.startswith('0x') else int(x))"
}

# ===================== CONFIG =====================
NUM_RUNS="${NUM_RUNS:-2}"
AMOUNT="${AMOUNT:-1000000000000000000}" # default 1 token (18 decimals)

if [ -z "${TOKEN:-}" ] || [ -z "${WRAPPED:-}" ] || [ -z "${VAULT:-}" ] || [ -z "${USER:-}" ] || [ -z "${KEY:-}" ]; then
  echo "Set TOKEN, VAULT, WRAPPED, USER, KEY (see scripts/demo-bridge.sh header)."
  exit 1
fi

# Approve ceiling: 10 deposits of AMOUNT per run (adjust if NUM_RUNS * AMOUNT exceeds)
APPROVE_CAP=$(python3 -c "print($AMOUNT * 10)")

# ===================== AGGREGATES =====================
TOTAL_APPROVE_GAS=0
TOTAL_DEPOSIT_GAS=0
TOTAL_MINT_GAS=0
TOTAL_BURN_GAS=0
TOTAL_RELEASE_GAS=0

TOTAL_MINT_LAT=0
TOTAL_RELEASE_LAT=0
TOTAL_FULL_CYCLE_MS=0

echo "Sequential throughput test: NUM_RUNS=$NUM_RUNS AMOUNT=$AMOUNT wei"
echo "chain-a: $CHAIN_A_RPC  chain-b: $CHAIN_B_RPC"
echo ""

# --- Ensure USER has enough BRG for at least one deposit(AMOUNT) ---
MIN_BRG="$AMOUNT"
UBRG_RAW=$(call_u256 "$TOKEN" "balanceOf(address)(uint256)" "$USER" "$CHAIN_A_RPC")
UBRG=$(to_dec_str "$UBRG_RAW")
if [ "$(python3 -c "print(1 if $UBRG < $MIN_BRG else 0)")" = "1" ]; then
  if [ -n "${DEPLOYER_KEY:-}" ] && [ -n "${DEPLOYER:-}" ]; then
    echo "Funding USER from deployer (USER BRG $UBRG wei < need $MIN_BRG wei for deposit)..."
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
    print("Deployer has 0 BRG — run npm run deploy with fresh chains or fund USER manually.")
    sys.exit(1)
subprocess.check_call(
    ["cast", "send", token, "transfer(address,uint256)", user, str(amt),
     "--private-key", key, "--rpc-url", rpc],
)
print(f"Transferred {amt} wei BRG to USER.")
PY
  else
    echo "USER BRG ($UBRG wei) is less than AMOUNT ($MIN_BRG wei). Deposit would revert (Vault: transferFrom failed)."
    echo "Export DEPLOYER and DEPLOYER_KEY (see demo-bridge.sh) for auto-fund, or transfer BRG to USER first."
    exit 1
  fi
fi

# ===================== LOOP =====================
for run in $(seq 1 "$NUM_RUNS"); do
  echo ""
  echo "================ RUN $run / $NUM_RUNS ================"
  echo ""

  BRG_BEFORE=$(call_u256 "$TOKEN" "balanceOf(address)(uint256)" "$USER" "$CHAIN_A_RPC")
  WBRG_BEFORE=$(call_u256 "$WRAPPED" "balanceOf(address)(uint256)" "$USER" "$CHAIN_B_RPC")
  EXPECTED_WBRG=$(expected_wbrg_after_mint "$WBRG_BEFORE" "$AMOUNT")
  BRG_TARGET=$(to_dec_str "$BRG_BEFORE")

  echo "Pre-run balances: BRG(target after release)=$BRG_TARGET  wBRG=$WBRG_BEFORE  → expect wBRG after mint=$EXPECTED_WBRG"

  FULL_CYCLE_START=$(ms_now)

  # ---------------- APPROVE ----------------
  echo "Approving..."
  APPROVE_TX=$(cast send "$TOKEN" \
    "approve(address,uint256)" \
    "$VAULT" \
    "$APPROVE_CAP" \
    --private-key "$KEY" \
    --rpc-url "$CHAIN_A_RPC" --json)

  APPROVE_HASH=$(echo "$APPROVE_TX" | jq -r '.transactionHash')
  APPROVE_GAS=$(cast receipt "$APPROVE_HASH" --rpc-url "$CHAIN_A_RPC" | awk '/gasUsed/ {print $2}')
  TOTAL_APPROVE_GAS=$((TOTAL_APPROVE_GAS + APPROVE_GAS))
  echo "Approve gas: $APPROVE_GAS"

  # ---------------- DEPOSIT ----------------
  echo "Depositing..."
  DEPOSIT_TX=$(cast send "$VAULT" \
    "deposit(uint256)" \
    "$AMOUNT" \
    --private-key "$KEY" \
    --rpc-url "$CHAIN_A_RPC" --json)

  DEPOSIT_HASH=$(echo "$DEPOSIT_TX" | jq -r '.transactionHash')
  DEPOSIT_GAS=$(cast receipt "$DEPOSIT_HASH" --rpc-url "$CHAIN_A_RPC" | awk '/gasUsed/ {print $2}')
  TOTAL_DEPOSIT_GAS=$((TOTAL_DEPOSIT_GAS + DEPOSIT_GAS))
  echo "Deposit gas: $DEPOSIT_GAS"

  # ---------------- WAIT FOR MINT ----------------
  echo "Waiting for mint (post-deposit → wBRG += amount)..."
  MINT_START=$(ms_now)

  while true; do
    BAL_RAW=$(call_u256 "$WRAPPED" "balanceOf(address)(uint256)" "$USER" "$CHAIN_B_RPC")
    BAL_N=$(to_dec_str "$BAL_RAW")
    if [ "$BAL_N" = "$EXPECTED_WBRG" ]; then
      break
    fi
    sleep 1
  done

  MINT_END=$(ms_now)
  MINT_LAT=$((MINT_END - MINT_START))
  TOTAL_MINT_LAT=$((TOTAL_MINT_LAT + MINT_LAT))

  MINT_TX=$(
    docker logs relayer 2>&1 |
      grep "MINTED" |
      tail -1 |
      sed -n 's/.*tx: \(0x[a-fA-F0-9]\{64\}\).*/\1/p'
  )

  if [ -z "$MINT_TX" ]; then
    echo "Mint tx not found in relayer logs (grep MINTED ... tx: 0x...)"
    MINT_GAS=0
  else
    MINT_GAS=$(cast receipt "$MINT_TX" --rpc-url "$CHAIN_B_RPC" | awk '/gasUsed/ {print $2}')
  fi
  TOTAL_MINT_GAS=$((TOTAL_MINT_GAS + MINT_GAS))

  echo "Mint wait latency: ${MINT_LAT} ms (deposit mined → wBRG target; ~1s poll quantization)"
  echo "Mint gas: $MINT_GAS"

  # ---------------- BURN ----------------
  echo "Burning..."
  BURN_TX=$(cast send "$WRAPPED" \
    "burn(uint256)" \
    "$AMOUNT" \
    --private-key "$KEY" \
    --rpc-url "$CHAIN_B_RPC" --json)

  BURN_HASH=$(echo "$BURN_TX" | jq -r '.transactionHash')
  BURN_GAS=$(cast receipt "$BURN_HASH" --rpc-url "$CHAIN_B_RPC" | awk '/gasUsed/ {print $2}')
  TOTAL_BURN_GAS=$((TOTAL_BURN_GAS + BURN_GAS))
  echo "Burn gas: $BURN_GAS"

  # ---------------- WAIT FOR RELEASE ----------------
  echo "Waiting for release (post-burn → BRG restored to pre-run)..."
  RELEASE_START=$(ms_now)

  while true; do
    BAL_RAW=$(call_u256 "$TOKEN" "balanceOf(address)(uint256)" "$USER" "$CHAIN_A_RPC")
    BAL_N=$(to_dec_str "$BAL_RAW")
    if [ "$BAL_N" = "$BRG_TARGET" ]; then
      break
    fi
    sleep 1
  done

  RELEASE_END=$(ms_now)
  RELEASE_LAT=$((RELEASE_END - RELEASE_START))
  TOTAL_RELEASE_LAT=$((TOTAL_RELEASE_LAT + RELEASE_LAT))

  RELEASE_TX=$(
    docker logs relayer 2>&1 |
      grep "RELEASED" |
      tail -1 |
      sed -n 's/.*tx: \(0x[a-fA-F0-9]\{64\}\).*/\1/p'
  )

  if [ -n "$RELEASE_TX" ]; then
    RELEASE_GAS=$(cast receipt "$RELEASE_TX" --rpc-url "$CHAIN_A_RPC" | awk '/gasUsed/ {print $2}')
  else
    RELEASE_GAS=0
  fi
  TOTAL_RELEASE_GAS=$((TOTAL_RELEASE_GAS + RELEASE_GAS))

  FULL_CYCLE_END=$(ms_now)
  FULL_CYCLE_MS=$((FULL_CYCLE_END - FULL_CYCLE_START))
  TOTAL_FULL_CYCLE_MS=$((TOTAL_FULL_CYCLE_MS + FULL_CYCLE_MS))

  echo "Release wait latency: ${RELEASE_LAT} ms"
  echo "Release gas: $RELEASE_GAS"
  echo "Full round-trip wall (this run): ${FULL_CYCLE_MS} ms (approve through release confirmed)"
done

# ===================== SUMMARY =====================
AVG_MINT_LAT=$((TOTAL_MINT_LAT / NUM_RUNS))
AVG_REL_LAT=$((TOTAL_RELEASE_LAT / NUM_RUNS))
AVG_ATTEST_MS=$((AVG_MINT_LAT + AVG_REL_LAT))
AVG_FULL_MS=$((TOTAL_FULL_CYCLE_MS / NUM_RUNS))

echo ""
echo "==================== FINAL RESULTS ===================="
echo "Runs: $NUM_RUNS  Amount per leg: $AMOUNT wei"
echo ""
echo "--- Gas (avg per run) ---"
echo "Approve:     $((TOTAL_APPROVE_GAS / NUM_RUNS))"
echo "Deposit:     $((TOTAL_DEPOSIT_GAS / NUM_RUNS))"
echo "Mint:        $((TOTAL_MINT_GAS / NUM_RUNS))"
echo "Burn:        $((TOTAL_BURN_GAS / NUM_RUNS))"
echo "Release:     $((TOTAL_RELEASE_GAS / NUM_RUNS))"
echo ""
echo "--- Latency (avg per run, ms) ---"
echo "Mint wait:   $AVG_MINT_LAT  (after deposit tx, until wBRG reaches pre+mint amount)"
echo "Release wait: $AVG_REL_LAT  (after burn tx, until BRG returns to pre-run level)"
echo "Attestation legs only (mint wait + release wait): $AVG_ATTEST_MS"
echo "Full round-trip wall (approve → release done): $AVG_FULL_MS"
echo ""
echo "--- Throughput (define in report) ---"
if [ "$AVG_ATTEST_MS" -gt 0 ]; then
  ATTEST_JPS=$(python3 -c "print(round(1000.0 / $AVG_ATTEST_MS, 6))")
  echo "Jobs/s from attestation legs only (~= 1000 / avg mint+release wait): ~$ATTEST_JPS"
fi
if [ "$AVG_FULL_MS" -gt 0 ]; then
  FULL_JPS=$(python3 -c "print(round(1000.0 / $AVG_FULL_MS, 6))")
  echo "Jobs/s from full sequential round-trip wall: ~$FULL_JPS"
fi
if [ "$TOTAL_FULL_CYCLE_MS" -gt 0 ]; then
  BATCH_JPS=$(python3 -c "print(round($NUM_RUNS * 1000.0 / $TOTAL_FULL_CYCLE_MS, 6))")
  echo "Batch throughput (all $NUM_RUNS runs / sum of per-run wall times): ~$BATCH_JPS jobs/s"
fi
echo ""
echo "Note: Poll interval is 1s; latencies include up to ~1s quantization per wait."
echo "======================================================="
