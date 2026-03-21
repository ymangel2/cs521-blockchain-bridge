#!/usr/bin/env node
/**
 * Deploys Token, Vault, and WrappedToken to chain-a and chain-b.
 * Requires chains to be running (docker compose up -d chain-a chain-b).
 *
 * Uses Anvil: deployer 0xf39Fd... is prefunded with 10000 ETH on each chain.
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const CHAIN_A_RPC = process.env.CHAIN_A_RPC || "http://127.0.0.1:8545";
const CHAIN_B_RPC = process.env.CHAIN_B_RPC || "http://127.0.0.1:8547";

// Anvil uses chainId 31337. Use static network to avoid ethers network detection failures.
const ANVIL_NETWORK = ethers.Network.from(31337);

// Anvil/Hardhat test account #0 - prefunded on Anvil
const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const DEPLOYER_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

async function deployContract(signer, artifactName, nonceOverride, ...args) {
  const artifactPath = path.join(
    __dirname,
    "..",
    "artifacts",
    "contracts",
    `${artifactName}.sol`,
    `${artifactName}.json`
  );
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  const factory = new ethers.ContractFactory(
    artifact.abi,
    artifact.bytecode,
    signer
  );
  const nonce = nonceOverride !== undefined
    ? nonceOverride
    : await signer.provider.getTransactionCount(await signer.getAddress(), "latest");
  const deployTx = await factory.getDeployTransaction(...args);
  const sentTx = await signer.sendTransaction({ ...deployTx, nonce });
  const receipt = await sentTx.wait();
  const contractAddress = receipt.contractAddress;
  if (!contractAddress) throw new Error("Deployment failed: no contract address");
  return new ethers.Contract(contractAddress, artifact.abi, signer);
}

async function rpcCall(url, method = "eth_blockNumber", params = []) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5000);
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method, params, id: 1 }),
    signal: controller.signal,
  });
  clearTimeout(timeout);
  const data = await res.json();
  if (data.error) throw new Error(data.error.message || JSON.stringify(data.error));
  return data.result;
}

async function waitForChain(url, name, maxAttempts = 30) {
  for (let i = 0; i < maxAttempts; i++) {
    try {
      await rpcCall(url);
      return;
    } catch (e) {
      if (i === 0) console.log(`Waiting for ${name} at ${url}...`);
      else if (i % 5 === 4) console.log(`  (attempt ${i + 1}/${maxAttempts}): ${e.message}`);
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  throw new Error(`${name} not reachable at ${url}. Run: docker compose up -d chain-a chain-b`);
}

async function main() {
  console.log("Deploying bridge contracts...\n");

  await waitForChain(CHAIN_A_RPC, "chain-a");
  await waitForChain(CHAIN_B_RPC, "chain-b");
  console.log("Chains ready.\n");

  const providerA = new ethers.JsonRpcProvider(CHAIN_A_RPC, ANVIL_NETWORK, { staticNetwork: ANVIL_NETWORK });
  const providerB = new ethers.JsonRpcProvider(CHAIN_B_RPC, ANVIL_NETWORK, { staticNetwork: ANVIL_NETWORK });

  const signerA = new ethers.Wallet(DEPLOYER_KEY, providerA);
  const signerB = new ethers.Wallet(DEPLOYER_KEY, providerB);

  let nonceA = await providerA.getTransactionCount(DEPLOYER_ADDRESS, "latest");
  let nonceB = await providerB.getTransactionCount(DEPLOYER_ADDRESS, "latest");

  console.log("Chain A: deploying Token...");
  const token = await deployContract(signerA, "Token", nonceA++, ethers.parseEther("1000000"));
  const tokenAddress = token.target;
  console.log(`  Token at ${tokenAddress}`);

  console.log("Chain A: deploying Vault...");
  const vault = await deployContract(signerA, "Vault", nonceA++, tokenAddress, DEPLOYER_ADDRESS);
  const vaultAddress = vault.target;
  console.log(`  Vault at ${vaultAddress}`);

  console.log("\nChain B: deploying WrappedToken (minter = deployer/relayer)...");
  const wrappedToken = await deployContract(signerB, "WrappedToken", nonceB, DEPLOYER_ADDRESS);
  const wrappedTokenAddress = wrappedToken.target;
  console.log(`  WrappedToken at ${wrappedTokenAddress}`);

  const config = {
    chainA: {
      rpc: CHAIN_A_RPC,
      token: tokenAddress,
      vault: vaultAddress,
    },
    chainB: {
      rpc: CHAIN_B_RPC,
      wrappedToken: wrappedTokenAddress,
    },
    relayer: {
      address: DEPLOYER_ADDRESS,
      privateKey: DEPLOYER_KEY,
    },
  };

  const configPath = path.join(__dirname, "..", "relayer", "config.json");
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
  console.log(`\nConfig written to ${configPath}`);

  console.log("\n--- Deployment complete ---");
  console.log("Chain A - Token:", tokenAddress);
  console.log("Chain A - Vault:", vaultAddress);
  console.log("Chain B - WrappedToken:", wrappedTokenAddress);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
