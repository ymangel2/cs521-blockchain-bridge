#!/usr/bin/env node
/**
 * Bridge Relayer
 *
 * Monitors the source chain (chain-a) for Deposit events emitted by the Vault.
 * After waiting for CONFIRMATION_BLOCKS to mitigate 51% reorg risk, submits a
 * mint transaction to the WrappedToken contract on the destination chain (chain-b).
 *
 * Trust model: Off-chain verification. The relayer trusts its own observation
 * of the chain state (no on-chain Merkle proofs). Suitable for a simplified
 * course project.
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const CONFIRMATION_BLOCKS = parseInt(process.env.CONFIRMATION_BLOCKS || "3", 10);
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || "2000", 10);

const ANVIL_NETWORK = ethers.Network.from(31337);

const VAULT_ABI = [
  "event Deposit(address indexed sender, uint256 amount, uint256 indexed destChainId, uint256 blockNumber)",
];
const WRAPPED_TOKEN_ABI = [
  "function mint(address to, uint256 amount) external",
];

async function loadConfig() {
  const configPath = path.join(__dirname, "config.json");
  const chainARpc = process.env.CHAIN_A_RPC || "http://chain-a:8545";
  const providerA = new ethers.JsonRpcProvider(chainARpc, ANVIL_NETWORK, { staticNetwork: ANVIL_NETWORK });

  for (let i = 0; i < 90; i++) {
    if (fs.existsSync(configPath)) {
      const raw = fs.readFileSync(configPath, "utf8").trim();
      if (raw) {
        try {
          const config = JSON.parse(raw);
          if (config.chainA?.vault && config.chainB?.wrappedToken) {
            const code = await providerA.getCode(config.chainA.vault);
            if (code && code !== "0x") {
              if (process.env.CHAIN_A_RPC) config.chainA.rpc = process.env.CHAIN_A_RPC;
              if (process.env.CHAIN_B_RPC) config.chainB.rpc = process.env.CHAIN_B_RPC;
              return config;
            }
          }
        } catch (_) {}
      }
    }
    if (i === 0) console.log("Waiting for config (run: npm run deploy)...");
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error(`Config not found or vault not deployed. Run 'npm run deploy' first.`);
}

async function main() {
  const config = await loadConfig();
  const { chainA, chainB, relayer } = config;

  const providerA = new ethers.JsonRpcProvider(chainA.rpc, ANVIL_NETWORK, { staticNetwork: ANVIL_NETWORK });
  const providerB = new ethers.JsonRpcProvider(chainB.rpc, ANVIL_NETWORK, { staticNetwork: ANVIL_NETWORK });
  const signer = new ethers.Wallet(relayer.privateKey, providerB);

  const vault = new ethers.Contract(chainA.vault, VAULT_ABI, providerA);
  const wrappedToken = new ethers.Contract(
    chainB.wrappedToken,
    WRAPPED_TOKEN_ABI,
    signer
  );

  const processed = new Set();

  console.log("Bridge Relayer started");
  console.log(`  Source (chain-a): ${chainA.rpc}`);
  console.log(`  Destination (chain-b): ${chainB.rpc}`);
  console.log(`  Vault: ${chainA.vault}`);
  console.log(`  WrappedToken: ${chainB.wrappedToken}`);
  console.log(`  Confirmations: ${CONFIRMATION_BLOCKS}`);
  console.log("");

  async function processDeposit(depositEvent) {
    const key = `${depositEvent.transactionHash}-${depositEvent.logIndex}`;
    if (processed.has(key)) return;

    const sender = depositEvent.args[0];
    const amount = depositEvent.args[1];
    const blockNumber = Number(depositEvent.args[3]);

    const currentBlock = await providerA.getBlockNumber();
    const confirmations = currentBlock - blockNumber;
    if (confirmations < CONFIRMATION_BLOCKS) {
      console.log(
        `  Deposit ${amount} from ${sender} at block ${blockNumber} - waiting for ${CONFIRMATION_BLOCKS - confirmations} more confirmations`
      );
      return;
    }

    processed.add(key);
    try {
      const tx = await wrappedToken.mint(sender, amount);
      await tx.wait();
      console.log(
        `  MINTED ${ethers.formatEther(amount)} wBRG to ${sender} (tx: ${tx.hash})`
      );
    } catch (err) {
      console.error(`  Mint failed for ${sender}: ${err.message}`);
      processed.delete(key);
    }
  }

  async function poll() {
    try {
      const currentBlock = await providerA.getBlockNumber();
      const fromBlock = Math.max(0, currentBlock - 50);
      const filter = vault.filters.Deposit();
      const events = await vault.queryFilter(filter, fromBlock, currentBlock);
      for (const e of events) {
        await processDeposit(e);
      }
    } catch (err) {
      console.error("Poll error:", err.message);
    }
  }

  // Process historical Deposit events (from block 0 in case we missed any)
  const toBlock = await providerA.getBlockNumber();
  const historicalFilter = vault.filters.Deposit();
  const historical = await vault.queryFilter(historicalFilter, 0, toBlock);
  for (const e of historical) {
    await processDeposit(e);
  }

  setInterval(poll, POLL_INTERVAL_MS);
  console.log("Polling for new Deposit events...\n");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
