# Topic 14: Blockchain Bridges and Cross-Chain Communication

### Coding project: Implement a simplified bridge between two local test chains that locks tokens on one chain and mints wrapped tokens on the other, using a relayer to pass attestations.

## Quick Start

```bash
npm install && npx hardhat compile
docker compose up -d --build
npm run deploy
# Load env and run demo (see scripts/demo-bridge.sh)
```

### Clean State (Reset Chains and Contracts)

If you end up in a bad state (e.g. odd balances, failed txs, or "transaction already imported" from the relayer), reset everything:

```bash
./scripts/clean-state.sh
```

This does `docker compose down`, rebuilds and starts containers, then runs `npm run deploy`. The chains are ephemeral (no volumes), so they start fresh. You must re-deploy because old contract addresses no longer exist. Afterward, re-export addresses and run the demo again.

---

## Demo Script: Why Export Addresses?

The demo script (`scripts/demo-bridge.sh`) uses `cast` to call contracts. `cast` needs contract addresses and RPC URLs, but it does not read `config.json` or deployment artifacts. You must export the addresses so the shell can substitute them:

```bash
export TOKEN=$(jq -r '.chainA.token' relayer/config.json) VAULT=$(jq -r '.chainA.vault' relayer/config.json) WRAPPED=$(jq -r '.chainB.wrappedToken' relayer/config.json) USER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

- **TOKEN, VAULT, WRAPPED** - Contract addresses from the deploy output; the script reads them from `relayer/config.json`.
- **USER** - Anvil's default first account; the demo uses it as sender.
- **KEY** - That account's private key; required by `cast send` to sign transactions.

Without these, the script would try to call `$VAULT` or `$WRAPPED` as literal strings and fail.

---

## Cast Output:

**`cast send`** - Sends a transaction and prints the **transaction receipt** (block and tx metadata), not the return data. Example from `burn(uint256)`:

```
blockHash            0x1f49f6d97ce008e43a467e9b29679281ede315527b13f4b95acc0a88cb9cdb28
blockNumber          167
cumulativeGasUsed    28074
effectiveGasPrice    8
from                 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
gasUsed              28074
status               1 (success)
transactionHash      0xf496d13bf6f68bf111f572b3bb7aa1dc50ccf882323354c1c9c3903e7047e74d
to                   0x5FbDB2315678afecb367f032d93F642f64180aa3
logs                 [{"address":"...", "topics":["0xddf252ad...","0x000...92266","0x0..."],"data":"0x000...00000", ...}, {"address":"...", "topics":["0xcc16f5db...","0x000...92266"],"data":"0x000...00000", ...}]
...
```

- **status 1** - Tx succeeded.
- **logs** - Event logs (here: `Transfer` to zero address and `Burn`).
- **transactionHash** - Use for verification or relayer processing.

**`cast call`** - Simulates a call and prints the **return value** of the function (e.g. `balanceOf` → raw uint256). The script pipes this through `cast --to-unit {} ether` to display human-readable amounts like `100.0`.

---

## Architecture: Tools and Components

### Which Tools Are Used and Why? 

This project uses Foundry, which is a fast, Rust-based toolkit for Ethereum development that supports building, testing, and running local blockchain environments. Compared to full clients like Geth, Foundry enables lightweight, in-memory simulation of the Ethereum Virtual Machine (EVM) without the overhead of syncing or maintaining a full node. For contract development and deployment, Hardhat is used due to its flexible scripting and JavaScript-based workflow.

### Chains

For the chains, we use Anvil Docker containers. Anvil is a lightweight local Ethereum node from Foundry that simulates an Ethereum Virtual Machine (EVM) in memory. It exposes standard JSON-RPC endpoints (see next section), making it compatible with tools like Hardhat and ethers.js, and enables fast, deterministic testing of smart contracts. In this project, separate Anvil instances are used to represent independent chains for simulating cross-chain interactions.

### JSON-RPC Protocol

JSON-RPC (Remote Procedure Call) is a protocol for sending JSON-formatted requests to a blockchain node over HTTP to facilitate interactions involving EVMs. Hardhat uses it to deploy compiled contracts by submitting transactions to the node, while the relayer uses it to poll for lock attestations and trigger mint transactions on the destination chain accordingly.

We expose the following ports for JSON-RPC interactions with the Anvil nodes:

- **chain-a** - Port 8545, source chain
- **chain-b** - Port 8547, destination chain

### Smart Contracts

| Contract                | Chain   | Role                                                               |
| ----------------------- | ------- | ------------------------------------------------------------------ |
| **Token (BRG)**         | chain-a | ERC-20; deployer gets 1M BRG                                       |
| **Vault**               | chain-a | Locks BRG via `deposit()`; releases via `release()` (relayer-only) |
| **WrappedToken (wBRG)** | chain-b | ERC-20; relayer can mint; anyone can burn; emits `Burn` for redeem |

### Relayer (Node.js)

- **Lock-and-mint:** Watches chain-a for `Deposit` events, waits 3 confirmations, calls `mint(recipient, amount)` on WrappedToken on chain-b
- **Burn-and-redeem:** Watches chain-b for `Burn` events, waits 3 confirmations, calls `release(burner, amount)` on Vault on chain-a

**Signers:** The relayer uses `signerA` and `signerB`, which are ethers `Wallet` instances with the relayer's private key, each connected to a different chain's provider. To _submit_ transactions (mint on chain-b, release on chain-a), the relayer must sign them; a provider-only connection is read-only. `vaultWithSigner` is the Vault contract connected to `signerA`, so the relayer can call `release()` on chain-a. The WrappedToken is connected to `signerB` for `mint()` on chain-b.

---

## Protocol Flow (Lock-and-Mint)

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
       │ 2. User: deposit(100)             │
       │ 3. Vault: transferFrom(user)      │
       │ 4. Vault: emit Deposit(user,100)  │
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

## Lock-and-Mint Protocol

**Lock (chain-a):** When the user calls `deposit(amount)`, the Vault uses `transferFrom` to pull BRG from the user into the Vault. This is atomic: either the full amount moves or the tx reverts. The Vault only emits `Deposit` after a successful transfer (Q-Bridge lesson: never emit before verifying).

**Mint (chain-b):** The relayer polls chain-a for `Deposit` events. For each event, it waits for 3 block confirmations (to reduce reorg risk), then calls `mint(recipient, amount)` on WrappedToken. Only the relayer (minter) can call `mint`.

**Trust model:** The relayer is trusted. It observes chain-a off-chain and submits mints on chain-b. There are no on-chain Merkle proofs or validator sets.

---

## Burn-and-Redeem Protocol (Reverse Flow)

The bridge also supports the reverse direction: burning wBRG on chain-b to redeem BRG from the Vault on chain-a.

```
┌─────────────┐                    ┌─────────────┐
│   chain-a   │                    │   chain-b   │
│  (source)   │                    │ (destination)│
├─────────────┤                    ├─────────────┤
│ Token (BRG) │                    │ WrappedToken │
│ Vault       │                    │ (wBRG)       │
└──────▲──────┘                    └──────┬──────┘
       │                                  │
       │ 4. Relayer: release(user, 100)    │
       │ 5. Vault: transfer(user)          │
       │                                  │
       │         ┌─────────────┐          │
       └─────────│   Relayer   │◄─────────┘
                 │ (off-chain)  │  1. User: burn(100)
                 │ polls Burns │  2. WrappedToken: Burn(user, 100)
                 └─────────────┘
