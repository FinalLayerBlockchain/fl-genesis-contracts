// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./SystemV2.sol";
import "./extension/Protectable.sol";
import "./interface/0.8.x/IBSCValidatorSet.sol";
import "./interface/0.8.x/IGovToken.sol";
import "./interface/0.8.x/IStakeCredit.sol";
import "./lib/0.8.x/Utils.sol";

interface ISlashIndicatorMisses {
    function getSlashIndicator(
        address validator
    ) external view returns (uint256 height, uint256 count);
}

contract StakeHub is SystemV2, Initializable, Protectable {
    using Utils for string;
    using Utils for bytes;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*----------------- constants -----------------*/
    uint256 private constant BLS_PUBKEY_LENGTH = 48;
    uint256 private constant BLS_SIG_LENGTH = 96;

    address public constant DEAD_ADDRESS = address(0xdEaD);
    uint256 public constant LOCK_AMOUNT = 1 ether;
    uint256 public constant REDELEGATE_FEE_RATE_BASE = 100000; // 100%

    uint256 public constant BREATHE_BLOCK_INTERVAL = 1 days;

    uint256 public constant INIT_MAX_NUMBER_NODE_ID = 5;

    // receive fund status
    uint8 private constant _DISABLE = 0;
    uint8 private constant _ENABLE = 1;

    /*----------------- errors -----------------*/
    // @notice signature: 0x5f28f62b
    error TooManyValidators();
    error TooManyPendingRotations();
    error ValidatorExisted();
    // @notice signature: 0x056e8811
    error ValidatorNotExisted();
    // @notice signature: 0x4b6b857d
    error ValidatorNotJailed();
    // @notice signature: 0x3cdeb0ea
    error DuplicateConsensusAddress();
    // @notice signature: 0x11fdb947
    error DuplicateVoteAddress();
    // @notice signature: 0xc0bf4143
    error DuplicateMoniker();
    // @notice signature: 0x2f64097e
    error SelfDelegationNotEnough();
    // @notice signature: 0xdc81db85
    error InvalidCommission();
    // @notice signature: 0x5dba5ad7
    error InvalidMoniker();
    // @notice signature: 0x2c8fc796
    error InvalidVoteAddress();
    // @notice signature: 0xca40c236
    error InvalidConsensusAddress();
    // @notice signature: 0x3f259b7a
    error UpdateTooFrequently();
    // @notice signature: 0x5c32dd9c
    error JailTimeNotExpired();
    // @notice signature: 0xdc6f0bdd
    error DelegationAmountTooSmall();
    // @notice signature: 0x64689203
    error OnlySelfDelegation();
    // @notice signature: 0x9811e0c7
    error ZeroShares();
    // @notice signature: 0xf0e3e629
    error SameValidator();
    // @notice signature: 0xbd52fcdb
    error NoMoreFelonyAllowed();
    // @notice signature: 0x37233762
    error AlreadySlashed();
    // @notice signature: 0x90b8ec18
    error TransferFailed();
    // @notice signature: 0x41abc801
    error InvalidRequest();
    // @notice signature: 0x1898eb6b
    error VoteAddressExpired();
    // @notice signature: 0xc2aee074
    error ConsensusAddressExpired();
    // @notice signature: 0x0d7b78d4
    error InvalidSynPackage();
    // @notice signature: 0xbebdc757
    error InvalidAgent();
    // @notice signature: 0x682a6e7c
    error InvalidValidator();
    // @notice signature: 0x6490ffd3
    error InvalidNodeID();
    // @notice signature: 0x246be614
    error ExceedsMaxNodeIDs();
    // @notice signature: 0x440bc78e
    error DuplicateNodeID();

    /*----------------- storage -----------------*/
    uint8 private _receiveFundStatus;
    uint256 public transferGasLimit;

    // stake params
    uint256 public minSelfDelegationBNB;
    uint256 public minDelegationBNBChange;
    uint256 public maxElectedValidators;
    uint256 public unbondPeriod;
    uint256 public redelegateFeeRate;

    // slash params
    uint256 public downtimeSlashAmount;
    uint256 public felonySlashAmount;
    uint256 public downtimeJailTime;
    uint256 public felonyJailTime;

    // validator operator address set
    EnumerableSet.AddressSet private _validatorSet;
    // validator operator address => validator info
    mapping(address => Validator) private _validators;
    // validator moniker set(hash of the moniker)
    mapping(bytes32 => bool) private _monikerSet;
    // validator consensus address => validator operator address
    mapping(address => address) public consensusToOperator;
    // validator consensus address => expiry date
    mapping(address => uint256) public consensusExpiration;
    // validator vote address => validator operator address
    mapping(bytes => address) public voteToOperator;
    // validator vote address => expiry date
    mapping(bytes => uint256) public voteExpiration;

    // legacy addresses of BC
    mapping(address => bool) private _legacyConsensusAddress; // @dev deprecated
    mapping(bytes => bool) private _legacyVoteAddress; // @dev deprecated

    // total number of current jailed validators
    uint256 public numOfJailed;
    // max number of jailed validators between breathe block(only for malicious vote and double sign)
    uint256 public maxFelonyBetweenBreatheBlock;
    // index(timestamp / breatheBlockInterval) => number of malicious vote and double sign slash
    mapping(uint256 => uint256) private _felonyMap;
    // slash key => slash jail time
    mapping(bytes32 => uint256) private _felonyRecords;

    // agent => validator operator address
    mapping(address => address) public agentToOperator;

    // network related values //

    // governance controlled maximum number of NodeIDs per validator (default is 5).
    uint256 public maxNodeIDs;

    // mapping from a validator's operator address to an array of their registered NodeIDs,
    // where each NodeID is stored as a fixed 32-byte value.
    mapping(address => bytes32[]) private validatorNodeIDs;

    // ---- Final Layer staking inflation ----
    // Annual staking reward paid to every delegator (including the validator's
    // own self-delegation), in basis points of the staked amount. 1200 = 12%.
    uint256 public stakingAprBps;
    // Extra reward paid to the validator itself, in basis points of the staking
    // reward of its pool. 1000 = the validator earns an extra 10% on top of what
    // its delegators earn (1.2% of the pool per year at a 12% APR).
    uint256 public validatorRewardBps;
    // Inflation is paid up to this timestamp. After a halt longer than
    // MAX_INFLATION_PERIOD it advances only by the time actually paid, so the
    // missed time is caught up on the following breathe blocks.
    uint256 public lastInflationTime;
    // Inflation accrued at the previous rates when a rate is changed by
    // governance, paid at the next breathe block (rates never apply backwards).
    uint256 public accruedInflation;
    // Inflation that was minted but could not be assigned to a pool (rounding,
    // pool jailed since the snapshot). It is paid out with the next distribution.
    uint256 public inflationCarry;
    // Staker and validator parts a pool failed to accept. Retried at every
    // breathe block and by anyone through retryStakingInflation.
    mapping(address => uint256) public pendingStakerInflation;
    mapping(address => uint256) public pendingValidatorInflation;
    // Recipients and stake weights taken at the previous breathe block. The
    // next distribution pays by these weights, so stake added just before a
    // breathe block does not earn the reward of the day before it.
    address[] internal _inflationOperators;
    address[] internal _inflationCredits;
    uint256[] internal _inflationWeights;
    uint256 public inflationWeightTotal;
    // Time of each operator's last editConsensusAddress. Until the new key is in
    // Parlia's validator set the validator cannot seal (the node rejects the old
    // key at once), so concurrent rotations are bounded to keep the chain live,
    // and a pool rotated after the inflation snapshot forfeits that distribution.
    mapping(address => uint256) public consensusRotatedAt;
    // Timestamp of the block that took the current inflation snapshot.
    uint256 public inflationSnapshotTime;
    // The validator-bonus part of accruedInflation, so a later change of
    // validatorRewardBps does not re-split rewards that were already earned.
    uint256 public accruedValidatorInflation;

    /*----------------- Final Layer constants -----------------*/
    uint256 public constant MAX_STAKING_APR_BPS = 2000; // 20% hard cap
    uint256 public constant MAX_VALIDATOR_REWARD_BPS = 5000; // 50% of the pool reward
    uint256 public constant MAX_INFLATION_PERIOD = 30 days; // cap after a long halt
    // Bounds the breathe block system txs: at 50 the worst case (validator update
    // growing the set + inflation with retries for every pool) is ~23.3M gas of
    // the 35M reserved on a 40M gas block; at 100 it is ~47M, over the block gas
    // limit, so no breathe block could be built (FinalLayerInflation.t.sol).
    uint256 public constant MAX_INFLATION_VALIDATORS = 50;
    // Bounds the daily election read, which scans every registered validator.
    uint256 public constant MAX_REGISTERED_VALIDATORS = 500;
    uint256 public constant MIN_SELF_DELEGATION_FLOOR = 100_000 ether;
    // Upper bound on the time from editConsensusAddress until Parlia seals with
    // the new key: the next breathe block (<= 1 day) installs it in the
    // validator set and the following epoch block (1000 blocks) in Parlia.
    uint256 public constant ROTATION_SETTLE_TIME = 1 days + 4 hours;
    // A current validator that missed its turn within this many blocks counts
    // as offline for the rotation liveness check (SlashIndicator records the
    // block of every missed turn).
    uint256 public constant RECENT_MISS_BLOCKS = 200;
    address private constant PQ_VERIFY_PRECOMPILE = address(0x0f01);
    uint8 private constant PQ_SCHEME_MLDSA87 = 0x01;
    uint256 private constant PQ_PUBKEY_LENGTH = 2592;
    uint256 private constant PQ_PROOF_LENGTH = 1 + 2592 + 4627;
    uint256 private constant INFLATION_YEAR = 365 days;

    /*----------------- structs and events -----------------*/
    struct StakeMigrationPackage {
        address operatorAddress; // the operator address of the target validator to delegate to
        address delegator; // the beneficiary of the delegation
        address refundAddress; // the Beacon Chain address to refund the fund if migration failed
        uint256 amount; // the amount of BNB to be migrated(decimal: 18)
    }

    enum StakeMigrationRespCode {
        MIGRATE_SUCCESS,
        CLAIM_FUND_FAILED,
        VALIDATOR_NOT_EXISTED,
        VALIDATOR_JAILED,
        INVALID_DELEGATOR
    }

    struct Validator {
        address consensusAddress;
        address operatorAddress;
        address creditContract;
        uint256 createdTime;
        bytes voteAddress;
        Description description;
        Commission commission;
        bool jailed;
        uint256 jailUntil;
        uint256 updateTime;
        // The agent can perform transactions on behalf of the operatorAddress in certain scenarios.
        address agent;
        uint256[19] __reservedSlots;
    }

    struct Description {
        string moniker;
        string identity;
        string website;
        string details;
    }

    struct Commission {
        uint64 rate; // the commission rate charged to delegators(10000 is 100%)
        uint64 maxRate; // maximum commission rate which validator can ever charge
        uint64 maxChangeRate; // maximum daily increase of the validator commission
    }

    enum SlashType {
        DoubleSign,
        DownTime,
        MaliciousVote
    }

    event ValidatorCreated(
        address indexed consensusAddress,
        address indexed operatorAddress,
        address indexed creditContract,
        bytes voteAddress
    );
    event StakeCreditInitialized(address indexed operatorAddress, address indexed creditContract);
    event ConsensusAddressEdited(address indexed operatorAddress, address indexed newConsensusAddress);
    event CommissionRateEdited(address indexed operatorAddress, uint64 newCommissionRate);
    event DescriptionEdited(address indexed operatorAddress);
    event VoteAddressEdited(address indexed operatorAddress, bytes newVoteAddress);
    event Delegated(address indexed operatorAddress, address indexed delegator, uint256 shares, uint256 bnbAmount);
    event Undelegated(address indexed operatorAddress, address indexed delegator, uint256 shares, uint256 bnbAmount);
    event Redelegated(
        address indexed srcValidator,
        address indexed dstValidator,
        address indexed delegator,
        uint256 oldShares,
        uint256 newShares,
        uint256 bnbAmount
    );
    event RewardDistributed(address indexed operatorAddress, uint256 reward);
    event RewardDistributeFailed(address indexed operatorAddress, bytes failReason);
    event ValidatorSlashed(
        address indexed operatorAddress, uint256 jailUntil, uint256 slashAmount, SlashType slashType
    );
    event ValidatorJailed(address indexed operatorAddress);
    event ValidatorEmptyJailed(address indexed operatorAddress);
    event ValidatorUnjailed(address indexed operatorAddress);
    event Claimed(address indexed operatorAddress, address indexed delegator, uint256 bnbAmount);
    event AgentChanged(address indexed operatorAddress, address indexed oldAgent, address indexed newAgent);
    event StakingInflationDistributed(uint256 amount, uint256 elapsed);
    event StakingInflationFailed(address indexed operatorAddress, uint256 amount);
    event StakingInflationRetried(address indexed operatorAddress, uint256 amount);

    // Events for adding and removing NodeIDs.
    event NodeIDAdded(address indexed validator, bytes32 nodeID);
    event NodeIDRemoved(address indexed validator, bytes32 nodeID);

    event MigrateSuccess(address indexed operatorAddress, address indexed delegator, uint256 shares, uint256 bnbAmount); // @dev deprecated
    event MigrateFailed(
        address indexed operatorAddress, address indexed delegator, uint256 bnbAmount, StakeMigrationRespCode respCode
    ); // @dev deprecated
    event UnexpectedPackage(uint8 channelId, bytes msgBytes); // @dev deprecated

    /*----------------- modifiers -----------------*/
    modifier validatorExist(
        address operatorAddress
    ) {
        if (!_validatorSet.contains(operatorAddress)) revert ValidatorNotExisted();
        _;
    }

    modifier enableReceivingFund() {
        _receiveFundStatus = _ENABLE;
        _;
        _receiveFundStatus = _DISABLE;
    }

    receive() external payable {
        // to prevent BNB from being lost
        if (_receiveFundStatus != _ENABLE) revert();
    }

    /**
     * @dev this function is invoked by BSC Parlia consensus engine during the hard fork
     */
    function initialize() external initializer onlyCoinbase onlyZeroGasPrice {
        transferGasLimit = 5000;
        minSelfDelegationBNB = 100_000 ether;
        minDelegationBNBChange = 1 ether;
        maxElectedValidators = 21;
        unbondPeriod = 7 days;
        redelegateFeeRate = 2;
        downtimeSlashAmount = 10 ether;
        felonySlashAmount = 200 ether;
        downtimeJailTime = 2 days;
        felonyJailTime = 30 days;
        maxFelonyBetweenBreatheBlock = 2;
        stakingAprBps = 1200;
        validatorRewardBps = 1000;
        lastInflationTime = block.timestamp;
        // Different address will be set depending on the environment
        __Protectable_init_unchained(0xe643DA662420be3f839D522e32BB688894308F2B);
    }

    /*----------------- Implement cross chain app -----------------*/
    function handleSynPackage(
        uint8,
        bytes calldata msgBytes
    ) external onlyCrossChainContract whenNotPaused enableReceivingFund returns (bytes memory) {
        revert("deprecated");
    }

    function handleAckPackage(uint8 channelId, bytes calldata msgBytes) external onlyCrossChainContract {
        revert("deprecated");
    }

    function handleFailAckPackage(uint8 channelId, bytes calldata msgBytes) external onlyCrossChainContract {
        revert("deprecated");
    }

    /*----------------- external functions -----------------*/
    /**
     * @param newAgent the new agent address of the validator, updating to address(0) means remove the old agent.
     */
    function updateAgent(
        address newAgent
    ) external validatorExist(msg.sender) whenNotPaused notInBlackList {
        if (agentToOperator[newAgent] != address(0)) revert InvalidAgent();
        if (_validatorSet.contains(newAgent)) revert InvalidAgent();

        address operatorAddress = msg.sender;
        address oldAgent = _validators[operatorAddress].agent;
        if (oldAgent == newAgent) revert InvalidAgent();

        if (oldAgent != address(0)) {
            delete agentToOperator[oldAgent];
        }

        _validators[operatorAddress].agent = newAgent;

        if (newAgent != address(0)) {
            agentToOperator[newAgent] = operatorAddress;
        }

        emit AgentChanged(operatorAddress, oldAgent, newAgent);
    }

    /**
     * @param consensusAddress the consensus address of the validator
     * @param voteAddress the vote address of the validator
     * @param blsProof the bls proof of the vote address
     * @param commission the commission of the validator
     * @param description the description of the validator
     */
    function createValidator(
        address consensusAddress,
        bytes calldata voteAddress,
        bytes calldata blsProof,
        Commission calldata commission,
        Description calldata description
    ) external payable whenNotPaused notInBlackList {
        // basic check
        address operatorAddress = msg.sender;
        if (_validatorSet.contains(operatorAddress)) revert ValidatorExisted();
        if (agentToOperator[operatorAddress] != address(0)) revert InvalidValidator();
        if (_validatorSet.length() >= MAX_REGISTERED_VALIDATORS) revert TooManyValidators();

        if (consensusToOperator[consensusAddress] != address(0)) {
            revert DuplicateConsensusAddress();
        }
        if (voteToOperator[voteAddress] != address(0)) {
            revert DuplicateVoteAddress();
        }
        bytes32 monikerHash = keccak256(abi.encodePacked(description.moniker));
        if (_monikerSet[monikerHash]) revert DuplicateMoniker();

        uint256 delegation = msg.value - LOCK_AMOUNT; // create validator need to lock 1 BNB
        if (delegation < minSelfDelegationBNB) revert SelfDelegationNotEnough();

        if (consensusAddress == address(0)) revert InvalidConsensusAddress();
        if (
            commission.maxRate > 5_000 || commission.rate > commission.maxRate
                || commission.maxChangeRate > commission.maxRate
        ) revert InvalidCommission();
        if (!_checkMoniker(description.moniker)) revert InvalidMoniker();
        // the vote address is only an identifier derived from the consensus address
        if (!_checkVoteAddress(consensusAddress, voteAddress)) revert InvalidVoteAddress();
        // ML-DSA proof of possession of the consensus key (blsProof carries it)
        if (!_checkConsensusProof(consensusAddress, operatorAddress, blsProof)) revert InvalidConsensusAddress();

        // deploy stake credit proxy contract
        address creditContract = _deployStakeCredit(operatorAddress, description.moniker);

        _validatorSet.add(operatorAddress);
        _monikerSet[monikerHash] = true;
        Validator storage valInfo = _validators[operatorAddress];
        valInfo.consensusAddress = consensusAddress;
        valInfo.operatorAddress = operatorAddress;
        valInfo.creditContract = creditContract;
        valInfo.createdTime = block.timestamp;
        valInfo.voteAddress = voteAddress;
        valInfo.description = description;
        valInfo.commission = commission;
        valInfo.updateTime = block.timestamp;
        consensusToOperator[consensusAddress] = operatorAddress;
        voteToOperator[voteAddress] = operatorAddress;

        emit ValidatorCreated(consensusAddress, operatorAddress, creditContract, voteAddress);
        emit Delegated(operatorAddress, operatorAddress, delegation, delegation);
        emit Delegated(operatorAddress, DEAD_ADDRESS, LOCK_AMOUNT, LOCK_AMOUNT);

        IGovToken(GOV_TOKEN_ADDR).sync(creditContract, operatorAddress);
    }

    /**
     * @param newConsensusAddress the new consensus address of the validator
     * @param consensusProof ML-DSA proof of possession of the new consensus key
     */
    function editConsensusAddress(
        address newConsensusAddress,
        bytes calldata consensusProof
    ) external whenNotPaused notInBlackList validatorExist(_bep410MsgSender()) {
        if (newConsensusAddress == address(0)) revert InvalidConsensusAddress();
        if (consensusToOperator[newConsensusAddress] != address(0)) {
            revert DuplicateConsensusAddress();
        }

        address operatorAddress = _bep410MsgSender();
        if (!_checkConsensusProof(newConsensusAddress, operatorAddress, consensusProof)) {
            revert InvalidConsensusAddress();
        }
        Validator storage valInfo = _validators[operatorAddress];
        if (valInfo.updateTime + BREATHE_BLOCK_INTERVAL > block.timestamp) revert UpdateTooFrequently();
        _checkRotationLiveness(operatorAddress);

        consensusRotatedAt[operatorAddress] = block.timestamp;
        consensusExpiration[valInfo.consensusAddress] = block.timestamp;
        valInfo.consensusAddress = newConsensusAddress;
        valInfo.updateTime = block.timestamp;
        consensusToOperator[newConsensusAddress] = operatorAddress;

        // The vote identifier is derived from the consensus address; keep them in step.
        bytes memory newVoteAddress = bytes.concat(bytes4("FLPQ"), bytes24(0), bytes20(newConsensusAddress));
        voteExpiration[valInfo.voteAddress] = block.timestamp;
        valInfo.voteAddress = newVoteAddress;
        voteToOperator[newVoteAddress] = operatorAddress;
        emit VoteAddressEdited(operatorAddress, newVoteAddress);

        emit ConsensusAddressEdited(operatorAddress, newConsensusAddress);
    }

    /**
     * @dev The node rejects blocks sealed by a replaced consensus key from the
     * next block on, while the new key only seals once the next breathe block and
     * epoch have put it in Parlia's validator set. Parlia needs floor(n/2)+1 of
     * the n current validators able to seal (recents rule), so a rotation of a
     * current validator is refused if it would leave fewer than that, counting
     * the rotations that have not settled yet.
     */
    function _checkRotationLiveness(
        address operatorAddress
    ) internal view {
        address[] memory current = IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).getValidators();
        uint256 n = current.length;
        bool isCurrent;
        uint256 unavailable;
        for (uint256 i; i < n; ++i) {
            address op = consensusToOperator[current[i]];
            if (op != address(0) && op == operatorAddress) {
                isCurrent = true;
                continue;
            }
            // a rotation that has not settled yet: that validator cannot seal
            if (op != address(0)) {
                uint256 rotatedAt = consensusRotatedAt[op];
                if (rotatedAt != 0 && rotatedAt + ROTATION_SETTLE_TIME > block.timestamp) {
                    ++unavailable;
                    continue;
                }
            }
            // a validator that missed a turn recently is probably offline
            (uint256 missedAt,) = ISlashIndicatorMisses(SLASH_CONTRACT_ADDR).getSlashIndicator(current[i]);
            if (missedAt != 0 && missedAt + RECENT_MISS_BLOCKS >= block.number) ++unavailable;
        }
        if (isCurrent && n < unavailable + 1 + n / 2 + 1) revert TooManyPendingRotations();
    }

    /**
     * @param commissionRate the new commission rate of the validator
     */
    function editCommissionRate(
        uint64 commissionRate
    ) external whenNotPaused notInBlackList validatorExist(_bep410MsgSender()) {
        address operatorAddress = _bep410MsgSender();
        Validator storage valInfo = _validators[operatorAddress];
        if (valInfo.updateTime + BREATHE_BLOCK_INTERVAL > block.timestamp) revert UpdateTooFrequently();

        if (commissionRate > valInfo.commission.maxRate) revert InvalidCommission();
        uint256 changeRate = commissionRate >= valInfo.commission.rate
            ? commissionRate - valInfo.commission.rate
            : valInfo.commission.rate - commissionRate;
        if (changeRate > valInfo.commission.maxChangeRate) revert InvalidCommission();

        valInfo.commission.rate = commissionRate;
        valInfo.updateTime = block.timestamp;

        emit CommissionRateEdited(operatorAddress, commissionRate);
    }

    /**
     * @notice the moniker of the validator will be ignored as it is not editable
     * @param description the new description of the validator
     */
    function editDescription(
        Description memory description
    ) external whenNotPaused notInBlackList validatorExist(_bep410MsgSender()) {
        address operatorAddress = _bep410MsgSender();
        Validator storage valInfo = _validators[operatorAddress];
        if (valInfo.updateTime + BREATHE_BLOCK_INTERVAL > block.timestamp) revert UpdateTooFrequently();

        description.moniker = valInfo.description.moniker;
        valInfo.description = description;
        valInfo.updateTime = block.timestamp;

        emit DescriptionEdited(operatorAddress);
    }

    /**
     * @param newVoteAddress the new vote address of the validator
     * @param blsProof the bls proof of the vote address
     */
    function editVoteAddress(
        bytes calldata newVoteAddress,
        bytes calldata blsProof
    ) external whenNotPaused notInBlackList validatorExist(_bep410MsgSender()) {
        // Final Layer has no BLS vote keys; the identifier is fixed at creation.
        newVoteAddress;
        blsProof;
        revert InvalidVoteAddress();
    }

    /**
     * @param operatorAddress the operator address of the validator to be unjailed
     */
    function unjail(
        address operatorAddress
    ) external whenNotPaused notInBlackList validatorExist(operatorAddress) {
        Validator storage valInfo = _validators[operatorAddress];
        if (!valInfo.jailed) revert ValidatorNotJailed();

        if (IStakeCredit(valInfo.creditContract).getPooledBNB(operatorAddress) < minSelfDelegationBNB) {
            revert SelfDelegationNotEnough();
        }
        if (valInfo.jailUntil > block.timestamp) revert JailTimeNotExpired();

        valInfo.jailed = false;
        numOfJailed -= 1;
        emit ValidatorUnjailed(operatorAddress);
    }

    /**
     * @param operatorAddress the operator address of the validator to be delegated to
     * @param delegateVotePower whether to delegate vote power to the validator
     */
    function delegate(
        address operatorAddress,
        bool delegateVotePower
    ) external payable whenNotPaused notInBlackList validatorExist(operatorAddress) {
        uint256 bnbAmount = msg.value;
        if (bnbAmount < minDelegationBNBChange) revert DelegationAmountTooSmall();

        address delegator = msg.sender;
        Validator memory valInfo = _validators[operatorAddress];
        if (valInfo.jailed && delegator != operatorAddress) revert OnlySelfDelegation();

        uint256 shares = IStakeCredit(valInfo.creditContract).delegate{ value: bnbAmount }(delegator);
        emit Delegated(operatorAddress, delegator, shares, bnbAmount);

        IGovToken(GOV_TOKEN_ADDR).sync(valInfo.creditContract, delegator);
        if (delegateVotePower) {
            IGovToken(GOV_TOKEN_ADDR).delegateVote(delegator, operatorAddress);
        }
    }

    /**
     * @dev Undelegate BNB from a validator, fund is only claimable few days later
     * @param operatorAddress the operator address of the validator to be undelegated from
     * @param shares the shares to be undelegated
     */
    function undelegate(
        address operatorAddress,
        uint256 shares
    ) external whenNotPaused notInBlackList validatorExist(operatorAddress) {
        if (shares == 0) revert ZeroShares();

        address delegator = msg.sender;
        Validator memory valInfo = _validators[operatorAddress];

        uint256 bnbAmount = IStakeCredit(valInfo.creditContract).undelegate(delegator, shares);
        emit Undelegated(operatorAddress, delegator, shares, bnbAmount);

        if (delegator == operatorAddress) {
            _checkValidatorSelfDelegation(operatorAddress);
        }

        IGovToken(GOV_TOKEN_ADDR).sync(valInfo.creditContract, delegator);
    }

    /**
     * @param srcValidator the operator address of the validator to be redelegated from
     * @param dstValidator the operator address of the validator to be redelegated to
     * @param shares the shares to be redelegated
     * @param delegateVotePower whether to delegate vote power to the dstValidator
     */
    function redelegate(
        address srcValidator,
        address dstValidator,
        uint256 shares,
        bool delegateVotePower
    )
        external
        whenNotPaused
        notInBlackList
        validatorExist(srcValidator)
        validatorExist(dstValidator)
        enableReceivingFund
    {
        if (shares == 0) revert ZeroShares();
        if (srcValidator == dstValidator) revert SameValidator();

        address delegator = msg.sender;
        Validator memory srcValInfo = _validators[srcValidator];
        Validator memory dstValInfo = _validators[dstValidator];
        if (dstValInfo.jailed && delegator != dstValidator) revert OnlySelfDelegation();

        uint256 bnbAmount = IStakeCredit(srcValInfo.creditContract).unbond(delegator, shares);
        if (bnbAmount < minDelegationBNBChange) revert DelegationAmountTooSmall();
        // check if the srcValidator has enough self delegation
        if (
            delegator == srcValidator
                && IStakeCredit(srcValInfo.creditContract).getPooledBNB(srcValidator) < minSelfDelegationBNB
        ) {
            revert SelfDelegationNotEnough();
        }

        uint256 feeCharge = bnbAmount * redelegateFeeRate / REDELEGATE_FEE_RATE_BASE;
        (bool success,) = dstValInfo.creditContract.call{ value: feeCharge }("");
        if (!success) revert TransferFailed();

        bnbAmount -= feeCharge;
        uint256 newShares = IStakeCredit(dstValInfo.creditContract).delegate{ value: bnbAmount }(delegator);
        emit Redelegated(srcValidator, dstValidator, delegator, shares, newShares, bnbAmount);

        address[] memory stakeCredits = new address[](2);
        stakeCredits[0] = srcValInfo.creditContract;
        stakeCredits[1] = dstValInfo.creditContract;
        IGovToken(GOV_TOKEN_ADDR).syncBatch(stakeCredits, delegator);
        if (delegateVotePower) {
            IGovToken(GOV_TOKEN_ADDR).delegateVote(delegator, dstValidator);
        }
    }

    /**
     * @dev Claim the undelegated BNB from the pool after unbondPeriod
     * @param operatorAddress the operator address of the validator
     * @param requestNumber the request number of the undelegation. 0 means claim all
     */
    function claim(address operatorAddress, uint256 requestNumber) external whenNotPaused notInBlackList {
        _claim(operatorAddress, requestNumber);
    }

    /**
     * @dev Claim the undelegated BNB from the pools after unbondPeriod
     * @param operatorAddresses the operator addresses of the validator
     * @param requestNumbers numbers of the undelegation requests. 0 means claim all
     */
    function claimBatch(
        address[] calldata operatorAddresses,
        uint256[] calldata requestNumbers
    ) external whenNotPaused notInBlackList {
        if (operatorAddresses.length != requestNumbers.length) revert InvalidRequest();
        for (uint256 i; i < operatorAddresses.length; ++i) {
            _claim(operatorAddresses[i], requestNumbers[i]);
        }
    }

    /**
     * @dev Sync the gov tokens of validators in operatorAddresses
     * @param operatorAddresses the operator addresses of the validators
     * @param account the account to sync gov tokens to
     */
    function syncGovToken(
        address[] calldata operatorAddresses,
        address account
    ) external whenNotPaused notInBlackList {
        uint256 _length = operatorAddresses.length;
        address[] memory stakeCredits = new address[](_length);
        address credit;
        for (uint256 i = 0; i < _length; ++i) {
            if (!_validatorSet.contains(operatorAddresses[i])) revert ValidatorNotExisted();
            credit = _validators[operatorAddresses[i]].creditContract;
            stakeCredits[i] = credit;
        }

        IGovToken(GOV_TOKEN_ADDR).syncBatch(stakeCredits, account);
    }

    /*----------------- system functions -----------------*/
    /**
     * @dev This function will be called by consensus engine. So it should never revert.
     */
    function distributeReward(
        address consensusAddress
    ) external payable onlyValidatorContract {
        address operatorAddress = consensusToOperator[consensusAddress];
        Validator memory valInfo = _validators[operatorAddress];
        if (valInfo.creditContract == address(0) || valInfo.jailed) {
            SYSTEM_REWARD_ADDR.call{ value: msg.value }("");
            emit RewardDistributeFailed(operatorAddress, "INVALID_VALIDATOR");
            return;
        }

        IStakeCredit(valInfo.creditContract).distributeReward{ value: msg.value }(valInfo.commission.rate);
        emit RewardDistributed(operatorAddress, msg.value);

        IGovToken(GOV_TOKEN_ADDR).sync(valInfo.creditContract, operatorAddress);
    }

    /**
     * @notice Amount of new FL the consensus engine mints at the breathe block
     * whose timestamp is `timestamp`, given the current state:
     * accruedInflation + snapshotStake * apr * (1 + validatorReward) * elapsed / 1 year.
     * snapshotStake is the stake of the working (elected, not jailed) validators
     * taken at the previous breathe block, so it depends only on state written
     * by the previous distribution and by governance, never on transactions of
     * the breathe block itself. elapsed is capped at MAX_INFLATION_PERIOD.
     */
    function pendingStakingInflation(
        uint256 timestamp
    ) public view returns (uint256 total) {
        total = accruedInflation;
        if (lastInflationTime == 0 || timestamp <= lastInflationTime) return total;
        total += _inflationFor(timestamp - lastInflationTime);
    }

    function _inflationFor(
        uint256 elapsed
    ) internal view returns (uint256) {
        if (elapsed > MAX_INFLATION_PERIOD) elapsed = MAX_INFLATION_PERIOD;
        return (inflationWeightTotal * stakingAprBps * (10_000 + validatorRewardBps) * elapsed)
            / (100_000_000 * INFLATION_YEAR);
    }

    /**
     * @dev Books the inflation earned so far at the current rates before a rate
     * changes, so a new rate only applies from now on.
     */
    function _checkpointInflation() internal {
        if (lastInflationTime == 0 || block.timestamp <= lastInflationTime) return;
        // All unpaid time is booked at the rates in force while it passed,
        // including a backlog longer than MAX_INFLATION_PERIOD after a halt.
        uint256 elapsed = block.timestamp - lastInflationTime;
        uint256 amount = (inflationWeightTotal * stakingAprBps * (10_000 + validatorRewardBps) * elapsed)
            / (100_000_000 * INFLATION_YEAR);
        accruedInflation += amount;
        accruedValidatorInflation += (amount * validatorRewardBps) / (10_000 + validatorRewardBps);
        lastInflationTime = block.timestamp;
    }

    /**
     * @dev Called by the consensus engine once per breathe block (daily) with the
     * newly minted inflation as msg.value. It never reverts: every external call
     * is guarded, and FL that cannot be paid now is kept and paid later.
     * Each pool of the previous snapshot receives a share proportional to its
     * snapshot stake. The delegators' part is added to the pool (raising the
     * share price, so every delegator earns the APR); the validator part is
     * minted to the validator as commission shares. Then a new snapshot is taken.
     * This system transaction counts towards the block gas limit, so its work is
     * bounded by MAX_INFLATION_VALIDATORS, never by the number of registered
     * validators.
     */
    function distributeStakingInflation() external payable onlyCoinbase onlyZeroGasPrice {
        uint256 elapsed;
        if (lastInflationTime != 0 && block.timestamp > lastInflationTime) {
            elapsed = block.timestamp - lastInflationTime;
            if (elapsed > MAX_INFLATION_PERIOD) elapsed = MAX_INFLATION_PERIOD;
        }
        if (lastInflationTime == 0) lastInflationTime = block.timestamp;
        else lastInflationTime += elapsed;
        // The part of msg.value that was booked at earlier rates keeps the
        // staker/validator split it was earned with.
        uint256 accPart = accruedInflation < msg.value ? accruedInflation : msg.value;
        uint256 accValidatorPart =
            accruedInflation == 0 ? 0 : (accruedValidatorInflation * accPart) / accruedInflation;
        accruedInflation = 0;
        accruedValidatorInflation = 0;
        emit StakingInflationDistributed(msg.value, elapsed);

        uint256 n = _inflationOperators.length;
        // retry earlier failed payouts of the snapshot pools first
        for (uint256 i; i < n; ++i) {
            _retryPending(_inflationOperators[i]);
        }

        // Pools that do not earn this time (jailed, or consensus key rotated
        // since the snapshot) are left out of the split, so their share goes to
        // the other pools now and can never flow back to them later.
        uint256 eligibleTotal;
        for (uint256 i; i < n; ++i) {
            if (_earnsInflation(_inflationOperators[i])) eligibleTotal += _inflationWeights[i];
        }
        uint256 freshPart = msg.value - accPart + inflationCarry;
        uint256 remaining = accPart + freshPart;
        if (remaining > 0 && eligibleTotal > 0) {
            uint256 denominator = 10_000 + validatorRewardBps;
            for (uint256 i; i < n; ++i) {
                address operatorAddress = _inflationOperators[i];
                if (!_earnsInflation(operatorAddress)) continue;
                uint256 w = _inflationWeights[i];
                uint256 shareAcc = (accPart * w) / eligibleTotal;
                uint256 shareFresh = (freshPart * w) / eligibleTotal;
                uint256 share = shareAcc + shareFresh;
                if (share == 0 || share > remaining) continue;
                remaining -= share;
                uint256 validatorPart =
                    (accValidatorPart * w) / eligibleTotal + (shareFresh * validatorRewardBps) / denominator;
                if (validatorPart > share) validatorPart = share;
                _payInflation(operatorAddress, _inflationCredits[i], share - validatorPart, validatorPart);
            }
        }
        inflationCarry = remaining;

        _snapshotInflationRecipients();
    }

    /**
     * @dev Whether a pool of the inflation snapshot earns at this distribution:
     * not jailed, and its consensus key not rotated since the snapshot (it could
     * not seal until the new key was installed, and is exempt from downtime
     * slashing for that time).
     */
    function _earnsInflation(
        address operatorAddress
    ) internal view returns (bool) {
        if (_validators[operatorAddress].jailed) return false;
        uint256 rotatedAt = consensusRotatedAt[operatorAddress];
        return rotatedAt == 0 || rotatedAt < inflationSnapshotTime;
    }

    /**
     * @notice Pays out staking inflation a pool failed to accept earlier.
     * Anyone can call it.
     */
    function retryStakingInflation(
        address operatorAddress
    ) external {
        _retryPending(operatorAddress);
    }

    function _retryPending(
        address operatorAddress
    ) internal {
        uint256 stakerPart = pendingStakerInflation[operatorAddress];
        uint256 validatorPart = pendingValidatorInflation[operatorAddress];
        if (stakerPart == 0 && validatorPart == 0) return;
        Validator storage valInfo = _validators[operatorAddress];
        if (valInfo.jailed || valInfo.creditContract == address(0)) return;
        pendingStakerInflation[operatorAddress] = 0;
        pendingValidatorInflation[operatorAddress] = 0;
        emit StakingInflationRetried(operatorAddress, stakerPart + validatorPart);
        _payInflation(operatorAddress, valInfo.creditContract, stakerPart, validatorPart);
    }

    function _payInflation(
        address operatorAddress,
        address credit,
        uint256 stakerPart,
        uint256 validatorPart
    ) internal {
        if (stakerPart > 0) {
            try IStakeCredit(credit).distributeReward{ value: stakerPart }(0) { }
            catch {
                pendingStakerInflation[operatorAddress] += stakerPart;
                emit StakingInflationFailed(operatorAddress, stakerPart);
            }
        }
        if (validatorPart > 0) {
            try IStakeCredit(credit).distributeReward{ value: validatorPart }(10_000) { }
            catch {
                pendingValidatorInflation[operatorAddress] += validatorPart;
                emit StakingInflationFailed(operatorAddress, validatorPart);
            }
        }
        try IGovToken(GOV_TOKEN_ADDR).sync(credit, operatorAddress) { } catch { }
    }

    /**
     * @dev Records the current working validators and their stake as the weights
     * of the next distribution. A pool whose stake cannot be read gets weight 0.
     */
    function _snapshotInflationRecipients() internal {
        delete _inflationOperators;
        delete _inflationCredits;
        delete _inflationWeights;
        uint256 total;
        (address[] memory credits, address[] memory operators, uint256 n) = _inflationRecipients();
        for (uint256 i; i < n; ++i) {
            uint256 weight;
            try IStakeCredit(credits[i]).totalPooledBNB() returns (uint256 pooled) {
                weight = pooled;
            } catch { }
            if (weight == 0) continue;
            _inflationOperators.push(operators[i]);
            _inflationCredits.push(credits[i]);
            _inflationWeights.push(weight);
            total += weight;
        }
        inflationWeightTotal = total;
        inflationSnapshotTime = block.timestamp;
    }

    /**
     * @notice The recipients and stake weights the next distribution pays by.
     */
    function getInflationSnapshot()
        external
        view
        returns (address[] memory operators, uint256[] memory weights, uint256 total)
    {
        return (_inflationOperators, _inflationWeights, inflationWeightTotal);
    }

    /**
     * @dev Validators that earn staking inflation: the working validators of the
     * current (elected) validator set that are registered here and not jailed.
     * Registering a validator is permissionless, so iterating every registered
     * validator would let anyone push the breathe block over the gas limit.
     */
    function _inflationRecipients()
        internal
        view
        returns (address[] memory credits, address[] memory operators, uint256 n)
    {
        address[] memory consensusAddrs = IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).getValidators();
        uint256 length = consensusAddrs.length;
        if (length > MAX_INFLATION_VALIDATORS) length = MAX_INFLATION_VALIDATORS;
        credits = new address[](length);
        operators = new address[](length);
        for (uint256 i; i < length; ++i) {
            address operatorAddress = consensusToOperator[consensusAddrs[i]];
            if (operatorAddress == address(0)) continue;
            Validator storage valInfo = _validators[operatorAddress];
            address credit = valInfo.creditContract;
            if (valInfo.jailed || credit == address(0)) continue;
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (operators[j] == operatorAddress) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            credits[n] = credit;
            operators[n] = operatorAddress;
            ++n;
        }
    }

    /**
     * @dev Downtime slash. Only the `SlashIndicator` contract can call this function.
     */
    function downtimeSlash(
        address consensusAddress
    ) external onlySlash {
        address operatorAddress = consensusToOperator[consensusAddress];
        if (!_validatorSet.contains(operatorAddress)) revert ValidatorNotExisted(); // should never happen
        Validator storage valInfo = _validators[operatorAddress];

        // slash
        uint256 slashAmount = IStakeCredit(valInfo.creditContract).slash(downtimeSlashAmount);
        uint256 jailUntil = block.timestamp + downtimeJailTime;
        _jailValidator(valInfo, jailUntil);

        emit ValidatorSlashed(operatorAddress, jailUntil, slashAmount, SlashType.DownTime);

        IGovToken(GOV_TOKEN_ADDR).sync(valInfo.creditContract, operatorAddress);
    }

    /**
     * @dev Malicious vote slash. Only the `SlashIndicator` contract can call this function.
     */
    function maliciousVoteSlash(
        bytes calldata voteAddress
    ) external onlySlash whenNotPaused {
        address operatorAddress = voteToOperator[voteAddress];
        if (!_validatorSet.contains(operatorAddress)) revert ValidatorNotExisted(); // should never happen
        Validator storage valInfo = _validators[operatorAddress];

        uint256 index = block.timestamp / BREATHE_BLOCK_INTERVAL;
        // This is to prevent many honest validators being slashed at the same time because of implementation bugs
        if (_felonyMap[index] >= maxFelonyBetweenBreatheBlock) revert NoMoreFelonyAllowed();
        _felonyMap[index] += 1;

        // check if the voteAddress has already expired
        if (voteExpiration[voteAddress] != 0 && voteExpiration[voteAddress] + BREATHE_BLOCK_INTERVAL < block.timestamp)
        {
            revert VoteAddressExpired();
        }

        // slash
        (bool canSlash, uint256 jailUntil) = _checkFelonyRecord(operatorAddress, SlashType.MaliciousVote);
        if (!canSlash) revert AlreadySlashed();
        uint256 slashAmount = IStakeCredit(valInfo.creditContract).slash(felonySlashAmount);
        _jailValidator(valInfo, jailUntil);
        // Evict using the post-rotation consensus key; SlashIndicator's voteAddr-based
        // eviction covers the case where BSCValidatorSet has not yet synced K_new.
        IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).felony(valInfo.consensusAddress);

        emit ValidatorSlashed(operatorAddress, jailUntil, slashAmount, SlashType.MaliciousVote);

        IGovToken(GOV_TOKEN_ADDR).sync(valInfo.creditContract, operatorAddress);
    }

    /**
     * @dev Double sign slash. Only the `SlashIndicator` contract can call this function.
     */
    function doubleSignSlash(
        address consensusAddress
    ) external onlySlash whenNotPaused {
        address operatorAddress = consensusToOperator[consensusAddress];
        if (!_validatorSet.contains(operatorAddress)) revert ValidatorNotExisted(); // should never happen
        Validator storage valInfo = _validators[operatorAddress];

        uint256 index = block.timestamp / BREATHE_BLOCK_INTERVAL;
        // This is to prevent many honest validators being slashed at the same time because of implementation bugs
        if (_felonyMap[index] >= maxFelonyBetweenBreatheBlock) revert NoMoreFelonyAllowed();
        _felonyMap[index] += 1;

        // check if the consensusAddress has already expired
        if (
            consensusExpiration[consensusAddress] != 0
                && consensusExpiration[consensusAddress] + BREATHE_BLOCK_INTERVAL < block.timestamp
        ) {
            revert ConsensusAddressExpired();
        }

        // slash
        (bool canSlash, uint256 jailUntil) = _checkFelonyRecord(operatorAddress, SlashType.DoubleSign);
        if (!canSlash) revert AlreadySlashed();
        uint256 slashAmount = IStakeCredit(valInfo.creditContract).slash(felonySlashAmount);
        _jailValidator(valInfo, jailUntil);
        // Evict using the post-rotation consensus key; SlashIndicator's felony(K_old)
        // covers the case where BSCValidatorSet has not yet synced K_new.
        IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).felony(valInfo.consensusAddress);

        emit ValidatorSlashed(operatorAddress, jailUntil, slashAmount, SlashType.DoubleSign);

        IGovToken(GOV_TOKEN_ADDR).sync(valInfo.creditContract, operatorAddress);
    }

    /**
     * @param key the key of the param
     * @param value the value of the param
     */
    function updateParam(string calldata key, bytes calldata value) external onlyGov {
        if (key.compareStrings("transferGasLimit")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newTransferGasLimit = value.bytesToUint256(32);
            if (newTransferGasLimit < 2300 || newTransferGasLimit > 10_000) revert InvalidValue(key, value);
            transferGasLimit = newTransferGasLimit;
        } else if (key.compareStrings("minSelfDelegationBNB")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newMinSelfDelegationBNB = value.bytesToUint256(32);
            if (newMinSelfDelegationBNB < MIN_SELF_DELEGATION_FLOOR || newMinSelfDelegationBNB > 10_000_000 ether) {
                revert InvalidValue(key, value);
            }
            minSelfDelegationBNB = newMinSelfDelegationBNB;
        } else if (key.compareStrings("minDelegationBNBChange")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newMinDelegationBNBChange = value.bytesToUint256(32);
            if (newMinDelegationBNBChange < 0.1 ether || newMinDelegationBNBChange > 10 ether) {
                revert InvalidValue(key, value);
            }
            minDelegationBNBChange = newMinDelegationBNBChange;
        } else if (key.compareStrings("maxElectedValidators")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newMaxElectedValidators = value.bytesToUint256(32);
            // every elected validator must be able to earn staking inflation
            if (newMaxElectedValidators == 0 || newMaxElectedValidators > MAX_INFLATION_VALIDATORS) {
                revert InvalidValue(key, value);
            }
            maxElectedValidators = newMaxElectedValidators;
        } else if (key.compareStrings("unbondPeriod")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newUnbondPeriod = value.bytesToUint256(32);
            if (newUnbondPeriod < 3 days || newUnbondPeriod > 30 days) revert InvalidValue(key, value);
            unbondPeriod = newUnbondPeriod;
        } else if (key.compareStrings("redelegateFeeRate")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newRedelegateFeeRate = value.bytesToUint256(32);
            if (newRedelegateFeeRate > 100) {
                revert InvalidValue(key, value);
            }
            redelegateFeeRate = newRedelegateFeeRate;
        } else if (key.compareStrings("downtimeSlashAmount")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newDowntimeSlashAmount = value.bytesToUint256(32);
            if (newDowntimeSlashAmount < 1 ether || newDowntimeSlashAmount >= felonySlashAmount) {
                revert InvalidValue(key, value);
            }
            downtimeSlashAmount = newDowntimeSlashAmount;
        } else if (key.compareStrings("felonySlashAmount")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newFelonySlashAmount = value.bytesToUint256(32);
            if (newFelonySlashAmount < 10 ether || newFelonySlashAmount <= downtimeSlashAmount) {
                revert InvalidValue(key, value);
            }
            felonySlashAmount = newFelonySlashAmount;
        } else if (key.compareStrings("downtimeJailTime")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newDowntimeJailTime = value.bytesToUint256(32);
            if (newDowntimeJailTime < 1 days || newDowntimeJailTime >= felonyJailTime) revert InvalidValue(key, value);
            downtimeJailTime = newDowntimeJailTime;
        } else if (key.compareStrings("felonyJailTime")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newFelonyJailTime = value.bytesToUint256(32);
            if (newFelonyJailTime < 3 days || newFelonyJailTime <= downtimeJailTime) revert InvalidValue(key, value);
            felonyJailTime = newFelonyJailTime;
        } else if (key.compareStrings("maxFelonyBetweenBreatheBlock")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newJailedPerDay = value.bytesToUint256(32);
            if (newJailedPerDay == 0) revert InvalidValue(key, value);
            maxFelonyBetweenBreatheBlock = newJailedPerDay;
        } else if (key.compareStrings("stakeHubProtector")) {
            if (value.length != 20) revert InvalidValue(key, value);
            address newStakeHubProtector = value.bytesToAddress(20);
            if (newStakeHubProtector == address(0)) revert InvalidValue(key, value);
            _setProtector(newStakeHubProtector);
        } else if (key.compareStrings("stakingAprBps")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newStakingAprBps = value.bytesToUint256(32);
            if (newStakingAprBps > MAX_STAKING_APR_BPS) revert InvalidValue(key, value);
            _checkpointInflation();
            stakingAprBps = newStakingAprBps;
        } else if (key.compareStrings("validatorRewardBps")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newValidatorRewardBps = value.bytesToUint256(32);
            if (newValidatorRewardBps > MAX_VALIDATOR_REWARD_BPS) revert InvalidValue(key, value);
            _checkpointInflation();
            validatorRewardBps = newValidatorRewardBps;
        } else if (key.compareStrings("maxNodeIDs")) {
            if (value.length != 32) revert InvalidValue(key, value);
            uint256 newMaxNodeIDs = value.bytesToUint256(32);
            if (newMaxNodeIDs == 0) revert InvalidValue(key, value);
            maxNodeIDs = newMaxNodeIDs;
        } else {
            revert UnknownParam(key, value);
        }
        emit ParamChange(key, value);
    }

    /*----------------- view functions -----------------*/
    /**
     * @param operatorAddress the operator address of the validator
     * @param index the index of the day to query(timestamp / 1 days)
     *
     * @return the validator's reward of the day
     */
    function getValidatorRewardRecord(address operatorAddress, uint256 index) external view returns (uint256) {
        if (!_validatorSet.contains(operatorAddress)) revert ValidatorNotExisted();
        return IStakeCredit(_validators[operatorAddress].creditContract).rewardRecord(index);
    }

    /**
     * @param operatorAddress the operator address of the validator
     * @param index the index of the day to query(timestamp / 1 days)
     *
     * @return the validator's total pooled BNB of the day
     */
    function getValidatorTotalPooledBNBRecord(address operatorAddress, uint256 index) external view returns (uint256) {
        if (!_validatorSet.contains(operatorAddress)) revert ValidatorNotExisted();
        return IStakeCredit(_validators[operatorAddress].creditContract).totalPooledBNBRecord(index);
    }

    /**
     * @notice pagination query all validators' operator address and credit contract address
     *
     * @param offset the offset of the query
     * @param limit the limit of the query
     *
     * @return operatorAddrs operator addresses
     * @return creditAddrs credit contract addresses
     * @return totalLength total number of validators
     */
    function getValidators(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory operatorAddrs, address[] memory creditAddrs, uint256 totalLength) {
        totalLength = _validatorSet.length();
        if (offset >= totalLength) {
            return (operatorAddrs, creditAddrs, totalLength);
        }

        limit = limit == 0 ? totalLength : limit;
        uint256 count = (totalLength - offset) > limit ? limit : (totalLength - offset);
        operatorAddrs = new address[](count);
        creditAddrs = new address[](count);
        for (uint256 i; i < count; ++i) {
            operatorAddrs[i] = _validatorSet.at(offset + i);
            creditAddrs[i] = _validators[operatorAddrs[i]].creditContract;
        }
    }

    /**
     * @notice get the consensus address of a validator
     *
     * @param operatorAddress the operator address of the validator
     *
     * @return consensusAddress the consensus address of the validator
     */
    function getValidatorConsensusAddress(
        address operatorAddress
    ) external view returns (address consensusAddress) {
        Validator memory valInfo = _validators[operatorAddress];
        consensusAddress = valInfo.consensusAddress;
    }

    /**
     * @notice get the credit contract address of a validator
     *
     * @param operatorAddress the operator address of the validator
     *
     * @return creditContract the credit contract address of the validator
     */
    function getValidatorCreditContract(
        address operatorAddress
    ) external view returns (address creditContract) {
        Validator memory valInfo = _validators[operatorAddress];
        creditContract = valInfo.creditContract;
    }

    /**
     * @notice get the vote address of a validator
     *
     * @param operatorAddress the operator address of the validator
     *
     * @return voteAddress the vote address of the validator
     */
    function getValidatorVoteAddress(
        address operatorAddress
    ) external view returns (bytes memory voteAddress) {
        Validator memory valInfo = _validators[operatorAddress];
        voteAddress = valInfo.voteAddress;
    }

    /**
     * @notice get the basic info of a validator
     *
     * @param operatorAddress the operator address of the validator
     *
     * @return createdTime the creation time of the validator
     * @return jailed whether the validator is jailed
     * @return jailUntil the jail time of the validator
     */
    function getValidatorBasicInfo(
        address operatorAddress
    ) external view returns (uint256 createdTime, bool jailed, uint256 jailUntil) {
        Validator memory valInfo = _validators[operatorAddress];
        createdTime = valInfo.createdTime;
        jailed = valInfo.jailed;
        jailUntil = valInfo.jailUntil;
    }

    /**
     * @param operatorAddress the operator address of the validator
     *
     * @return the description of a validator
     */
    function getValidatorDescription(
        address operatorAddress
    ) external view validatorExist(operatorAddress) returns (Description memory) {
        return _validators[operatorAddress].description;
    }

    /**
     * @param operatorAddress the operator address of the validator
     *
     * @return the commission of a validator
     */
    function getValidatorCommission(
        address operatorAddress
    ) external view validatorExist(operatorAddress) returns (Commission memory) {
        return _validators[operatorAddress].commission;
    }

    /**
     * @param operatorAddress the operator address of the validator
     *
     * @return the agent of a validator
     */
    function getValidatorAgent(
        address operatorAddress
    ) external view validatorExist(operatorAddress) returns (address) {
        return _validators[operatorAddress].agent;
    }

    /**
     * @param operatorAddress the operator address of the validator
     *
     * @return the updateTime of a validator
     */
    function getValidatorUpdateTime(
        address operatorAddress
    ) external view validatorExist(operatorAddress) returns (uint256) {
        return _validators[operatorAddress].updateTime;
    }

    /**
     * @dev this function will be used by Parlia consensus engine.
     *
     * @notice get the election info of a validator
     *
     * @param offset the offset of the query
     * @param limit the limit of the query
     *
     * @return consensusAddrs the consensus addresses of the validators
     * @return votingPowers the voting powers of the validators. The voting power will be 0 if the validator is jailed.
     * @return voteAddrs the vote addresses of the validators
     * @return totalLength the total number of validators
     */
    function getValidatorElectionInfo(
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (
            address[] memory consensusAddrs,
            uint256[] memory votingPowers,
            bytes[] memory voteAddrs,
            uint256 totalLength
        )
    {
        totalLength = _validatorSet.length();
        if (offset >= totalLength) {
            return (consensusAddrs, votingPowers, voteAddrs, totalLength);
        }

        limit = limit == 0 ? totalLength : limit;
        uint256 count = (totalLength - offset) > limit ? limit : (totalLength - offset);
        consensusAddrs = new address[](count);
        votingPowers = new uint256[](count);
        voteAddrs = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            address operatorAddress = _validatorSet.at(offset + i);
            Validator memory valInfo = _validators[operatorAddress];
            consensusAddrs[i] = valInfo.consensusAddress;
            votingPowers[i] = valInfo.jailed ? 0 : IStakeCredit(valInfo.creditContract).totalPooledBNB();
            voteAddrs[i] = valInfo.voteAddress;
        }
    }

    /**
     * @notice Adds multiple new NodeIDs to the validator's registry.
     * @param nodeIDs Array of NodeIDs to be added.
     */
    function addNodeIDs(
        bytes32[] calldata nodeIDs
    ) external whenNotPaused notInBlackList validatorExist(_bep563MsgSender()) {
        maxNodeIDsInitializer();

        if (nodeIDs.length == 0) {
            revert InvalidNodeID();
        }

        address operatorAddress = _bep563MsgSender();
        bytes32[] storage existingNodeIDs = validatorNodeIDs[operatorAddress];
        uint256 currentLength = existingNodeIDs.length;

        if (currentLength + nodeIDs.length > maxNodeIDs) {
            revert ExceedsMaxNodeIDs();
        }

        // Check for duplicates in new NodeIDs
        for (uint256 i = 0; i < nodeIDs.length; i++) {
            if (nodeIDs[i] == bytes32(0)) {
                revert InvalidNodeID();
            }
            for (uint256 j = i + 1; j < nodeIDs.length; j++) {
                if (nodeIDs[i] == nodeIDs[j]) {
                    revert DuplicateNodeID();
                }
            }
        }

        // Check for duplicates in existing NodeIDs
        for (uint256 i = 0; i < nodeIDs.length; i++) {
            for (uint256 j = 0; j < currentLength; j++) {
                if (nodeIDs[i] == existingNodeIDs[j]) {
                    revert DuplicateNodeID();
                }
            }
        }

        // Add new NodeIDs
        for (uint256 i = 0; i < nodeIDs.length; i++) {
            existingNodeIDs.push(nodeIDs[i]);
            emit NodeIDAdded(operatorAddress, nodeIDs[i]);
        }
    }

    /**
     * @notice Removes multiple NodeIDs from the validator's registry.
     * @param targetNodeIDs Array of NodeIDs to be removed.
     */
    function removeNodeIDs(
        bytes32[] calldata targetNodeIDs
    ) external whenNotPaused notInBlackList validatorExist(_bep563MsgSender()) {
        address validator = _bep563MsgSender();
        bytes32[] storage nodeIDs = validatorNodeIDs[validator];
        uint256 length = nodeIDs.length;

        // If targetNodeIDs is empty, remove all NodeIDs
        if (targetNodeIDs.length == 0) {
            for (uint256 i = 0; i < length; i++) {
                emit NodeIDRemoved(validator, nodeIDs[i]);
            }
            delete validatorNodeIDs[validator];
            return;
        }

        // Otherwise, remove specific NodeIDs
        for (uint256 i = 0; i < targetNodeIDs.length; i++) {
            bytes32 nodeID = targetNodeIDs[i];
            for (uint256 j = 0; j < length; j++) {
                if (nodeIDs[j] == nodeID) {
                    // Swap and pop
                    nodeIDs[j] = nodeIDs[length - 1];
                    nodeIDs.pop();
                    length--;
                    emit NodeIDRemoved(validator, nodeID);
                    break;
                }
            }
        }

        // Clean up storage if no NodeIDs left
        if (nodeIDs.length == 0) {
            delete validatorNodeIDs[validator];
        }
    }

    /**
     * @notice Returns all validators with their consensus addresses and registered NodeIDs.
     * @param validatorsToQuery The operator addresses of the validators.
     * @return consensusAddresses Array of consensus addresses corresponding to the validators.
     * @return nodeIDsList Array of NodeIDs for each validator.
     */
    function getNodeIDs(
        address[] calldata validatorsToQuery
    ) external view returns (address[] memory consensusAddresses, bytes32[][] memory nodeIDsList) {
        uint256 len = validatorsToQuery.length;
        consensusAddresses = new address[](len);
        nodeIDsList = new bytes32[][](len);

        for (uint256 i = 0; i < len; i++) {
            address operator = validatorsToQuery[i];
            Validator memory valInfo = _validators[operator];
            consensusAddresses[i] = valInfo.consensusAddress;
            nodeIDsList[i] = validatorNodeIDs[operator];
        }

        return (consensusAddresses, nodeIDsList);
    }

    /*----------------- internal functions -----------------*/
    function _checkMoniker(
        string memory moniker
    ) internal pure returns (bool) {
        bytes memory bz = bytes(moniker);

        // 1. moniker length should be between 3 and 9
        if (bz.length < 3 || bz.length > 9) {
            return false;
        }

        // 2. first character should be uppercase
        if (uint8(bz[0]) < 65 || uint8(bz[0]) > 90) {
            return false;
        }

        // 3. only alphanumeric characters are allowed
        for (uint256 i = 1; i < bz.length; ++i) {
            // Check if the ASCII value of the character falls outside the range of alphanumeric characters
            if (
                (uint8(bz[i]) < 48 || uint8(bz[i]) > 57) && (uint8(bz[i]) < 65 || uint8(bz[i]) > 90)
                    && (uint8(bz[i]) < 97 || uint8(bz[i]) > 122)
            ) {
                // Character is a special character
                return false;
            }
        }

        // No special characters found
        return true;
    }

    /**
     * @dev Final Layer has no BLS fast finality. The vote address is kept only as
     * a 48 byte validator identifier: "FLPQ" || 24 zero bytes || consensus
     * address. Binding it to the consensus address (which needs a proof of
     * possession) stops anyone from front-running another validator's identifier.
     */
    function _checkVoteAddress(address consensusAddress, bytes calldata voteAddress) internal pure returns (bool) {
        return keccak256(voteAddress) == keccak256(bytes.concat(bytes4("FLPQ"), bytes24(0), bytes20(consensusAddress)));
    }

    /**
     * @dev ML-DSA-87 proof of possession of a consensus key.
     * proof = scheme(1) || publicKey(2592) || signature(4627). The key must derive
     * consensusAddress (last 20 bytes of keccak256(scheme || publicKey)) and the
     * signature must verify in the FinalLayer/contract/v1 domain (precompile
     * 0x0f01) over keccak256("FinalLayer/validator-pop/v1" || chainid ||
     * consensusAddress || operatorAddress).
     */
    function _checkConsensusProof(
        address consensusAddress,
        address operatorAddress,
        bytes calldata proof
    ) internal view returns (bool) {
        if (proof.length != PQ_PROOF_LENGTH || uint8(proof[0]) != PQ_SCHEME_MLDSA87) return false;
        if (address(uint160(uint256(keccak256(proof[:1 + PQ_PUBKEY_LENGTH])))) != consensusAddress) return false;
        bytes32 message = keccak256(
            abi.encodePacked("FinalLayer/validator-pop/v1", block.chainid, consensusAddress, operatorAddress)
        );
        (bool ok, bytes memory out) =
            PQ_VERIFY_PRECOMPILE.staticcall(bytes.concat(proof[:1], message, proof[1:]));
        return ok && out.length == 32 && abi.decode(out, (uint256)) == 1;
    }

    function _deployStakeCredit(address operatorAddress, string memory moniker) internal returns (address) {
        address creditProxy = address(new TransparentUpgradeableProxy(STAKE_CREDIT_ADDR, DEAD_ADDRESS, ""));
        IStakeCredit(creditProxy).initialize{ value: msg.value }(operatorAddress, moniker);
        emit StakeCreditInitialized(operatorAddress, creditProxy);

        return creditProxy;
    }

    function _checkValidatorSelfDelegation(
        address operatorAddress
    ) internal {
        Validator storage valInfo = _validators[operatorAddress];
        if (valInfo.jailed) {
            return;
        }
        if (IStakeCredit(valInfo.creditContract).getPooledBNB(operatorAddress) < minSelfDelegationBNB) {
            _jailValidator(valInfo, block.timestamp + downtimeJailTime);
            IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).felony(valInfo.consensusAddress);
        }
    }

    function _checkFelonyRecord(address operatorAddress, SlashType slashType) internal returns (bool, uint256) {
        bytes32 slashKey = keccak256(abi.encodePacked(operatorAddress, slashType));
        uint256 jailUntil = _felonyRecords[slashKey];
        // for double sign and malicious vote slash
        // if the validator is already jailed, no need to slash again
        if (jailUntil > block.timestamp) {
            return (false, 0);
        }
        jailUntil = block.timestamp + felonyJailTime;
        _felonyRecords[slashKey] = jailUntil;
        return (true, jailUntil);
    }

    function _jailValidator(Validator storage valInfo, uint256 jailUntil) internal {
        // keep the last eligible validator
        bool isLast = (numOfJailed >= _validatorSet.length() - 1);
        if (isLast) {
            // If staking channel is closed, then BC-fusion is finished and we should keep the last eligible validator here
            emit ValidatorEmptyJailed(valInfo.operatorAddress);
            return;
        }

        if (jailUntil > valInfo.jailUntil) {
            valInfo.jailUntil = jailUntil;
        }

        if (!valInfo.jailed) {
            valInfo.jailed = true;
            numOfJailed += 1;

            emit ValidatorJailed(valInfo.operatorAddress);
        }
    }

    function _claim(address operatorAddress, uint256 requestNumber) internal validatorExist(operatorAddress) {
        uint256 bnbAmount = IStakeCredit(_validators[operatorAddress].creditContract).claim(msg.sender, requestNumber);
        emit Claimed(operatorAddress, msg.sender, bnbAmount);
    }

    function _bep410MsgSender() internal view returns (address) {
        if (agentToOperator[msg.sender] != address(0)) {
            return agentToOperator[msg.sender];
        }

        return msg.sender;
    }

    function _bep563MsgSender() internal view returns (address) {
        // Rotated consensus addresses must no longer authorize validator-admin
        // actions, but the stale mapping is intentionally retained for system
        // paths such as slash/reward handling.
        if (consensusToOperator[msg.sender] != address(0) && consensusExpiration[msg.sender] == 0) {
            return consensusToOperator[msg.sender];
        }

        return _bep410MsgSender();
    }

    function maxNodeIDsInitializer() internal {
        if (maxNodeIDs == 0) {
            maxNodeIDs = INIT_MAX_NUMBER_NODE_ID;
        }
    }
}
