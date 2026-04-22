#!/usr/bin/env node
/**
 * Deploys Token, Vault, and WrappedToken to chain-a and chain-b.
 * Requires chains to be running (docker compose up -d chain-a chain-b).
 *
 * Uses Anvil: deployer 0xf39Fd... is prefunded with 10000 ETH on each chain.
 * Validators: HD path m/44'/60'/0'/0/{1,2,3} (Anvil accounts 1–3). Threshold 2-of-3.
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const CHAIN_A_RPC = process.env.CHAIN_A_RPC || "http://127.0.0.1:8545";
const CHAIN_B_RPC = process.env.CHAIN_B_RPC || "http://127.0.0.1:8547";

const ANVIL_NETWORK = ethers.Network.from(31337);

const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const DEPLOYER_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

const THRESHOLD = 2;
const BRIDGE_CHAIN_ID = 31337;

const TEST_MNEMONIC = "test test test test test test test test test test test junk";

function validatorWallet(index) {
  const mnemonic = ethers.Mnemonic.fromPhrase(TEST_MNEMONIC);
  return ethers.HDNodeWallet.fromMnemonic(mnemonic, `m/44'/60'/0'/0/${index}`);
}

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
  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, signer);
  const nonce =
    nonceOverride !== undefined
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
  console.log("Deploying bridge contracts (2-of-3 attestation)...\n");

  await waitForChain(CHAIN_A_RPC, "chain-a");
  await waitForChain(CHAIN_B_RPC, "chain-b");
  console.log("Chains ready.\n");

  const providerA = new ethers.JsonRpcProvider(CHAIN_A_RPC, ANVIL_NETWORK, { staticNetwork: ANVIL_NETWORK });
  const providerB = new ethers.JsonRpcProvider(CHAIN_B_RPC, ANVIL_NETWORK, { staticNetwork: ANVIL_NETWORK });

  const signerA = new ethers.Wallet(DEPLOYER_KEY, providerA);
  const signerB = new ethers.Wallet(DEPLOYER_KEY, providerB);

  let nonceA = await providerA.getTransactionCount(DEPLOYER_ADDRESS, "latest");
  let nonceB = await providerB.getTransactionCount(DEPLOYER_ADDRESS, "latest");

  const v1 = validatorWallet(1);
  const v2 = validatorWallet(2);
  const v3 = validatorWallet(3);
  const validators = [v1.address, v2.address, v3.address];

  console.log("Validators (2-of-3):");
  console.log(`  [0] ${validators[0]}`);
  console.log(`  [1] ${validators[1]}`);
  console.log(`  [2] ${validators[2]}`);
  console.log(`  chainId (digests): ${BRIDGE_CHAIN_ID}\n`);

  console.log("Chain A: deploying Token...");
  const token = await deployContract(signerA, "Token", nonceA++, ethers.parseEther("1000000"));
  const tokenAddress = token.target;
  console.log(`  Token at ${tokenAddress}`);

  console.log("Chain A: deploying Vault...");
  const vault = await deployContract(signerA, "Vault", nonceA++, tokenAddress, validators, THRESHOLD, BRIDGE_CHAIN_ID);
  const vaultAddress = vault.target;
  console.log(`  Vault at ${vaultAddress}`);

  console.log("\nChain B: deploying WrappedToken...");
  const wrappedToken = await deployContract(
    signerB,
    "WrappedToken",
    nonceB++,
    validators,
    THRESHOLD,
    vaultAddress,
    BRIDGE_CHAIN_ID
  );
  const wrappedTokenAddress = wrappedToken.target;
  console.log(`  WrappedToken at ${wrappedTokenAddress}`);

  console.log("\nChain A: setWrappedOnDest (links burn digest to wrapped address)...");
  const linkTx = await vault.setWrappedOnDest(wrappedTokenAddress);
  await linkTx.wait();
  console.log("  Linked.\n");

  const config = {
    threshold: THRESHOLD,
    chainA: {
      rpc: CHAIN_A_RPC,
      chainId: BRIDGE_CHAIN_ID,
      token: tokenAddress,
      vault: vaultAddress,
    },
    chainB: {
      rpc: CHAIN_B_RPC,
      chainId: BRIDGE_CHAIN_ID,
      wrappedToken: wrappedTokenAddress,
    },
    validators: [
      { address: v1.address, privateKey: v1.privateKey },
      { address: v2.address, privateKey: v2.privateKey },
      { address: v3.address, privateKey: v3.privateKey },
    ],
    relayer: {
      address: DEPLOYER_ADDRESS,
      privateKey: DEPLOYER_KEY,
    },
  };

  const configPath = path.join(__dirname, "..", "relayer", "config.json");
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
  console.log(`Config written to ${configPath}`);

  console.log("\n--- Deployment complete ---");
  console.log("Chain A - Token:", tokenAddress);
  console.log("Chain A - Vault:", vaultAddress);
  console.log("Chain B - WrappedToken:", wrappedTokenAddress);
  console.log("\nRun three validator processes (see scripts/demo-bridge.sh), then the relayer.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
