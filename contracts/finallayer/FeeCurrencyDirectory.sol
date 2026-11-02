// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.17;

import "./IFeeCurrency.sol";

interface IFLValidatorSet {
    function getValidators() external view returns (address[] memory);
    function currentValidatorSetMap(address consensus) external view returns (uint256);
    function currentValidatorSet(uint256 index)
        external
        view
        returns (address consensusAddress, address feeAddress, address bbcFeeAddress, uint64 votingPower, bool jailed, uint256 incoming);
}

interface IFLStakeHub {
    function consensusToOperator(address consensus) external view returns (address);
}

interface IFLFixedRateOracle {
    function setRate(address token, uint128 numerator, uint128 denominator, uint64 maxAge) external;
}

/**
 * @dev Allowlist of tokens that can pay for gas on Final Layer. The node reads
 * it through getCurrencyConfigAndRate before charging a transaction that names
 * a fee currency; an unlisted or suspended token, or one whose price source
 * reverts, cannot pay for gas.
 *
 * Pre-deployed in genesis at 0x0000000000000000000000000000000000005052.
 * Storage slots 0 and 1 are written directly by the genesis generator.
 *
 * Who can change it:
 *  - Governance (the BSCTimelock, i.e. a passed BSCGovernor vote). Listing,
 *    rate/price-source changes and lifting a suspension need the strict vote
 *    (BSCGovernor: 30% of voting power votes yes and 2/3 of yes+no are yes);
 *    removing a token needs only a normal vote.
 *  - The active validators, by 2/3 of the stake of the current working set
 *    (each validator weighs its voting power, i.e. its total stake as fixed
 *    at the last validator election, so stake added mid-day does not count
 *    and filling seats with minimum-stake validators gains little):
 *      suspend a token: takes effect at once;
 *      list / change a token's config and fixed rate, or lift a suspension:
 *      takes effect VALIDATOR_DELAY after reaching 2/3, and only if 2/3 still
 *      approve when executed (validators cancel by withdrawing approval).
 *    A validator acts from its consensus address or its operator address.
 */
