// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Vault
 * @dev Holds locked tokens on the source chain. Users call approve() on the Token
 *      then deposit(amount). The Vault uses transferFrom to pull tokens into custody.
 *      Relayer calls release(to, amount) when a Burn is observed on chain-b.
 *      CRITICAL: We only emit Deposit after transferFrom succeeds - the Q-Bridge
 *      exploit showed that emitting before verifying the transfer is dangerous.
 */
contract Vault {
    address public immutable token;
    address public immutable releaser;
    uint256 public constant DEST_CHAIN_ID = 200; // Logical ID for chain-b

    event Deposit(
        address indexed sender,
        uint256 amount,
        uint256 indexed destChainId,
        uint256 blockNumber
    );

    constructor(address _token, address _releaser) {
        require(_token != address(0), "Vault: zero token address");
        require(_releaser != address(0), "Vault: zero releaser");
        token = _token;
        releaser = _releaser;
    }

    modifier onlyReleaser() {
        require(msg.sender == releaser, "Vault: not releaser");
        _;
    }

    /**
     * @dev Locks tokens by pulling them from msg.sender. Requires prior approve().
     *      Emits Deposit only after transferFrom succeeds.
     */
    function deposit(uint256 amount) external {
        require(amount > 0, "Vault: zero amount");

        // Pull tokens - reverts on failure (insufficient balance/allowance)
        (bool success, ) = token.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender,
                address(this),
                amount
            )
        );
        require(success, "Vault: transferFrom failed");

        // Only emit after successful transfer (Q-Bridge lesson)
        emit Deposit(msg.sender, amount, DEST_CHAIN_ID, block.number);
    }

    /**
     * @dev Called by the relayer when a Burn is observed on chain-b. Releases BRG to the burner.
     */
    function release(address to, uint256 amount) external onlyReleaser {
        require(to != address(0), "Vault: release to zero");
        require(amount > 0, "Vault: zero amount");
        (bool success, ) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(success, "Vault: transfer failed");
    }
}
