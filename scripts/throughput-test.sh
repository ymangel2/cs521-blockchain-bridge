#!/bin/bash
set -e
cd "$(dirname "$0")/.."

# ===================== CONFIG =====================
NUM_RUNS=2   # set >1 to average multiple full rounds
AMOUNT=1000000000000000000  # 1 token

# ===================== LOAD STATE =====================
echo "Loading initial state..."

USER_BAL_START=$(cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547 | awk '{print $1}')

# ===================== AGGREGATES =====================
TOTAL_APPROVE_GAS=0
TOTAL_DEPOSIT_GAS=0
TOTAL_MINT_GAS=0
TOTAL_BURN_GAS=0
TOTAL_RELEASE_GAS=0

TOTAL_MINT_LAT=0
TOTAL_RELEASE_LAT=0

# ===================== LOOP =====================
for run in $(seq 1 $NUM_RUNS); do

echo ""
echo "================ RUN $run ================="
echo ""

# ---------------- APPROVE ----------------
echo "Approving..."

APPROVE_START=$(date +%s%3N)

APPROVE_TX=$(cast send $TOKEN \
  "approve(address,uint256)" \
  $VAULT \
  $(echo "$AMOUNT * 10" | bc) \
  --private-key $KEY \
  --rpc-url http://localhost:8545 --json)

APPROVE_HASH=$(echo "$APPROVE_TX" | jq -r '.transactionHash')

APPROVE_GAS=$(cast receipt $APPROVE_HASH --rpc-url http://localhost:8545 | awk '/gasUsed/ {print $2}')
APPROVE_END=$(date +%s%3N)

TOTAL_APPROVE_GAS=$((TOTAL_APPROVE_GAS + APPROVE_GAS))

echo "Approve gas: $APPROVE_GAS"

# ---------------- DEPOSIT ----------------
echo "Depositing..."

DEPOSIT_START=$(date +%s%3N)

DEPOSIT_TX=$(cast send $VAULT \
  "deposit(uint256)" \
  $AMOUNT \
  --private-key $KEY \
  --rpc-url http://localhost:8545 --json)

DEPOSIT_HASH=$(echo "$DEPOSIT_TX" | jq -r '.transactionHash')

DEPOSIT_GAS=$(cast receipt $DEPOSIT_HASH --rpc-url http://localhost:8545 | awk '/gasUsed/ {print $2}')

DEPOSIT_END=$(date +%s%3N)

TOTAL_DEPOSIT_GAS=$((TOTAL_DEPOSIT_GAS + DEPOSIT_GAS))

echo "Deposit gas: $DEPOSIT_GAS"

# ---------------- WAIT FOR MINT ----------------
echo "Waiting for mint..."

MINT_START=$(date +%s%3N)

EXPECTED=$((AMOUNT))

while true; do
  BAL=$(cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547 | awk '{print $1}')
  if [ "$BAL" = "$EXPECTED" ]; then
    break
  fi
  sleep 1
done

MINT_END=$(date +%s%3N)
MINT_LAT=$((MINT_END - MINT_START))

TOTAL_MINT_LAT=$((TOTAL_MINT_LAT + MINT_LAT))

MINT_TX=$(docker logs relayer 2>&1 \
  | grep "MINTED" \
  | grep -o "0x[a-fA-F0-9]\{64\}" \
  | tail -1)

if [ -z "$MINT_TX" ]; then
  echo "❌ Mint tx not found"
  MINT_GAS=0
else
  MINT_GAS=$(cast receipt $MINT_TX --rpc-url http://localhost:8547 | awk '/gasUsed/ {print $2}')
fi

TOTAL_MINT_GAS=$((TOTAL_MINT_GAS + MINT_GAS))

echo "Mint latency: $MINT_LAT ms"
echo "Mint gas: $MINT_GAS"

# ---------------- BURN ----------------
echo "Burning..."

BURN_START=$(date +%s%3N)

BURN_TX=$(cast send $WRAPPED \
  "burn(uint256)" \
  $AMOUNT \
  --private-key $KEY \
  --rpc-url http://localhost:8547 --json)

BURN_HASH=$(echo "$BURN_TX" | jq -r '.transactionHash')

BURN_GAS=$(cast receipt $BURN_HASH --rpc-url http://localhost:8547 | awk '/gasUsed/ {print $2}')

BURN_END=$(date +%s%3N)

TOTAL_BURN_GAS=$((TOTAL_BURN_GAS + BURN_GAS))

echo "Burn gas: $BURN_GAS"

# ---------------- WAIT FOR RELEASE ----------------
echo "Waiting for release..."

RELEASE_START=$(date +%s%3N)

EXPECTED_RELEASE="1000000000000000000000000" # adjust if needed

while true; do
  BAL=$(cast call $TOKEN "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545 | awk '{print $1}')
  if [ "$BAL" = "$EXPECTED_RELEASE" ]; then
    break
  fi
  sleep 1
done

RELEASE_END=$(date +%s%3N)
RELEASE_LAT=$((RELEASE_END - RELEASE_START))

TOTAL_RELEASE_LAT=$((TOTAL_RELEASE_LAT + RELEASE_LAT))

RELEASE_TX=$(docker logs relayer 2>&1 | grep "RELEASED" | tail -1 | sed -n 's/.*tx: \(0x[a-fA-F0-9]\+\).*/\1/p')

if [ ! -z "$RELEASE_TX" ]; then
  RELEASE_GAS=$(cast receipt $RELEASE_TX --rpc-url http://localhost:8545 | awk '/gasUsed/ {print $2}')
else
  RELEASE_GAS=0
fi

TOTAL_RELEASE_GAS=$((TOTAL_RELEASE_GAS + RELEASE_GAS))

echo "Release latency: $RELEASE_LAT ms"
echo "Release gas: $RELEASE_GAS"

done

# ===================== AVERAGES =====================

echo ""
echo "==================== FINAL RESULTS ===================="

echo "Avg approve gas: $((TOTAL_APPROVE_GAS / NUM_RUNS))"
echo "Avg deposit gas: $((TOTAL_DEPOSIT_GAS / NUM_RUNS))"
echo "Avg mint gas: $((TOTAL_MINT_GAS / NUM_RUNS))"
echo "Avg burn gas: $((TOTAL_BURN_GAS / NUM_RUNS))"
echo "Avg release gas: $((TOTAL_RELEASE_GAS / NUM_RUNS))"

echo ""
echo "Avg mint latency: $((TOTAL_MINT_LAT / NUM_RUNS)) ms"
echo "Avg release latency: $((TOTAL_RELEASE_LAT / NUM_RUNS)) ms"

echo ""
echo "Total round-trip latency: $(( (TOTAL_MINT_LAT + TOTAL_RELEASE_LAT) / NUM_RUNS )) ms"

echo ""
echo "Derived throughput (sequential):"
echo "≈ $(echo "scale=4; 1000 / (( $TOTAL_MINT_LAT + $TOTAL_RELEASE_LAT ) / $NUM_RUNS)" | bc -l) tx/sec"
echo ""
echo "======================================================="