contract FeeCurrencyDirectory {
    address public constant GOVERNANCE = 0x0000000000000000000000000000000000002006; // BSCTimelock
    address public constant VALIDATOR_SET = 0x0000000000000000000000000000000000001000;
    address public constant STAKE_HUB = 0x0000000000000000000000000000000000002002;
    address public constant FIXED_RATE_ORACLE = 0x0000000000000000000000000000000000005053;

    // The node gives each debit and credit call this much gas at most and
    // charges the sender the same amount once as extra intrinsic gas.
    uint256 public constant MIN_INTRINSIC_GAS = 40_000;
    uint256 public constant MAX_INTRINSIC_GAS = 200_000;
    uint256 public constant MAX_CURRENCIES = 32;
    uint256 public constant VALIDATOR_DELAY = 1 days;

    struct CurrencyConfig {
        address oracle;
        uint256 intrinsicGas;
    }

    enum ActionKind {
        None,
        Suspend,
        SetConfig, // list or change, optionally with a fixed rate
        Unsuspend
    }

    struct Action {
        ActionKind kind;
        address token;
        address oracle;
        uint256 intrinsicGas;
        uint128 rateNumerator; // 0 = leave the fixed rate unchanged
        uint128 rateDenominator;
        uint64 rateMaxAge;
        uint256 readyAt; // 0 until 2/3 approved (delayed kinds)
        uint256 nonce; // tokenNonce when created; the action is void once it changes
        bool done;
        address[] approvals; // consensus addresses
    }

    mapping(address => CurrencyConfig) internal currencies; // slot 0
    address[] internal currencyList; // slot 1
    mapping(address => bool) public suspended; // slot 2
    mapping(bytes32 => Action) internal actions; // slot 3
    // bumped whenever a token's state changes, so stale approvals for an old
    // situation cannot be replayed
    mapping(address => uint256) public tokenNonce; // slot 4

    event CurrencyConfigSet(address indexed token, address indexed oracle, uint256 intrinsicGas);
    event CurrencyRemoved(address indexed token);
    event CurrencySuspended(address indexed token, bool byValidators);
    event CurrencyUnsuspended(address indexed token);
    event ValidatorApproval(bytes32 indexed actionId, address indexed validator, uint256 approvedPower, uint256 totalPower);
    event ValidatorApprovalWithdrawn(bytes32 indexed actionId, address indexed validator);
    event ValidatorActionReady(bytes32 indexed actionId, uint256 readyAt);
    event ValidatorActionExecuted(bytes32 indexed actionId);

    modifier onlyGovernance() {
        require(msg.sender == GOVERNANCE, "only governance");
        _;
    }

    // ---------------------------------------------------------------- governance
    /// @dev Add a token or change its price source / intrinsic gas (strict vote).
    function setCurrencyConfig(address token, address oracle, uint256 intrinsicGas) external onlyGovernance {
        _setConfig(token, oracle, intrinsicGas);
    }

    /// @dev Remove a token (normal vote).
    function removeCurrency(address token) external onlyGovernance {
        require(currencies[token].oracle != address(0), "not a fee currency");
        _remove(token);
    }

    /// @dev Lift a suspension (strict vote).
    function unsuspend(address token) external onlyGovernance {
        _unsuspend(token);
    }

    // ---------------------------------------------------------------- validators
    /// @dev Approve suspending `token`; it is suspended as soon as 2/3 approve.
    function validatorSuspend(address token) external returns (bytes32 id) {
        require(currencies[token].oracle != address(0), "not a fee currency");
        require(!suspended[token], "already suspended");
        id = keccak256(abi.encode(ActionKind.Suspend, token, tokenNonce[token]));
        Action storage a = actions[id];
        if (a.kind == ActionKind.None) {
            a.kind = ActionKind.Suspend;
            a.token = token;
            a.nonce = tokenNonce[token];
        }
        _approve(id, a);
        if (_approvedNow(a)) {
            a.done = true;
            suspended[token] = true;
            tokenNonce[token]++;
            emit CurrencySuspended(token, true);
            emit ValidatorActionExecuted(id);
        }
    }

    /// @dev Approve listing / changing `token`. A non-zero rate also sets its
    /// fixed rate (use oracle == FIXED_RATE_ORACLE for that).
    function validatorSetConfig(
        address token,
        address oracle,
        uint256 intrinsicGas,
        uint128 rateNumerator,
        uint128 rateDenominator,
        uint64 rateMaxAge
    ) external returns (bytes32 id) {
        require((rateNumerator == 0) == (rateDenominator == 0), "bad rate");
        require(rateNumerator == 0 || oracle == FIXED_RATE_ORACLE, "rate needs the fixed rate oracle");
        id = keccak256(
            abi.encode(
                ActionKind.SetConfig, token, oracle, intrinsicGas, rateNumerator, rateDenominator, rateMaxAge, tokenNonce[token]
            )
        );
        Action storage a = actions[id];
        if (a.kind == ActionKind.None) {
            a.kind = ActionKind.SetConfig;
            a.token = token;
            a.oracle = oracle;
            a.intrinsicGas = intrinsicGas;
            a.rateNumerator = rateNumerator;
            a.rateDenominator = rateDenominator;
            a.rateMaxAge = rateMaxAge;
            a.nonce = tokenNonce[token];
        }
        _approve(id, a);
        _markReady(id, a);
    }

    /// @dev Approve lifting `token`'s suspension.
    function validatorUnsuspend(address token) external returns (bytes32 id) {
        require(suspended[token], "not suspended");
        id = keccak256(abi.encode(ActionKind.Unsuspend, token, tokenNonce[token]));
        Action storage a = actions[id];
        if (a.kind == ActionKind.None) {
            a.kind = ActionKind.Unsuspend;
            a.token = token;
            a.nonce = tokenNonce[token];
        }
        _approve(id, a);
        _markReady(id, a);
    }

    /// @dev Withdraw an approval (this is how validators cancel a delayed action).
    function withdrawApproval(bytes32 id) external {
        Action storage a = actions[id];
        require(a.kind != ActionKind.None && !a.done, "no open action");
        address v = _callerValidator();
        uint256 n = a.approvals.length;
        for (uint256 i; i < n; ++i) {
            if (a.approvals[i] == v) {
                a.approvals[i] = a.approvals[n - 1];
                a.approvals.pop();
                emit ValidatorApprovalWithdrawn(id, v);
                if (!_approvedNow(a)) a.readyAt = 0; // the wait restarts if 2/3 is reached again
                return;
            }
        }
        revert("not approved by caller");
    }

    /// @dev Run a delayed action after its wait. Anyone may call; validators
    /// holding 2/3 of the current stake must still approve it.
    function executeValidatorAction(bytes32 id) external {
        Action storage a = actions[id];
        require(a.kind == ActionKind.SetConfig || a.kind == ActionKind.Unsuspend, "not a delayed action");
        require(!a.done, "already executed");
        require(a.readyAt != 0 && block.timestamp >= a.readyAt, "not ready");
        require(a.nonce == tokenNonce[a.token], "token changed since approval");
        require(_approvedNow(a), "approval below 2/3");
        a.done = true;
        address token = a.token;
        if (a.kind == ActionKind.SetConfig) {
            if (a.rateNumerator != 0) {
                IFLFixedRateOracle(FIXED_RATE_ORACLE).setRate(token, a.rateNumerator, a.rateDenominator, a.rateMaxAge);
            }
            _setConfig(token, a.oracle, a.intrinsicGas);
        } else {
            _unsuspend(token);
        }
        emit ValidatorActionExecuted(id);
    }

    function getAction(bytes32 id)
        external
        view
        returns (
            ActionKind kind,
            address token,
            uint256 readyAt,
            bool done,
            uint256 approvedPower,
            uint256 totalPower
        )
    {
        Action storage a = actions[id];
        (approvedPower, totalPower) = _count(a);
        return (a.kind, a.token, a.readyAt, a.done, approvedPower, totalPower);
    }

    // ---------------------------------------------------------------- views
    function getCurrencies() external view returns (address[] memory) {
        return currencyList;
    }

    function getCurrencyConfig(address token) external view returns (CurrencyConfig memory) {
        return currencies[token];
    }

    /// @dev Token units per wei of FL: tokenAmount = flAmount * numerator / denominator.
    function getExchangeRate(address token) public view returns (uint256 numerator, uint256 denominator) {
        address oracle = currencies[token].oracle;
        require(oracle != address(0), "not a fee currency");
        require(!suspended[token], "suspended");
        (numerator, denominator) = IFeeCurrencyOracle(oracle).getExchangeRate(token);
        require(numerator > 0 && denominator > 0, "invalid rate");
    }

    /// @dev Single call used by the node.
    function getCurrencyConfigAndRate(address token)
        external
        view
        returns (uint256 numerator, uint256 denominator, uint256 intrinsicGas)
    {
        (numerator, denominator) = getExchangeRate(token);
        intrinsicGas = currencies[token].intrinsicGas;
    }

    // ---------------------------------------------------------------- internal
    function _setConfig(address token, address oracle, uint256 intrinsicGas) internal {
        require(token.code.length > 0, "token has no code");
        require(oracle.code.length > 0, "oracle has no code");
        require(intrinsicGas >= MIN_INTRINSIC_GAS && intrinsicGas <= MAX_INTRINSIC_GAS, "intrinsic gas out of range");
        if (currencies[token].oracle == address(0)) {
            require(currencyList.length < MAX_CURRENCIES, "too many currencies");
            currencyList.push(token);
        }
        currencies[token] = CurrencyConfig(oracle, intrinsicGas);
        tokenNonce[token]++;
        emit CurrencyConfigSet(token, oracle, intrinsicGas);
    }

    function _remove(address token) internal {
        delete currencies[token];
        suspended[token] = false;
        tokenNonce[token]++;
        uint256 n = currencyList.length;
        for (uint256 i; i < n; ++i) {
            if (currencyList[i] == token) {
                currencyList[i] = currencyList[n - 1];
                currencyList.pop();
                break;
            }
        }
        emit CurrencyRemoved(token);
    }

    function _unsuspend(address token) internal {
        require(suspended[token], "not suspended");
        suspended[token] = false;
        tokenNonce[token]++;
        emit CurrencyUnsuspended(token);
    }

    /// @dev Consensus address of the calling validator (consensus or operator key).
    function _callerValidator() internal view returns (address) {
        address[] memory set = IFLValidatorSet(VALIDATOR_SET).getValidators();
        for (uint256 i; i < set.length; ++i) {
            if (set[i] == msg.sender || IFLStakeHub(STAKE_HUB).consensusToOperator(set[i]) == msg.sender) {
                return set[i];
            }
        }
        revert("not an active validator");
    }

    function _approve(bytes32 id, Action storage a) internal {
        require(!a.done, "already executed");
        require(a.nonce == tokenNonce[a.token], "token changed since approval");
        address v = _callerValidator();
        for (uint256 i; i < a.approvals.length; ++i) {
            require(a.approvals[i] != v, "already approved");
        }
        a.approvals.push(v);
        (uint256 c, uint256 n) = _count(a);
        emit ValidatorApproval(id, v, c, n);
    }

    function _markReady(bytes32 id, Action storage a) internal {
        if (a.readyAt == 0 && _approvedNow(a)) {
            a.readyAt = block.timestamp + VALIDATOR_DELAY;
            emit ValidatorActionReady(id, a.readyAt);
        }
    }

    /// @dev Voting power of a working validator (its stake / 1e10 as set by
    /// the last validator election).
    function _power(address validator) internal view returns (uint256 power) {
        uint256 index = IFLValidatorSet(VALIDATOR_SET).currentValidatorSetMap(validator);
        if (index == 0) return 0;
        (,,, uint64 p,,) = IFLValidatorSet(VALIDATOR_SET).currentValidatorSet(index - 1);
        return p;
    }

    /// @dev Voting power of approvers in the current working set, and of the whole set.
    function _count(Action storage a) internal view returns (uint256 approved, uint256 total) {
        address[] memory set = IFLValidatorSet(VALIDATOR_SET).getValidators();
        uint256 n = a.approvals.length;
        for (uint256 j; j < set.length; ++j) {
            uint256 p = _power(set[j]);
            total += p;
            for (uint256 i; i < n; ++i) {
                if (a.approvals[i] == set[j]) {
                    approved += p;
                    break;
                }
            }
        }
    }

    function _approvedNow(Action storage a) internal view returns (bool) {
        (uint256 c, uint256 n) = _count(a);
        return n > 0 && c * 3 >= n * 2;
    }
}
