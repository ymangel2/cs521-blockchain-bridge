#!/usr/bin/env node
/**
 * Validator process: polls Deposit (chain-a) or Burn (chain-b), waits for confirmations,
 * signs the attestation digest, writes relayer/attestations/<kind>/<txHash>_<logIndex>/v<INDEX>.sig
 *
 * Run one process per validator, e.g.:
 *   VALIDATOR_INDEX=0 node validator.js
 *   VALIDATOR_INDEX=1 node validator.js
 *   VALIDATOR_INDEX=2 node validator.js
 *
 * From repo root with local RPC (not inside Docker unless CHAIN_* set):
 *   CHAIN_A_RPC=http://127.0.0.1:8545 CHAIN_B_RPC=http://127.0.0.1:8547 VALIDATOR_INDEX=0 node relayer/validator.js
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { depositDigest, burnDigest, signDigest } = require("./attestationCrypto");

const CONFIRMATION_BLOCKS = parseInt(process.env.CONFIRMATION_BLOCKS || "3", 10);
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || "2000", 10);
const POLL_LOOKBACK = (() => {
  const v = process.env.POLL_LOOKBACK;
  if (v === undefined || v === "") return 0;
  const n = parseInt(v, 10);
  return Number.isFinite(n) && n >= 0 ? n : 0;
})();
function pollFrom(currentBlock) {
  if (POLL_LOOKBACK === 0) return 0;
  return Math.max(0, currentBlock - POLL_LOOKBACK);
}

const VAULT_ABI = [
  "event Deposit(address indexed sender, uint256 amount, uint256 indexed destChainId, uint256 blockNumber)",
];
const WRAPPED_ABI = ["event Burn(address indexed from, uint256 amount)"];

function loadConfig() {
  const configPath = path.join(__dirname, "config.json");
  const raw = fs.readFileSync(configPath, "utf8");
  const config = JSON.parse(raw);
  if (process.env.CHAIN_A_RPC) config.chainA.rpc = process.env.CHAIN_A_RPC;
  if (process.env.CHAIN_B_RPC) config.chainB.rpc = process.env.CHAIN_B_RPC;
  return config;
}

function attestDir() {
  return process.env.ATTESTATIONS_DIR || path.join(__dirname, "attestations");
}

function main() {
  const idx = parseInt(process.env.VALIDATOR_INDEX || "0", 10);
  if (idx < 0 || idx > 2) {
    console.error("VALIDATOR_INDEX must be 0, 1, or 2");
    process.exit(1);
  }

  const config = loadConfig();
  const validators = config.validators;
  if (!validators || validators.length !== 3) {
    console.error("config.json must include validators[3] with address and privateKey");
    process.exit(1);
  }
  const me = validators[idx];
  const sourceChainId = config.chainA.chainId ?? 31337;
  const destChainId = config.chainB.chainId ?? 31337;
  const netA = ethers.Network.from(Number(sourceChainId));
  const netB = ethers.Network.from(Number(destChainId));

  const providerA = new ethers.JsonRpcProvider(config.chainA.rpc, netA, { staticNetwork: netA });
  const providerB = new ethers.JsonRpcProvider(config.chainB.rpc, netB, { staticNetwork: netB });
  const vault = new ethers.Contract(config.chainA.vault, VAULT_ABI, providerA);
  const wrapped = new ethers.Contract(config.chainB.wrappedToken, WRAPPED_ABI, providerB);

  const processedDeposits = new Set();
  const processedBurns = new Set();
  const base = attestDir();

  console.log(`Validator ${idx} (${me.address}) started`);
  console.log(`  Attestations dir: ${base}`);
  console.log(`  chain-a: ${config.chainA.rpc}  chain-b: ${config.chainB.rpc}`);

  function writeSig(kind, txHash, logIndex, signatureHex) {
    const sub = path.join(base, kind, `${txHash}_${logIndex}`);
    fs.mkdirSync(sub, { recursive: true });
    const fp = path.join(sub, `v${idx}.sig`);
    fs.writeFileSync(fp, signatureHex + "\n", "utf8");
    console.log(`  [validator ${idx}] wrote ${fp}`);
  }

  async function handleDeposit(ev) {
    const logIndex = ev.logIndex ?? ev.index;
    const key = `d:${ev.transactionHash}-${logIndex}`;
    if (processedDeposits.has(key)) return;

    const sender = ev.args[0];
    const amount = ev.args[1];
    const blockNumber = Number(ev.args[3]);
    const cur = await providerA.getBlockNumber();
    if (cur - blockNumber < CONFIRMATION_BLOCKS) return;

    processedDeposits.add(key);
    const digest = depositDigest(
      sourceChainId,
      config.chainA.vault,
      ev.transactionHash,
      logIndex,
      sender,
      amount
    );
    const sig = signDigest(me.privateKey, digest);
    writeSig("deposit", ev.transactionHash, logIndex, sig);
  }

  async function handleBurn(ev) {
    const logIndex = ev.logIndex ?? ev.index;
    const key = `b:${ev.transactionHash}-${logIndex}`;
    if (processedBurns.has(key)) return;

    const burner = ev.args[0];
    const amount = ev.args[1];
    const blockNumber = Number(ev.blockNumber);
    const cur = await providerB.getBlockNumber();
    if (cur - blockNumber < CONFIRMATION_BLOCKS) return;

    processedBurns.add(key);
    const digest = burnDigest(
      destChainId,
      config.chainB.wrappedToken,
      ev.transactionHash,
      logIndex,
      burner,
      amount
    );
    const sig = signDigest(me.privateKey, digest);
    writeSig("burn", ev.transactionHash, logIndex, sig);
  }

  async function poll() {
    try {
      const curA = await providerA.getBlockNumber();
      const fromA = pollFrom(curA);
      const deps = await vault.queryFilter(vault.filters.Deposit(), fromA, curA);
      for (const e of deps) await handleDeposit(e);

      const curB = await providerB.getBlockNumber();
      const fromB = pollFrom(curB);
      const burns = await wrapped.queryFilter(wrapped.filters.Burn(), fromB, curB);
      for (const e of burns) await handleBurn(e);
    } catch (err) {
      console.error("Validator poll error:", err.message);
    }
  }

  poll().then(() => {
    setInterval(poll, POLL_INTERVAL_MS);
    console.log("Polling for Deposit / Burn...\n");
  });
}

main();
