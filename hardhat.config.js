require("hardhat/config");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.19",
    settings: { optimizer: { enabled: true, runs: 200 } },
  },
  networks: {
    "chain-a": {
      url: "http://127.0.0.1:8545",
      chainId: 1337,
    },
    "chain-b": {
      url: "http://127.0.0.1:8547",
      chainId: 1337,
    },
  },
};
