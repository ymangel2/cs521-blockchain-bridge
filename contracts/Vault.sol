// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Vault
 * @dev Locks BRG on chain-a. Release requires 2-of-3 validator attestations over the Burn on chain-b.
 *      Plain release() removed — use releaseWithAttestation only.
 */
contract Vault {
    bytes32 public constant ATTEST_DOMAIN = keccak256("BRIDGE_V1_BURN");

    address public immutable token;
    address[3] public validators;
    uint256 public immutable threshold;
    uint256 public immutable destChainId;
    address public wrappedOnDest;

    address private immutable deployer;

    /// burnTxHash => logIndex => used
    mapping(bytes32 => mapping(uint256 => bool)) public usedBurnAttestations;

    event Deposit(
        address indexed sender,
        uint256 amount,
        uint256 indexed destChainId,
        uint256 blockNumber
    );

    constructor(
        address _token,
        address[3] memory _validators,
        uint256 _threshold,
        uint256 _destChainId
    ) {
        require(_token != address(0), "Vault: zero token address");
        require(_threshold > 0 && _threshold <= 3, "Vault: bad threshold");
        for (uint256 i = 0; i < 3; i++) {
            require(_validators[i] != address(0), "Vault: zero validator");
        }
        token = _token;
        validators = _validators;
        threshold = _threshold;
        destChainId = _destChainId;
        deployer = msg.sender;
    }

    function setWrappedOnDest(address _wrapped) external {
        require(msg.sender == deployer, "Vault: not deployer");
        require(_wrapped != address(0), "Vault: zero wrapped");
        require(wrappedOnDest == address(0), "Vault: already set");
        wrappedOnDest = _wrapped;
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "Vault: zero amount");

        (bool success, ) = token.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender,
                address(this),
                amount
            )
        );
        require(success, "Vault: transferFrom failed");

        emit Deposit(msg.sender, amount, 200, block.number);
    }

    /// @dev Legacy releaser path removed.
    function release(address, uint256) external pure {
        revert("Vault: use releaseWithAttestation");
    }

    /**
     * @dev Release BRG after threshold validators signed burnDigest(to, amount, burnTxHash, logIndex).
     */
    function releaseWithAttestation(
        address to,
        uint256 amount,
        bytes32 burnTxHash,
        uint256 logIndex,
        bytes[] calldata signatures,
        address[] calldata signers
    ) external {
        require(wrappedOnDest != address(0), "Vault: wrapped not set");
        require(to != address(0), "Vault: release to zero");
        require(amount > 0, "Vault: zero amount");
        require(!usedBurnAttestations[burnTxHash][logIndex], "Vault: burn already released");
        require(signatures.length == signers.length, "Vault: length mismatch");
        require(signatures.length >= threshold, "Vault: insufficient sigs");

        bytes32 digest = burnDigest(to, amount, burnTxHash, logIndex);

        for (uint256 i = 0; i < signers.length; i++) {
            require(_isValidator(signers[i]), "Vault: not validator");
            for (uint256 j = i + 1; j < signers.length; j++) {
                require(signers[i] != signers[j], "Vault: duplicate signer");
            }
            address recovered = _recoverSigner(digest, signatures[i]);
            require(recovered == signers[i], "Vault: bad signature");
        }

        usedBurnAttestations[burnTxHash][logIndex] = true;

        (bool success, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(success, "Vault: transfer failed");
    }

    function burnDigest(
        address to,
        uint256 amount,
        bytes32 burnTxHash,
        uint256 logIndex
    ) public view returns (bytes32) {
        return keccak256(abi.encode(ATTEST_DOMAIN, destChainId, wrappedOnDest, burnTxHash, logIndex, to, amount));
    }

    function _isValidator(address a) internal view returns (bool) {
        return a == validators[0] || a == validators[1] || a == validators[2];
    }

    function _recoverSigner(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "Vault: bad sig length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        return ecrecover(ethSigned, v, r, s);
    }
}
