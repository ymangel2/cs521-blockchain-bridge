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
  "function release(address to, uint256 amount) external",
];
const WRAPPED_TOKEN_ABI = [
  "function mint(address to, uint256 amount) external",
  "event Burn(address indexed from, uint256 amount)",
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
  const signerA = new ethers.Wallet(relayer.privateKey, providerA);
  const signerB = new ethers.Wallet(relayer.privateKey, providerB);

  const vault = new ethers.Contract(chainA.vault, VAULT_ABI, providerA);
  const vaultWithSigner = new ethers.Contract(chainA.vault, VAULT_ABI, signerA);
  const wrappedToken = new ethers.Contract(
    chainB.wrappedToken,
    WRAPPED_TOKEN_ABI,
    signerB
  );

  const processedDeposits = new Set();
  const processedBurns = new Set();

  console.log("Bridge Relayer started");
  console.log(`  Source (chain-a): ${chainA.rpc}`);
  console.log(`  Destination (chain-b): ${chainB.rpc}`);
  console.log(`  Vault: ${chainA.vault}`);
  console.log(`  WrappedToken: ${chainB.wrappedToken}`);
  console.log(`  Confirmations: ${CONFIRMATION_BLOCKS}`);
  console.log("");

  async function processDeposit(depositEvent) {
    const logIndex = depositEvent.logIndex ?? depositEvent.index;
    const key = `deposit:${depositEvent.transactionHash}-${logIndex}`;
    if (processedDeposits.has(key)) return;
    processedDeposits.add(key);

    try {
      const sender = depositEvent.args[0];
      const amount = depositEvent.args[1];
      const blockNumber = Number(depositEvent.args[3]);

      const currentBlock = await providerA.getBlockNumber();
      const confirmations = currentBlock - blockNumber;
      if (confirmations < CONFIRMATION_BLOCKS) {
        processedDeposits.delete(key);
        console.log(
          `  Deposit ${amount} from ${sender} at block ${blockNumber} - waiting for ${CONFIRMATION_BLOCKS - confirmations} more confirmations`
        );
        return;
      }

      try {
        const tx = await wrappedToken.mint(sender, amount);
        await tx.wait();
        console.log(
          `  MINTED ${ethers.formatEther(amount)} wBRG to ${sender} (tx: ${tx.hash})`
        );
      } catch (err) {
        const duplicateTx = /already imported|replacement transaction/i.test(err.message);
        if (duplicateTx) {
          console.log(`  Mint already applied for ${sender} (duplicate tx ignored)`);
        } else {
          console.error(`  Mint failed for ${sender}: ${err.message}`);
          processedDeposits.delete(key);
        }
      }
    } catch (err) {
      processedDeposits.delete(key);
      throw err;
    }
  }

  async function processBurn(burnEvent) {
    const logIndex = burnEvent.logIndex ?? burnEvent.index;
    const key = `burn:${burnEvent.transactionHash}-${logIndex}`;
    if (processedBurns.has(key)) return;
    processedBurns.add(key);

    try {
      const burner = burnEvent.args[0];
      const amount = burnEvent.args[1];
      const blockNumber = Number(burnEvent.blockNumber);

      const currentBlock = await providerB.getBlockNumber();
      const confirmations = currentBlock - blockNumber;
      if (confirmations < CONFIRMATION_BLOCKS) {
        processedBurns.delete(key);
        console.log(
          `  Burn ${amount} from ${burner} at block ${blockNumber} - waiting for ${CONFIRMATION_BLOCKS - confirmations} more confirmations`
        );
        return;
      }

      try {
        const tx = await vaultWithSigner.release(burner, amount);
        await tx.wait();
        console.log(
          `  RELEASED ${ethers.formatEther(amount)} BRG to ${burner} (tx: ${tx.hash})`
        );
      } catch (err) {
        const duplicateTx = /already imported|replacement transaction/i.test(err.message);
        if (duplicateTx) {
          console.log(`  Release already applied for ${burner} (duplicate tx ignored)`);
        } else {
          console.error(`  Release failed for ${burner}: ${err.message}`);
          processedBurns.delete(key);
        }
      }
    } catch (err) {
      processedBurns.delete(key);
      throw err;
    }
  }

  async function pollDeposits() {
    try {
      const currentBlock = await providerA.getBlockNumber();
      const fromBlock = Math.max(0, currentBlock - 50);
      const filter = vault.filters.Deposit();
      const events = await vault.queryFilter(filter, fromBlock, currentBlock);
      for (const e of events) {
        await processDeposit(e);
      }
    } catch (err) {
      console.error("Deposit poll error:", err.message);
    }
  }

  async function pollBurns() {
    try {
      const wrapped = new ethers.Contract(chainB.wrappedToken, WRAPPED_TOKEN_ABI, providerB);
      const currentBlock = await providerB.getBlockNumber();
      const fromBlock = Math.max(0, currentBlock - 50);
      const filter = wrapped.filters.Burn();
      const events = await wrapped.queryFilter(filter, fromBlock, currentBlock);
      for (const e of events) {
        await processBurn(e);
      }
    } catch (err) {
      console.error("Burn poll error:", err.message);
    }
  }

  // Process historical Deposit events (from block 0 in case we missed any)
  const toBlockA = await providerA.getBlockNumber();
  const historicalDeposits = await vault.queryFilter(vault.filters.Deposit(), 0, toBlockA);
  for (const e of historicalDeposits) {
    await processDeposit(e);
  }

  // Process historical Burn events
  const wrappedRead = new ethers.Contract(chainB.wrappedToken, WRAPPED_TOKEN_ABI, providerB);
  const toBlockB = await providerB.getBlockNumber();
  const historicalBurns = await wrappedRead.queryFilter(wrappedRead.filters.Burn(), 0, toBlockB);
  for (const e of historicalBurns) {
    await processBurn(e);
  }

  setInterval(pollDeposits, POLL_INTERVAL_MS);
  setInterval(pollBurns, POLL_INTERVAL_MS);
  console.log("Polling for Deposit (chain-a) and Burn (chain-b) events...\n");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
