// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.17;

import "./IFeeCurrency.sol";

/**
 * @dev Minimal ERC-20 that can pay for gas on Final Layer once governance lists
 * it in the FeeCurrencyDirectory. debitGasFees / creditGasFees can only be
 * called by the node (msg.sender == address(0)). Gas debits and credits emit
 * Transfer events to and from address(0) so indexers see every balance change.
 *
 * Storage layout is fixed (the genesis generator writes it directly):
 *   slot 0 balances, slot 1 allowances, slot 2 totalSupply.
 */
abstract contract FeeCurrencyERC20 is IFeeCurrency {
    mapping(address => uint256) internal _balances; // slot 0
    mapping(address => mapping(address => uint256)) internal _allowances; // slot 1
    uint256 internal _totalSupply; // slot 2

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    modifier onlyVm() {
        require(msg.sender == address(0), "only the node");
        _;
    }

    function name() external pure virtual returns (string memory);
    function symbol() external pure virtual returns (string memory);

    function decimals() external pure virtual returns (uint8) {
        return 18;
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

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "insufficient allowance");
            unchecked {
                _allowances[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(to != address(0), "transfer to zero");
        uint256 bal = _balances[from];
        require(bal >= value, "insufficient balance");
        unchecked {
            _balances[from] = bal - value;
        }
        _balances[to] += value;
        emit Transfer(from, to, value);
    }

    function debitGasFees(address from, uint256 value) external override onlyVm {
        uint256 bal = _balances[from];
        require(bal >= value, "insufficient balance for gas");
        unchecked {
            _balances[from] = bal - value;
            _totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }

    function creditGasFees(address[] calldata recipients, uint256[] calldata amounts) external override onlyVm {
        require(recipients.length == amounts.length, "length mismatch");
        for (uint256 i; i < recipients.length; ++i) {
            uint256 value = amounts[i];
            if (value == 0) continue;
            address to = recipients[i];
            _balances[to] += value;
            _totalSupply += value;
            emit Transfer(address(0), to, value);
        }
    }
}

/**
 * @dev Test fee currency pre-deployed in genesis at
 * 0x0000000000000000000000000000000000005054, whole supply to the treasury,
 * listed in the FeeCurrencyDirectory with a governance-set fixed rate.
 */
contract FLTestDollar is FeeCurrencyERC20 {
    function name() external pure override returns (string memory) {
        return "Final Layer Test Dollar";
    }

    function symbol() external pure override returns (string memory) {
        return "FLTD";
    }
}
