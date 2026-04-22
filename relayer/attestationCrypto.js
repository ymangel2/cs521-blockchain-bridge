/**
 * Shared digest + signing for 2-of-3 validator attestations (must match Solidity).
 */
const { ethers } = require("ethers");

const DEPOSIT_DOMAIN = ethers.keccak256(ethers.toUtf8Bytes("BRIDGE_V1_DEPOSIT"));
const BURN_DOMAIN = ethers.keccak256(ethers.toUtf8Bytes("BRIDGE_V1_BURN"));

function depositDigest(sourceChainId, vaultOnSource, depositTxHash, logIndex, to, amount) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "uint256", "address", "bytes32", "uint256", "address", "uint256"],
      [DEPOSIT_DOMAIN, sourceChainId, vaultOnSource, depositTxHash, logIndex, to, amount]
    )
  );
}

function burnDigest(destChainId, wrappedOnDest, burnTxHash, logIndex, to, amount) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "uint256", "address", "bytes32", "uint256", "address", "uint256"],
      [BURN_DOMAIN, destChainId, wrappedOnDest, burnTxHash, logIndex, to, amount]
    )
  );
}

function ethSignedMessageHash(digest) {
  return ethers.keccak256(
    ethers.concat([
      ethers.toUtf8Bytes("\x19Ethereum Signed Message:\n32"),
      ethers.getBytes(digest),
    ])
  );
}

/** @param {string} privateKey hex */
function signDigest(privateKey, digest) {
  const ethHash = ethSignedMessageHash(digest);
  const sk = new ethers.SigningKey(privateKey);
  const sig = sk.sign(ethHash);
  return ethers.Signature.from(sig).serialized;
}

module.exports = {
  depositDigest,
  burnDigest,
  ethSignedMessageHash,
  signDigest,
  DEPOSIT_DOMAIN,
  BURN_DOMAIN,
};
