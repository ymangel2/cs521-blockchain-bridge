#!/usr/bin/env node
/**
 * Concurrent bridge load test: N distinct HD wallets each do approve → deposit (parallel),
 * wait for all mints, burn (parallel), wait for all releases.
 *
 * Prerequisites: docker chain-a/b + relayer, npm run deploy, three validators (0,1,2).
 *
 * Env:
 *   CONCURRENCY   — number of parallel users (default 2). Wallets use HD indices INDEX_START..INDEX_START+N-1.
 *   AMOUNT        — wei per deposit/burn (default 100 BRG = 100e18).
 *   INDEX_START   — first HD account index (default 20; avoids deployer 0, validators 1–3, demo user 1).
 *   CHAIN_A_RPC, CHAIN_B_RPC — optional (default localhost 8545 / 8547).
 *   TIMEOUT_MS      — default 1_200_000 (20 min) for wBRG/release waits at high CONCURRENCY.
 *
 * Usage:
 *   CONCURRENCY=5 node scripts/throughput-concurrent.js
 *
 * Throughput (report):
 *   • "burn_span": N / (t_last_burn_confirmed − t_first_deposit_submitted) — your requested definition.
 *   • "full_round_trip": N / (t_last_release_observed − t_first_deposit_submitted) — includes relayer release.
 *
 * Gas: sums user txs (approve, deposit, burn) + finds mint/release receipts via events (best-effort).
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const MNEMONIC = "test test test test test test test test test test test junk";

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
];
const VAULT_ABI = ["function deposit(uint256)"];
const WRAPPED_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function burn(uint256)",
  "event Mint(address indexed to, uint256 amount)",
];
const TOKEN_TRANSFER_ABI = ["event Transfer(address indexed from, address indexed to, uint256 value)"];
const TOKEN_READ_ABI = [...ERC20_ABI, ...TOKEN_TRANSFER_ABI];

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function walletAt(index) {
  const m = ethers.Mnemonic.fromPhrase(MNEMONIC);
  return ethers.HDNodeWallet.fromMnemonic(m, `m/44'/60'/0'/0/${index}`);
}

function loadConfig() {
  const p = path.join(__dirname, "..", "relayer", "config.json");
  const c = JSON.parse(fs.readFileSync(p, "utf8"));
  if (process.env.CHAIN_A_RPC) c.chainA.rpc = process.env.CHAIN_A_RPC;
  if (process.env.CHAIN_B_RPC) c.chainB.rpc = process.env.CHAIN_B_RPC;
  return c;
}

async function waitUntil(pollMs, timeoutMs, pred) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (await pred()) return;
    await sleep(pollMs);
  }
  throw new Error(`waitUntil timeout after ${timeoutMs}ms`);
}

async function main() {
  const CONCURRENCY = Math.max(1, parseInt(process.env.CONCURRENCY || "2", 10));
  const AMOUNT = BigInt(process.env.AMOUNT || "100000000000000000000");
  const INDEX_START = parseInt(process.env.INDEX_START || "20", 10);
  const POLL_MS = parseInt(process.env.POLL_MS || "1000", 10);
  /* Large N + serial relayer mints: allow long wall time (override with TIMEOUT_MS). */
  const TIMEOUT_MS = parseInt(process.env.TIMEOUT_MS || "1200000", 10);

  const net = ethers.Network.from(31337);
  const config = loadConfig();
  const { chainA, chainB, relayer } = config;

  const providerA = new ethers.JsonRpcProvider(chainA.rpc, net, { staticNetwork: net });
  const providerB = new ethers.JsonRpcProvider(chainB.rpc, net, { staticNetwork: net });
  const deployerA = new ethers.Wallet(relayer.privateKey, providerA);
  const deployerB = new ethers.Wallet(relayer.privateKey, providerB);

  const tokenA = new ethers.Contract(chainA.token, ERC20_ABI, deployerA);
  const tokenRead = new ethers.Contract(chainA.token, TOKEN_READ_ABI, providerA);
  const vaultA = new ethers.Contract(chainA.vault, VAULT_ABI, deployerA);
  const wrappedB = new ethers.Contract(chainB.wrappedToken, WRAPPED_ABI, deployerB);

  const workers = [];
  for (let i = 0; i < CONCURRENCY; i++) {
    const idx = INDEX_START + i;
    const hd = walletAt(idx);
    workers.push({
      index: idx,
      address: hd.address,
      a: hd.connect(providerA),
      b: hd.connect(providerB),
    });
  }

  console.log(`Concurrent throughput: N=${CONCURRENCY}  AMOUNT=${AMOUNT} wei  HD indices ${INDEX_START}..${INDEX_START + CONCURRENCY - 1}`);
  console.log(`chain-a: ${chainA.rpc}  chain-b: ${chainB.rpc}\n`);

  /* Fund ETH (indices ≥10 may be empty on default Anvil) + BRG — batched w/ explicit nonces (parallel), not one-by-one. */
  const ethTopUp = ethers.parseEther("2");
  const brgFund = AMOUNT * 20n;
  const minEth = ethers.parseEther("0.05");
  const minBrg = AMOUNT * 5n;
  const [ethABals, ethBBals, brgBals] = await Promise.all([
    Promise.all(workers.map((w) => providerA.getBalance(w.address))),
    Promise.all(workers.map((w) => providerB.getBalance(w.address))),
    Promise.all(workers.map((w) => tokenA.balanceOf(w.address))),
  ]);
  const needAEth = workers.filter((_, i) => ethABals[i] < minEth);
  const needBEth = workers.filter((_, i) => ethBBals[i] < minEth);
  const needBrg = workers.filter((_, i) => brgBals[i] < minBrg);
  if (needAEth.length + needBEth.length + needBrg.length > 0) {
    const parts = [];
    if (needAEth.length) parts.push(`${needAEth.length}×A-ETH`);
    if (needBEth.length) parts.push(`${needBEth.length}×B-ETH`);
    if (needBrg.length) parts.push(`${needBrg.length}×BRG`);
    console.log(`  Prefunding (${parts.join(" ")})…`);
  }
  async function sendNativeBatched(provider, wallet, addrs) {
    if (addrs.length === 0) return;
    let n = await provider.getTransactionCount(wallet.address, "pending");
    const pending = addrs.map((to) => {
      const nonce = n++;
      return wallet.sendTransaction({ to, value: ethTopUp, nonce });
    });
    const txs = await Promise.all(pending);
    await Promise.all(txs.map((t) => t.wait()));
  }
  await Promise.all([
    sendNativeBatched(providerA, deployerA, needAEth.map((w) => w.address)),
    sendNativeBatched(providerB, deployerB, needBEth.map((w) => w.address)),
  ]);
  if (needBrg.length) {
    let n = await providerA.getTransactionCount(deployerA.address, "pending");
    const pending = needBrg.map((w) => {
      const nonce = n++;
      return tokenA.transfer(w.address, brgFund, { nonce });
    });
    const txs = await Promise.all(pending);
    await Promise.all(txs.map((t) => t.wait()));
  }

  const snapshots = workers.map((w) => ({
    w,
    brg0: 0n,
    wbrg0: 0n,
    approveGas: 0n,
    depositGas: 0n,
    burnGas: 0n,
    mintGas: 0n,
    releaseGas: 0n,
    depositSubmittedMs: 0,
    depositMinedMs: 0,
    mintDoneMs: 0,
    burnSubmittedMs: 0,
    burnMinedMs: 0,
    releaseDoneMs: 0,
    depositBlock: 0,
    burnBlock: 0,
  }));

  for (const s of snapshots) {
    s.brg0 = await tokenA.balanceOf(s.w.address);
    s.wbrg0 = await wrappedB.balanceOf(s.w.address);
  }

  console.log("  Approve + deposit (chain A) — sending txs…");
  /* Phase: concurrent approve + deposit (deposit() broadcast times recorded) */
  await Promise.all(
    snapshots.map(async (s) => {
      const token = tokenA.connect(s.w.a);
      const vault = vaultA.connect(s.w.a);
      const cap = AMOUNT * 15n;
      const rec1 = await (await token.approve(vaultA.target, cap)).wait();
      s.approveGas = rec1.gasUsed;

      s.depositSubmittedMs = Date.now();
      const rec2 = await (await vault.deposit(AMOUNT)).wait();
      s.depositGas = rec2.gasUsed;
      s.depositMinedMs = Date.now();
      s.depositBlock = rec2.blockNumber;
    })
  );

  const firstDepositSubmittedMs = Math.min(...snapshots.map((s) => s.depositSubmittedMs));
  const tAfterDeposits = Date.now();
  console.log("  Deposits mined. Waiting for wBRG mints (Docker relayer + 2/3 validator sigs)…");
  console.log("    If this hangs: run `VALIDATOR_INDEX=0|1|2 node relayer/validator.js` in 3 terminals,");
  console.log("    and check `docker logs -f relayer` for the container relayer process.");

  /* Wait all mints */
  await Promise.all(
    snapshots.map(async (s) => {
      const target = s.wbrg0 + AMOUNT;
      const wrapped = wrappedB.connect(s.w.b);
      await waitUntil(POLL_MS, TIMEOUT_MS, async () => {
        const b = await wrapped.balanceOf(s.w.address);
        return b === target;
      });
      s.mintDoneMs = Date.now();

      const filter = wrappedB.filters.Mint(s.w.address);
      const curB = await providerB.getBlockNumber();
      const logs = await wrappedB.queryFilter(filter, s.depositBlock, curB);
      const inFlight = logs.filter((l) => l.blockNumber >= s.depositBlock);
      const last = inFlight[inFlight.length - 1];
      const txHash = last?.transactionHash ?? last?.log?.transactionHash;
      if (txHash) {
        const rec = await providerB.getTransactionReceipt(txHash);
        if (rec) s.mintGas = rec.gasUsed;
      }
    })
  );

  const tAfterMints = Date.now();
  console.log("  Mints done. burn() on chain B (parallel)…");

  /* Concurrent burns */
  await Promise.all(
    snapshots.map(async (s) => {
      const wrapped = wrappedB.connect(s.w.b);
      s.burnSubmittedMs = Date.now();
      const rec = await (await wrapped.burn(AMOUNT)).wait();
      s.burnGas = rec.gasUsed;
      s.burnMinedMs = Date.now();
      s.burnBlock = rec.blockNumber;
    })
  );

  const tLastBurn = Math.max(...snapshots.map((s) => s.burnMinedMs));
  console.log("  Burns mined. Waiting for BRG release on chain A (validators + relayer)…");

  /* Wait all releases (BRG back to pre-run per user) */
  await Promise.all(
    snapshots.map(async (s) => {
      await waitUntil(POLL_MS, TIMEOUT_MS, async () => {
        const b = await tokenA.balanceOf(s.w.address);
        return b === s.brg0;
      });
      s.releaseDoneMs = Date.now();

      const filter = tokenRead.filters.Transfer(chainA.vault, s.w.address);
      const cur = await providerA.getBlockNumber();
      const logs = await tokenRead.queryFilter(filter, s.burnBlock, cur);
      const ev = [...logs].reverse().find((e) => e.args.value === AMOUNT) ?? logs[logs.length - 1];
      const txHash = ev?.transactionHash ?? ev?.log?.transactionHash;
      if (txHash) {
        const rec = await providerA.getTransactionReceipt(txHash);
        if (rec) s.releaseGas = rec.gasUsed;
      }
    })
  );

  const tLastRelease = Math.max(...snapshots.map((s) => s.releaseDoneMs));

  /* Aggregate gas */
  const sum = (fn) => snapshots.reduce((a, s) => a + fn(s), 0n);
  const n = BigInt(CONCURRENCY);
  console.log("\n==================== RESULTS ====================");
  console.log(`First deposit submitted (earliest of N): ${firstDepositSubmittedMs}`);
  console.log(`Last burn confirmed (latest of N):       ${tLastBurn}`);
  console.log(`Last release observed (latest of N):     ${tLastRelease}`);
  console.log("");
  console.log("--- Segment wall times (batch, ms) ---");
  console.log(`Deposits parallel phase end (slowest deposit mined): ${tAfterDeposits - firstDepositSubmittedMs} ms (approx)`);
  console.log(`All mints done (after last deposit phase start):      ${tAfterMints - firstDepositSubmittedMs} ms`);
  console.log(`Burn span (first deposit → last burn):                ${tLastBurn - firstDepositSubmittedMs} ms`);
  console.log(`Full round-trip (first deposit → last release):       ${tLastRelease - firstDepositSubmittedMs} ms`);
  console.log("");
  console.log("--- Per-lane averages (ms) ---");
  const avg = (sel) => snapshots.reduce((a, s) => a + sel(s), 0) / CONCURRENCY;
  console.log(`deposit_submit → mint done:  ${avg((s) => s.mintDoneMs - s.depositSubmittedMs).toFixed(0)}`);
  console.log(`burn_submit → release done:  ${avg((s) => s.releaseDoneMs - s.burnSubmittedMs).toFixed(0)}`);
  console.log("");
  console.log("--- Throughput (jobs = full lock+mint+burn+release per user) ---");
  const spanBurn = (tLastBurn - firstDepositSubmittedMs) / 1000;
  const spanFull = (tLastRelease - firstDepositSubmittedMs) / 1000;
  if (spanBurn > 0) console.log(`N / (last_burn − first_deposit): ${(CONCURRENCY / spanBurn).toFixed(6)} jobs/s`);
  if (spanFull > 0) console.log(`N / (last_release − first_deposit): ${(CONCURRENCY / spanFull).toFixed(6)} jobs/s`);
  console.log("");
  console.log("--- Gas totals (all N users) ---");
  console.log(`Approve+Deposit+Burn (user txs): ${sum((s) => s.approveGas + s.depositGas + s.burnGas).toString()}`);
  console.log(`Mint (relayer, from Mint logs):    ${sum((s) => s.mintGas).toString()}`);
  console.log(`Release (relayer, from Transfer): ${sum((s) => s.releaseGas).toString()}`);
  console.log(`Avg mint gas / user:    ${(sum((s) => s.mintGas) / n).toString()}`);
  console.log(`Avg release gas / user: ${(sum((s) => s.releaseGas) / n).toString()}`);
  console.log("================================================\n");

  console.log(
    "Note: 'first deposit' = earliest local timestamp when any worker's deposit() was sent; " +
      "burn span matches your N/T_total definition if T_total uses last burn confirmation."
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