```

1. User calls `burn(amount)` on WrappedToken on chain-b.
2. WrappedToken burns the user's wBRG and emits `Burn(from, amount)`.
3. Relayer watches chain-b for `Burn` events, waits for 3 confirmations.
4. Relayer calls `release(burner, amount)` on Vault on chain-a.
5. Vault transfers BRG from its locked balance back to the user.

**Vault:** The Vault holds a `releaser` address (the relayer). Only the releaser can call `release(to, amount)` to send BRG back to users when they burn wBRG.

---

## Confirmations

**What they are:** When a transaction is mined in block N, "confirmations" is the number of blocks produced _after_ block N. Example: tx in block 78, current block 81 → 3 confirmations.

**How the relayer computes them:** Ethereum has no RPC like `eth_getConfirmations(txHash)`. Confirmations are derived from block heights: the relayer reads the event's block number (from the log) and the chain's latest block (`eth_blockNumber`), then does `confirmations = currentBlock - eventBlockNumber`. It's arithmetic on two integers the chain reports—no separate "confirmation" API.

**Why wait:** Blocks can be reorganized; a recent block might be dropped. Waiting a few confirmations (e.g. 3) lowers the chance we mint or release for an event that later gets reverted.

---

## Double-Spending Prevention

**On chain-a (source):** Double-spending is prevented by the Token contract. Each `deposit` uses `transferFrom`, which deducts from the user's balance. A user cannot deposit more BRG than they hold. If they try to deposit 100 twice with only 100 balance, the second tx reverts.

**On chain-b (destination):** The relayer maintains a `processed` set keyed by `transactionHash-logIndex`. Each `Deposit` event has a unique (tx hash, log index). Once the relayer mints for that event, it adds the key to `processed` and never mints again for the same event. This prevents double-minting from the same Deposit.

**Note:** The WrappedToken contract does not track which deposits have been minted. Double-mint prevention is off-chain (relayer's `processed` set). A malicious relayer could mint without a corresponding deposit; this project assumes a trusted relayer.

---

## Nonces

**Deployment:** The deploy script uses explicit nonce tracking when deploying multiple contracts from the same account in quick succession. Without it, concurrent deploys can hit "nonce too low" errors. The script passes `nonceA++` and `nonceB++` to ensure each deploy tx has the correct nonce.

**Bridge logic:** The bridge itself does not use nonces. Each user `deposit` and each relayer `mint` is a normal transaction; the EVM assigns nonces automatically per account. The Token, Vault, and WrappedToken contracts do not implement nonce-based replay protection. Replay protection comes from (1) the relayer's `processed` set and (2) the fact that each Deposit is a distinct on-chain event.
