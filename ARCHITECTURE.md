# Bridge Architecture & Protocol Overview

## 1. Output Verification

Your terminal output is correct:

| Step | Expected | Your Output |
|------|----------|-------------|
| User BRG (chain-a) initial | 1,000,000 | 1,000,000 ✓ |
| Approve 100 BRG to Vault | tx hash | Success ✓ |
| Allowance (user→vault) | 100 | 100 ✓ |
| Deposit 100 BRG | tx hash | Success ✓ |
| User BRG after deposit | 999,900 | 999,900 ✓ |
| Vault BRG | 100 | 100 ✓ |
| User wBRG (chain-b) after 15s | 100 | 100 ✓ |

---

## 2. Why `100000000000000000000` = 100 BRG?

ERC-20 tokens use **18 decimals** by convention (like ETH). The smallest unit is 1 wei = 10⁻¹⁸ of a whole token.

- **100 BRG** in human terms = **100 × 10¹⁸** in raw units
- 100 × 10¹⁸ = **100000000000000000000**

So when you call `approve(vault, 100000000000000000000)` or `deposit(100000000000000000000)`, you are approving/depositing 100 BRG.

`cast --to-unit X ether` converts raw wei-style values to human-readable (e.g. 100000000000000000000 → 100).

---

## 3. Why Approve Before Deposit?

The Token contract uses the standard ERC-20 **approve/transferFrom** pattern:

1. **approve(spender, amount)** – You tell the Token: “Allow `spender` (the Vault) to move up to `amount` of my tokens.”
2. **transferFrom(from, to, amount)** – The Vault calls this to move tokens from you to itself.

The Vault cannot take your tokens without prior approval. This is by design:

- **Security:** Only addresses you approve can move your tokens.
- **Explicit consent:** You must opt in before any contract can spend your balance.
- **Standard pattern:** Same as Uniswap, Aave, etc.

Flow: `approve(Vault, 100 BRG)` → `deposit(100 BRG)` → Vault calls `transferFrom(you, Vault, 100 BRG)` → tokens move into the Vault.

---

## 4. Architecture Components

### Chains (Anvil)

- **chain-a** – Port 8545, source chain
- **chain-b** – Port 8547, destination chain

Both run **Anvil** (Foundry’s local EVM). Anvil is used for:

- Fast local development
- Deterministic accounts (e.g. `0xf39Fd...` with known keys)
- Block production (`--block-time 1`)

### Smart Contracts

| Contract | Chain | Role |
|----------|-------|------|
| **Token (BRG)** | chain-a | ERC-20; deployer gets 1M BRG |
| **Vault** | chain-a | Locks BRG via `deposit()`; emits `Deposit` events |
| **WrappedToken (wBRG)** | chain-b | ERC-20; only the relayer can mint |

### Relayer (Node.js)

- Watches chain-a for `Deposit` events
- Waits for 3 confirmations
- Calls `mint(recipient, amount)` on WrappedToken on chain-b

### Tools

- **Foundry (cast)** – CLI for sending txs and calling contracts
- **Hardhat** – Compiles Solidity
- **Docker Compose** – Runs chain-a, chain-b, and relayer

---

## 5. Protocol Flow (Lock-and-Mint)

```
┌─────────────┐                    ┌─────────────┐
│   chain-a   │                    │   chain-b   │
│  (source)   │                    │ (destination)│
├─────────────┤                    ├─────────────┤
│ Token (BRG) │                    │ WrappedToken │
│ Vault       │                    │ (wBRG)       │
└──────┬──────┘                    └──────▲──────┘
       │                                  │
       │ 1. User: approve(Vault, 100)      │
       │ 2. User: deposit(100)            │
       │ 3. Vault: transferFrom(user)     │
       │ 4. Vault: emit Deposit(user,100) │
       │                                  │
       │         ┌─────────────┐          │
       └────────►│   Relayer    │──────────┘
                 │ (off-chain)  │  5. mint(user, 100)
                 │ polls events │
                 └─────────────┘
```

1. User approves Vault to spend 100 BRG.
2. User calls `deposit(100)` on Vault.
3. Vault pulls 100 BRG from user via `transferFrom`.
4. Vault emits `Deposit(sender, amount, destChainId, blockNumber)`.
5. Relayer sees the event, waits for 3 confirmations, then mints 100 wBRG to the user on chain-b.

---

## 6. Quick Commands for Your Partner

```bash
# Setup (once)
npm install && npx hardhat compile
docker compose up -d --build
npm run deploy

# Load env
export TOKEN=$(jq -r '.chainA.token' relayer/config.json)
export VAULT=$(jq -r '.chainA.vault' relayer/config.json)
export WRAPPED=$(jq -r '.chainB.wrappedToken' relayer/config.json)
export USER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Bridge flow
cast send $TOKEN "approve(address,uint256)" $VAULT 100000000000000000000 --private-key $KEY --rpc-url http://localhost:8545
cast send $VAULT "deposit(uint256)" 100000000000000000000 --private-key $KEY --rpc-url http://localhost:8545
sleep 15
cast call $WRAPPED "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8547
```

**Prerequisites:** Foundry (`foundryup`), Docker, Node.js.
