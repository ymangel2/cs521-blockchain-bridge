// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title WrappedToken
 * @dev ERC-20 on the destination chain (chain-b). The relayer calls mint() when
 *      it observes a Deposit event on the source chain. Only the minter (relayer)
 *      can mint. Standard ERC-20 for composability with other dApps.
 */
contract WrappedToken {
    string public name = "Wrapped Bridge Token";
    string public symbol = "wBRG";
    uint8 public decimals = 18;

    address public minter;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Mint(address indexed to, uint256 amount);

    constructor(address _minter) {
        require(_minter != address(0), "WrappedToken: zero minter");
        minter = _minter;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "WrappedToken: not minter");
        _;
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

    /**
     * @dev Called by the relayer when a Deposit is observed on the source chain.
     */
    function mint(address to, uint256 amount) external onlyMinter {
        require(to != address(0), "WrappedToken: mint to zero");
        require(amount > 0, "WrappedToken: zero amount");

        _totalSupply += amount;
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(address(0), to, amount);
        emit Mint(to, amount);
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
