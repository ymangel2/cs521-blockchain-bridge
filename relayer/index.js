#!/usr/bin/env node
/**
 * Bridge relayer (submitter only)
 *
 * After Deposit / Burn finality, waits for 2-of-3 validator signature files under
 * relayer/attestations/{deposit|burn}/<txHash>_<logIndex>/v{i}.sig, then submits
 * mintWithAttestation / releaseWithAttestation.
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const CONFIRMATION_BLOCKS = parseInt(process.env.CONFIRMATION_BLOCKS || "3", 10);
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || "2000", 10);

const ANVIL_NETWORK = ethers.Network.from(31337);

const VAULT_ABI = [
  "event Deposit(address indexed sender, uint256 amount, uint256 indexed destChainId, uint256 blockNumber)",
  "function releaseWithAttestation(address to,uint256 amount,bytes32 burnTxHash,uint256 logIndex,bytes[] signatures,address[] signers) external",
];
const WRAPPED_TOKEN_ABI = [
  "function mintWithAttestation(address to,uint256 amount,bytes32 depositTxHash,uint256 logIndex,bytes[] signatures,address[] signers) external",
  "event Burn(address indexed from, uint256 amount)",
];

function attestationsRoot() {
  return process.env.ATTESTATIONS_DIR || path.join(__dirname, "attestations");
}

function loadAttestationBundle(kind, txHash, logIndex, threshold, validators) {
  const dir = path.join(attestationsRoot(), kind, `${txHash}_${logIndex}`);
  if (!fs.existsSync(dir)) return null;

  const entries = [];
  for (let i = 0; i < validators.length; i++) {
    const fp = path.join(dir, `v${i}.sig`);
    if (!fs.existsSync(fp)) continue;
    const sig = fs.readFileSync(fp, "utf8").trim();
    if (!sig.startsWith("0x") || sig.length < 130) continue;
    entries.push({ index: i, signature: sig, address: validators[i].address });
  }
  if (entries.length < threshold) return null;

  entries.sort((a, b) => a.index - b.index);
  const chosen = entries.slice(0, threshold);
  return {
    signatures: chosen.map((e) => e.signature),
    signers: chosen.map((e) => e.address),
  };
}

/** How many valid v*.sig files exist (for clearer logs). */
function countValidSigFiles(kind, txHash, logIndex, validators) {
  const dir = path.join(attestationsRoot(), kind, `${txHash}_${logIndex}`);
  if (!fs.existsSync(dir)) return 0;
  let n = 0;
  for (let i = 0; i < validators.length; i++) {
    const fp = path.join(dir, `v${i}.sig`);
    if (!fs.existsSync(fp)) continue;
    const sig = fs.readFileSync(fp, "utf8").trim();
    if (!sig.startsWith("0x") || sig.length < 130) continue;
    n++;
  }
  return n;
}

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
          if (
            config.chainA?.vault &&
            config.chainB?.wrappedToken &&
            config.validators?.length === 3 &&
            config.threshold >= 1
          ) {
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
  const { chainA, chainB, relayer, validators, threshold } = config;

  const providerA = new ethers.JsonRpcProvider(chainA.rpc, ANVIL_NETWORK, { staticNetwork: ANVIL_NETWORK });
  const providerB = new ethers.JsonRpcProvider(chainB.rpc, ANVIL_NETWORK, { staticNetwork: ANVIL_NETWORK });
  const signerA = new ethers.Wallet(relayer.privateKey, providerA);
  const signerB = new ethers.Wallet(relayer.privateKey, providerB);

  const vault = new ethers.Contract(chainA.vault, VAULT_ABI, providerA);
  const vaultWithSigner = new ethers.Contract(chainA.vault, VAULT_ABI, signerA);
  const wrappedToken = new ethers.Contract(chainB.wrappedToken, WRAPPED_TOKEN_ABI, signerB);

  const processedDeposits = new Set();
  const processedBurns = new Set();

  console.log("Bridge relayer started (attestation submitter)");
  console.log(`  Source (chain-a): ${chainA.rpc}`);
  console.log(`  Destination (chain-b): ${chainB.rpc}`);
  console.log(`  Vault: ${chainA.vault}`);
  console.log(`  WrappedToken: ${chainB.wrappedToken}`);
  console.log(`  Attestations: ${attestationsRoot()}`);
  console.log(`  Confirmations: ${CONFIRMATION_BLOCKS}  threshold: ${threshold}`);
  console.log("");

  async function processDeposit(depositEvent) {
    const logIndex = depositEvent.logIndex ?? depositEvent.index;
    const key = `deposit:${depositEvent.transactionHash}-${logIndex}`;
    if (processedDeposits.has(key)) return;

    try {
      const sender = depositEvent.args[0];
      const amount = depositEvent.args[1];
      const blockNumber = Number(depositEvent.args[3]);

      const currentBlock = await providerA.getBlockNumber();
      const confirmations = currentBlock - blockNumber;
      if (confirmations < CONFIRMATION_BLOCKS) {
        console.log(
          `  Deposit ${amount} from ${sender} at block ${blockNumber} — waiting ${CONFIRMATION_BLOCKS - confirmations} more confirmations`
        );
        return;
      }

      const bundle = loadAttestationBundle(
        "deposit",
        depositEvent.transactionHash,
        logIndex,
        threshold,
        validators
      );
      if (!bundle) {
        const have = countValidSigFiles("deposit", depositEvent.transactionHash, logIndex, validators);
        console.log(
          `  Deposit ${depositEvent.transactionHash} log ${logIndex} — attestations ${have}/${threshold} (need ${threshold} distinct v*.sig files; start validators with VALIDATOR_INDEX=0,1,2)`
        );
        return;
      }

      try {
        const tx = await wrappedToken.mintWithAttestation(
          sender,
          amount,
          depositEvent.transactionHash,
          logIndex,
          bundle.signatures,
          bundle.signers
        );
        await tx.wait();
        processedDeposits.add(key);
        console.log(`  MINTED ${ethers.formatEther(amount)} wBRG to ${sender} (tx: ${tx.hash})`);
      } catch (err) {
        if (/deposit already minted|WrappedToken: deposit already minted/i.test(err.message || "")) {
          processedDeposits.add(key);
          console.log(`  Mint already recorded for deposit ${depositEvent.transactionHash} log ${logIndex}`);
        } else {
          console.error(`  mintWithAttestation failed: ${err.message}`);
        }
      }
    } catch (err) {
      console.error(`  processDeposit error: ${err.message}`);
    }
  }

  async function processBurn(burnEvent) {
    const logIndex = burnEvent.logIndex ?? burnEvent.index;
    const key = `burn:${burnEvent.transactionHash}-${logIndex}`;
    if (processedBurns.has(key)) return;

    try {
      const burner = burnEvent.args[0];
      const amount = burnEvent.args[1];
      const blockNumber = Number(burnEvent.blockNumber);

      const currentBlock = await providerB.getBlockNumber();
      const confirmations = currentBlock - blockNumber;
      if (confirmations < CONFIRMATION_BLOCKS) {
        console.log(
          `  Burn ${amount} from ${burner} at block ${blockNumber} — waiting ${CONFIRMATION_BLOCKS - confirmations} more confirmations`
        );
        return;
      }

      const bundle = loadAttestationBundle("burn", burnEvent.transactionHash, logIndex, threshold, validators);
      if (!bundle) {
        const have = countValidSigFiles("burn", burnEvent.transactionHash, logIndex, validators);
        console.log(
          `  Burn ${burnEvent.transactionHash} log ${logIndex} — attestations ${have}/${threshold} (need ${threshold} distinct v*.sig files; start validators with VALIDATOR_INDEX=0,1,2)`
        );
        return;
      }

      try {
        const tx = await vaultWithSigner.releaseWithAttestation(
          burner,
          amount,
          burnEvent.transactionHash,
          logIndex,
          bundle.signatures,
          bundle.signers
        );
        await tx.wait();
        processedBurns.add(key);
        console.log(`  RELEASED ${ethers.formatEther(amount)} BRG to ${burner} (tx: ${tx.hash})`);
      } catch (err) {
        if (/burn already released|Vault: burn already released/i.test(err.message || "")) {
          processedBurns.add(key);
          console.log(`  Release already recorded for burn ${burnEvent.transactionHash} log ${logIndex}`);
        } else {
          console.error(`  releaseWithAttestation failed: ${err.message}`);
        }
      }
    } catch (err) {
      console.error(`  processBurn error: ${err.message}`);
    }
  }

  async function pollDeposits() {
    try {
      const currentBlock = await providerA.getBlockNumber();
      const fromBlock = Math.max(0, currentBlock - 50);
      const events = await vault.queryFilter(vault.filters.Deposit(), fromBlock, currentBlock);
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
      const events = await wrapped.queryFilter(wrapped.filters.Burn(), fromBlock, currentBlock);
      for (const e of events) {
        await processBurn(e);
      }
    } catch (err) {
      console.error("Burn poll error:", err.message);
    }
  }

  const toBlockA = await providerA.getBlockNumber();
  for (const e of await vault.queryFilter(vault.filters.Deposit(), 0, toBlockA)) {
    await processDeposit(e);
  }

  const wrappedRead = new ethers.Contract(chainB.wrappedToken, WRAPPED_TOKEN_ABI, providerB);
  const toBlockB = await providerB.getBlockNumber();
  for (const e of await wrappedRead.queryFilter(wrappedRead.filters.Burn(), 0, toBlockB)) {
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
