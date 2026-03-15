# Topic 14: Blockchain Bridges and Cross-Chain Communication

### Coding project: Implement a simplified bridge between two local test chains that locks tokens on one chain and mints wrapped tokens on the other, using a relayer to pass attestations.

## Quick Start

```bash
npm install && npx hardhat compile
docker compose up -d --build
npm run deploy
# Load env and run demo (see scripts/demo-bridge.sh and ARCHITECTURE.md)
```

See [MANUAL_TESTING.md](MANUAL_TESTING.md) for detailed steps and expected output.

**How the relayer works:** The relayer continuously polls chain-a for `Deposit` events from the Vault. When it sees a deposit with enough confirmations (3 blocks), it mints the corresponding wBRG to the user on chain-b. No restart is required—the relayer reacts to on-chain events in real time. The `--build` flag ensures the relayer runs the latest code.
