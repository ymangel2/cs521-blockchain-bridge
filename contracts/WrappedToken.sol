// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title WrappedToken
 * @dev wBRG on chain-b. Minting requires 2-of-3 validator ECDSA attestations over the
 *      source Deposit (tx hash + log index + recipient + amount). Plain mint() is disabled.
 */
contract WrappedToken {
    string public name = "Wrapped Bridge Token";
    string public symbol = "wBRG";
    uint8 public decimals = 18;

    bytes32 public constant ATTEST_DOMAIN = keccak256("BRIDGE_V1_DEPOSIT");

    address[3] public validators;
    uint256 public immutable threshold;
    address public immutable vaultOnSource;
    uint256 public immutable sourceChainId;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    /// depositTxHash => logIndex => used
    mapping(bytes32 => mapping(uint256 => bool)) public usedDepositAttestations;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);

    constructor(
        address[3] memory _validators,
        uint256 _threshold,
        address _vaultOnSource,
        uint256 _sourceChainId
    ) {
        require(_threshold > 0 && _threshold <= 3, "WrappedToken: bad threshold");
        require(_vaultOnSource != address(0), "WrappedToken: zero vault");
        for (uint256 i = 0; i < 3; i++) {
            require(_validators[i] != address(0), "WrappedToken: zero validator");
        }
        validators = _validators;
        threshold = _threshold;
        vaultOnSource = _vaultOnSource;
        sourceChainId = _sourceChainId;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "WrappedToken: insufficient allowance");
        unchecked {
            _approve(from, msg.sender, currentAllowance - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @dev Legacy single-minter path disabled; use mintWithAttestation.
    function mint(address, uint256) external pure {
        revert("WrappedToken: use mintWithAttestation");
    }

    /**
     * @dev Mint after threshold validators signed depositDigest(to, amount, depositTxHash, logIndex).
     */
    function mintWithAttestation(
        address to,
        uint256 amount,
        bytes32 depositTxHash,
        uint256 logIndex,
        bytes[] calldata signatures,
        address[] calldata signers
    ) external {
        require(to != address(0), "WrappedToken: mint to zero");
        require(amount > 0, "WrappedToken: zero amount");
        require(!usedDepositAttestations[depositTxHash][logIndex], "WrappedToken: deposit already minted");
        require(signatures.length == signers.length, "WrappedToken: length mismatch");
        require(signatures.length >= threshold, "WrappedToken: insufficient sigs");

        bytes32 digest = depositDigest(to, amount, depositTxHash, logIndex);

        for (uint256 i = 0; i < signers.length; i++) {
            require(_isValidator(signers[i]), "WrappedToken: not validator");
            for (uint256 j = i + 1; j < signers.length; j++) {
                require(signers[i] != signers[j], "WrappedToken: duplicate signer");
            }
            address recovered = _recoverSigner(digest, signatures[i]);
            require(recovered == signers[i], "WrappedToken: bad signature");
        }

        usedDepositAttestations[depositTxHash][logIndex] = true;

        _totalSupply += amount;
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(address(0), to, amount);
        emit Mint(to, amount);
    }

    function depositDigest(
        address to,
        uint256 amount,
        bytes32 depositTxHash,
        uint256 logIndex
    ) public view returns (bytes32) {
        return keccak256(abi.encode(ATTEST_DOMAIN, sourceChainId, vaultOnSource, depositTxHash, logIndex, to, amount));
    }

    function burn(uint256 amount) external {
        require(amount > 0, "WrappedToken: zero amount");
        require(_balances[msg.sender] >= amount, "WrappedToken: insufficient balance");

        unchecked {
            _balances[msg.sender] -= amount;
            _totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
        emit Burn(msg.sender, amount);
    }

    function _isValidator(address a) internal view returns (bool) {
        return a == validators[0] || a == validators[1] || a == validators[2];
    }

    function _recoverSigner(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "WrappedToken: bad sig length");
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

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "WrappedToken: transfer from zero");
        require(to != address(0), "WrappedToken: transfer to zero");
        require(_balances[from] >= amount, "WrappedToken: insufficient balance");

        unchecked {
            _balances[from] -= amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "WrappedToken: approve from zero");
        require(spender != address(0), "WrappedToken: approve to zero");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}
