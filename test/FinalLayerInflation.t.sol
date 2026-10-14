pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import "../contracts/StakeHub.sol";

// Final Layer staking inflation: the system transaction that distributes the
// daily inflation is gas metered and counted in header.GasUsed, so its cost
// must stay bounded no matter how many validators register.
interface VmCool {
    function cool(address target) external;
}

interface IFLValidatorSet {
    function init() external;
    function updateValidatorSetV2(address[] memory, uint64[] memory, bytes[] memory) external;
    function getValidators() external view returns (address[] memory);
    function lastEvictionBlock() external view returns (uint256);
    function updateParam(string calldata key, bytes calldata value) external;
    function getTurnLength() external view returns (uint256);
    function MAX_CONSENSUS_VALIDATORS() external view returns (uint256);
    function RECOVERY_OFFSET_BLOCKS() external view returns (uint256);
    function deposit(address valAddr) external payable;
    function enterMaintenance() external;
    function isSystemRewardIncluded() external view returns (bool);
    function systemRewardBaseRatio() external view returns (uint256);
    function burnRatio() external view returns (uint256);
    function systemRewardAntiMEVRatio() external view returns (uint256);
}

interface IFLSystemReward {
    function claimRewards(address payable to, uint256 amount) external returns (uint256);
    function isOperator(address addr) external view returns (bool);
    function alreadyInit() external view returns (bool);
    function updateParam(string calldata key, bytes calldata value) external;
}

contract FinalLayerInflationTest is Test {
    address payable constant VALIDATOR_CONTRACT_ADDR = payable(0x0000000000000000000000000000000000001000);
    address payable constant STAKE_HUB_ADDR = payable(0x0000000000000000000000000000000000002002);
    address payable constant STAKE_CREDIT_ADDR = payable(0x0000000000000000000000000000000000002003);
    address constant GOV_TOKEN_ADDR = 0x0000000000000000000000000000000000002005;
    address constant GOV_HUB_ADDR = 0x0000000000000000000000000000000000001007;

    // Gas the miner reserves for ALL system transactions of a breathe block
    // (params.SystemTxsGasHardLimit). updateValidatorSetV2 needs most of it.
    uint256 constant SYSTEM_TXS_GAS_HARD_LIMIT = 20_000_000;

    StakeHub stakeHub = StakeHub(STAKE_HUB_ADDR);
    address coinbase = address(0xC0FFEE);
    uint256 nextUser = 1;
    address[] operators;
    address[] consensusAddrs;

    function setUp() public {
        vm.etch(VALIDATOR_CONTRACT_ADDR, vm.getDeployedCode("BSCValidatorSet.sol:BSCValidatorSet"));
        vm.etch(STAKE_HUB_ADDR, vm.getDeployedCode("StakeHub.sol:StakeHub"));
        vm.etch(STAKE_CREDIT_ADDR, vm.getDeployedCode("StakeCredit.sol:StakeCredit"));
        vm.etch(GOV_TOKEN_ADDR, vm.getDeployedCode("GovToken.sol:GovToken"));
        vm.coinbase(coinbase);
        vm.txGasPrice(0);
        vm.prank(coinbase);
        stakeHub.initialize();
        // no missed turns recorded unless a test says otherwise
        vm.mockCall(
            0x0000000000000000000000000000000000001001,
            abi.encodeWithSignature("getSlashIndicator(address)"),
            abi.encode(uint256(0), uint256(0))
        );
    }

    function _moniker(uint256 i) internal pure returns (string memory) {
        bytes memory b = new bytes(6);
        b[0] = "V";
        for (uint256 j = 5; j >= 1; --j) {
            b[j] = bytes1(uint8(65 + (i % 26)));
            i /= 26;
        }
        return string(b);
    }

    address constant PQ_VERIFY = address(0x0f01);
    uint256 constant PQ_PK_LEN = 2592;
    uint256 constant PQ_SIG_LEN = 4627;

    // A stand-in ML-DSA-87 public key: forge has no ML-DSA precompile, so the
    // signature check at 0x0f01 is mocked and these tests cover the binding
    // logic around it (derived address, message, vote identifier).
    function _fakePubKey(uint256 i) internal pure returns (bytes memory pk) {
        pk = new bytes(PQ_PK_LEN);
        bytes32 seed = keccak256(abi.encode("pk", i));
        for (uint256 j = 0; j < 32; j++) {
            pk[j] = seed[j];
        }
    }

    function _consensusOf(bytes memory pk) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes.concat(bytes1(0x01), pk)))));
    }

    function _proof(bytes memory pk) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(0x01), pk, new bytes(PQ_SIG_LEN));
    }

    function _voteId(address consensus) internal pure returns (bytes memory) {
        return bytes.concat(bytes4("FLPQ"), bytes24(0), bytes20(consensus));
    }

    function _popMessage(address consensus, address operator) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("FinalLayer/validator-pop/v1", block.chainid, consensus, operator));
    }

    // Mocks the precompile to accept exactly this (pk, message) pair.
    function _acceptPop(bytes memory pk, address consensus, address operator) internal {
        bytes memory input = bytes.concat(bytes1(0x01), _popMessage(consensus, operator), pk, new bytes(PQ_SIG_LEN));
        vm.mockCall(PQ_VERIFY, input, abi.encode(uint256(1)));
    }

    function _commission() internal pure returns (StakeHub.Commission memory) {
        return StakeHub.Commission({ rate: 1000, maxRate: 5000, maxChangeRate: 500 });
    }

    function _description(uint256 i) internal pure returns (StakeHub.Description memory) {
        return StakeHub.Description({ moniker: _moniker(i), identity: "", website: "", details: "" });
    }

    function _createValidator() internal {
        address operator = address(uint160(uint256(keccak256(abi.encode("op", nextUser)))));
        bytes memory pk = _fakePubKey(nextUser);
        address consensus = _consensusOf(pk);
        _acceptPop(pk, consensus, operator);
        uint256 value = 100_001 ether;
        vm.deal(operator, value);
        vm.prank(operator);
        stakeHub.createValidator{ value: value }(
            consensus, _voteId(consensus), _proof(pk), _commission(), _description(nextUser)
        );
        nextUser++;
        operators.push(operator);
        consensusAddrs.push(consensus);
    }

    function testLaunchParameters() public {
        assertEq(stakeHub.minSelfDelegationBNB(), 100_000 ether);
        assertEq(stakeHub.maxElectedValidators(), 21);
    }

    function testCreateValidatorRequiresProofOfPossession() public {
        address operator = address(0xA11CE);
        address attacker = address(0xBAD);
        bytes memory pk = _fakePubKey(777);
        address consensus = _consensusOf(pk);
        vm.deal(attacker, 200_000 ether);

        // No proof at all.
        vm.prank(attacker);
        vm.expectRevert(StakeHub.InvalidConsensusAddress.selector);
        stakeHub.createValidator{ value: 100_001 ether }(consensus, _voteId(consensus), "", _commission(), _description(1));

        // The victim's proof (made for its own operator) replayed by an attacker.
        _acceptPop(pk, consensus, operator);
        vm.prank(attacker);
        vm.expectRevert(StakeHub.InvalidConsensusAddress.selector);
        stakeHub.createValidator{ value: 100_001 ether }(
            consensus, _voteId(consensus), _proof(pk), _commission(), _description(1)
        );

        // A valid signature by a key that does not derive the consensus address.
        bytes memory otherPk = _fakePubKey(778);
        _acceptPop(otherPk, consensus, attacker);
        vm.prank(attacker);
        vm.expectRevert(StakeHub.InvalidConsensusAddress.selector);
        stakeHub.createValidator{ value: 100_001 ether }(
            consensus, _voteId(consensus), _proof(otherPk), _commission(), _description(1)
        );

        // Vote identifier not derived from the consensus address.
        _acceptPop(pk, consensus, attacker);
        vm.prank(attacker);
        vm.expectRevert(StakeHub.InvalidVoteAddress.selector);
        stakeHub.createValidator{ value: 100_001 ether }(
            consensus, _voteId(address(0x1234)), _proof(pk), _commission(), _description(1)
        );

        // Below the minimum self delegation.
        vm.prank(attacker);
        vm.expectRevert(StakeHub.SelfDelegationNotEnough.selector);
        stakeHub.createValidator{ value: 99_999 ether }(
            consensus, _voteId(consensus), _proof(pk), _commission(), _description(1)
        );

        // The real operator with a proof bound to it succeeds.
        _acceptPop(pk, consensus, operator);
        vm.deal(operator, 100_001 ether);
        vm.prank(operator);
        stakeHub.createValidator{ value: 100_001 ether }(
            consensus, _voteId(consensus), _proof(pk), _commission(), _description(1)
        );
        assertEq(stakeHub.getValidatorConsensusAddress(operator), consensus);
    }

    function testEditConsensusAddressRequiresProof() public {
        _createValidator();
        address operator = operators[0];
        vm.warp(block.timestamp + 2 days);
        bytes memory pk = _fakePubKey(999);
        address newConsensus = _consensusOf(pk);

        vm.prank(operator);
        vm.expectRevert(StakeHub.InvalidConsensusAddress.selector);
        stakeHub.editConsensusAddress(newConsensus, "");

        _acceptPop(pk, newConsensus, operator);
        vm.prank(operator);
        stakeHub.editConsensusAddress(newConsensus, _proof(pk));
        assertEq(stakeHub.getValidatorConsensusAddress(operator), newConsensus);
        assertEq(stakeHub.getValidatorVoteAddress(operator), _voteId(newConsensus), "vote id did not follow");
        // the node (consensus/parlia/consensus_revocation.go) reads
        // consensusExpiration at storage slot 68 to reject the old key at once
        address oldConsensus = consensusAddrs[0];
        bytes32 raw = vm.load(STAKE_HUB_ADDR, keccak256(abi.encode(oldConsensus, uint256(68))));
        assertEq(uint256(raw), block.timestamp, "consensusExpiration slot moved");
    }

    function testEditVoteAddressDisabled() public {
        _createValidator();
        vm.warp(block.timestamp + 2 days);
        vm.prank(operators[0]);
        vm.expectRevert(StakeHub.InvalidVoteAddress.selector);
        stakeHub.editVoteAddress(_voteId(address(0x1)), "");
    }

    // Same vector as crypto/pq TestValidatorProofHashVector (Go), so the
    // message the node tooling signs and the one StakeHub checks cannot drift.
    function testValidatorProofHashMatchesGo() public {
        vm.chainId(20261012);
        assertEq(
            _popMessage(0x1111111111111111111111111111111111111111, 0x2222222222222222222222222222222222222222),
            0x59469dac0654c3ab96107422aaf84bfb2e30481a1bd352706c265b6fc8835d0b
        );
    }

    // An agent may submit the edit, but the proof must name the operator.
    function testEditConsensusAddressByAgentBindsOperator() public {
        _createValidator();
        address operator = operators[0];
        address agent = address(0xA6E7);
        vm.prank(operator);
        stakeHub.updateAgent(agent);
        vm.warp(block.timestamp + 2 days);
        bytes memory pk = _fakePubKey(4242);
        address newConsensus = _consensusOf(pk);

        _acceptPop(pk, newConsensus, agent);
        vm.prank(agent);
        vm.expectRevert(StakeHub.InvalidConsensusAddress.selector);
        stakeHub.editConsensusAddress(newConsensus, _proof(pk));

        _acceptPop(pk, newConsensus, operator);
        vm.prank(agent);
        stakeHub.editConsensusAddress(newConsensus, _proof(pk));
        assertEq(stakeHub.getValidatorConsensusAddress(operator), newConsensus);
    }

    // Only scheme 0x01 (ML-DSA-87) proofs are accepted, even if the key hash matches.
    function testProofRejectsOtherScheme() public {
        bytes memory pk = _fakePubKey(31);
        address consensus = address(uint160(uint256(keccak256(bytes.concat(bytes1(0x02), pk)))));
        address operator = address(0x0FE);
        bytes memory proof = bytes.concat(bytes1(0x02), pk, new bytes(PQ_SIG_LEN));
        vm.mockCall(
            PQ_VERIFY,
            bytes.concat(bytes1(0x02), _popMessage(consensus, operator), pk, new bytes(PQ_SIG_LEN)),
            abi.encode(uint256(1))
        );
        vm.deal(operator, 100_001 ether);
        vm.prank(operator);
        vm.expectRevert(StakeHub.InvalidConsensusAddress.selector);
        stakeHub.createValidator{ value: 100_001 ether }(consensus, _voteId(consensus), proof, _commission(), _description(31));
    }

    // The elected (working) validator set as BSCValidatorSet.getValidators() reports it.
    function _setElected(address[] memory elected) internal {
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("getValidators()"), abi.encode(elected));
    }

    function _distribute(uint256 amount) internal returns (uint256 gasUsed) {
        vm.deal(coinbase, amount);
        vm.prank(coinbase);
        uint256 g = gasleft();
        stakeHub.distributeStakingInflation{ value: amount }();
        gasUsed = g - gasleft();
    }

    function _pooled(uint256 i) internal view returns (uint256) {
        return IStakeCredit(stakeHub.getValidatorCreditContract(operators[i])).totalPooledBNB();
    }

    // Takes the inflation snapshot the next distribution pays by (a breathe
    // block that pays whatever is pending and re-snapshots).
    function _breathe() internal returns (uint256 gasUsed) {
        return _distribute(stakeHub.pendingStakingInflation(block.timestamp));
    }

    // Anyone can register validators (100,000 FL each). The breathe block system
    // transaction must not grow with that number, otherwise header.GasUsed
    // exceeds the block gas limit and every breathe block is invalid.
    function testInflationGasBoundedBySybilValidators() public {
        for (uint256 i; i < 200; ++i) {
            _createValidator();
        }
        address[] memory elected = new address[](21);
        for (uint256 i; i < 21; ++i) {
            elected[i] = consensusAddrs[i];
        }
        _setElected(elected);
        _breathe();
        vm.warp(block.timestamp + 1 days);
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        assertGt(amount, 0);
        uint256 gasUsed = _distribute(amount);
        emit log_named_uint("distributeStakingInflation gas, 200 registered / 21 elected", gasUsed);
        assertLt(gasUsed, SYSTEM_TXS_GAS_HARD_LIMIT / 4, "inflation system tx gas grows with registered validators");
    }

    // Only working validators earn; the minted amount equals what is paid out
    // (up to rounding dust, which is carried) and the expected 12% * 1.1 per year.
    function testInflationPaysElectedValidatorsOnly() public {
        for (uint256 i; i < 5; ++i) {
            _createValidator();
        }
        address[] memory elected = new address[](3);
        elected[0] = consensusAddrs[0];
        elected[1] = consensusAddrs[2];
        elected[2] = consensusAddrs[2]; // duplicates are ignored
        _setElected(elected);
        _breathe();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 365 days / 73); // 5 days
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        uint256 base = 2 * 100_001 ether;
        assertEq(amount, (base * 1200 * 11_000 * (365 days / 73)) / (100_000_000 * 365 days));
        uint256[] memory before = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            before[i] = _pooled(i);
        }
        _distribute(amount);
        uint256 paid;
        for (uint256 i; i < 5; ++i) {
            uint256 gained = _pooled(i) - before[i];
            if (i == 0 || i == 2) {
                assertGt(gained, 0);
            } else {
                assertEq(gained, 0);
            }
            paid += gained;
        }
        assertLe(amount - paid, 10, "minted inflation not paid out");
        assertEq(amount - paid, stakeHub.inflationCarry(), "dust is carried, not lost");
        assertEq(stakeHub.lastInflationTime(), block.timestamp);
        assertEq(stakeHub.pendingStakingInflation(block.timestamp), 0);
    }

    // FL-04: stake added right before a breathe block does not earn the reward
    // of the day before it; weights come from the previous breathe block.
    function testLateStakeDoesNotCaptureReward() public {
        for (uint256 i; i < 2; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        _breathe();
        vm.warp(block.timestamp + 1 days);
        uint256 pendingBefore = stakeHub.pendingStakingInflation(block.timestamp);

        // a whale delegates 10M FL into pool 1 just before the breathe block
        address whale = address(0x77AA1E);
        vm.deal(whale, 10_000_000 ether);
        vm.prank(whale);
        stakeHub.delegate{ value: 10_000_000 ether }(operators[1], false);

        assertEq(stakeHub.pendingStakingInflation(block.timestamp), pendingBefore, "late stake changed the mint");
        uint256 before0 = _pooled(0);
        uint256 before1 = _pooled(1);
        _distribute(pendingBefore);
        uint256 gained0 = _pooled(0) - before0;
        uint256 gained1 = _pooled(1) - before1;
        // both pools had equal stake at the snapshot, so they split the day equally
        assertApproxEqAbs(gained0, gained1, 2);
        // the next day the whale's stake counts
        (, uint256[] memory weights,) = stakeHub.getInflationSnapshot();
        assertGt(weights[1], 10_000_000 ether);
    }

    // FL-02: a pool that rejects its payout keeps the amount as a claim that is
    // retried, instead of losing it.
    function testPayoutFailureIsRetried() public {
        for (uint256 i; i < 2; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        _breathe();
        vm.warp(block.timestamp + 1 days);
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        address credit0 = stakeHub.getValidatorCreditContract(operators[0]);
        vm.mockCallRevert(credit0, abi.encodeWithSelector(IStakeCredit.distributeReward.selector), "down");
        _distribute(amount);
        uint256 owed = stakeHub.pendingStakerInflation(operators[0]) + stakeHub.pendingValidatorInflation(operators[0]);
        assertApproxEqAbs(owed, amount / 2, 2, "failed share not booked");
        vm.clearMockedCalls();
        _setElected(consensusAddrs);
        uint256 before = _pooled(0);
        stakeHub.retryStakingInflation(operators[0]);
        assertEq(stakeHub.pendingStakerInflation(operators[0]) + stakeHub.pendingValidatorInflation(operators[0]), 0);
        assertEq(_pooled(0) - before, owed);
    }

    // FL-03: a pool whose stake cannot be read gets weight 0; the system
    // transaction still succeeds.
    function testRevertingStakeGetterDoesNotRevert() public {
        for (uint256 i; i < 2; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        address credit0 = stakeHub.getValidatorCreditContract(operators[0]);
        vm.mockCallRevert(credit0, abi.encodeWithSelector(IStakeCredit.totalPooledBNB.selector), "broken");
        _breathe();
        (address[] memory ops,,) = stakeHub.getInflationSnapshot();
        assertEq(ops.length, 1);
        assertEq(ops[0], operators[1]);
    }

    // FL-11 / R4-02: after a long halt the whole backlog is paid at the first
    // breathe block, to the snapshot it was earned under (an election at
    // recovery cannot take earlier rewards).
    function testLongHaltPaidAtOnce() public {
        _createValidator();
        _setElected(consensusAddrs);
        _breathe();
        vm.warp(stakeHub.lastInflationTime() + 90 days);
        uint256 stake = 100_001 ether;
        uint256 expected = (stake * 1200 * 11_000 * 90 days) / (100_000_000 * 365 days);
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        assertEq(amount, expected);
        uint256 before = _pooled(0);
        _distribute(amount);
        assertApproxEqAbs(_pooled(0) - before, amount, 2);
        assertEq(stakeHub.lastInflationTime(), block.timestamp);
        assertEq(stakeHub.pendingStakingInflation(block.timestamp), 0);
    }

    // FL-12: a rate change only applies from the moment it is made.
    function testRateChangeIsNotRetroactive() public {
        _createValidator();
        _setElected(consensusAddrs);
        _breathe();
        uint256 start = stakeHub.lastInflationTime();
        vm.warp(start + 12 hours);
        vm.prank(GOV_HUB_ADDR);
        stakeHub.updateParam("stakingAprBps", abi.encode(uint256(2000)));
        vm.warp(start + 24 hours);
        uint256 half = 12 hours;
        uint256 stake = 100_001 ether;
        uint256 expected = (stake * 1200 * 11_000 * half) / (100_000_000 * 365 days)
            + (stake * 2000 * 11_000 * half) / (100_000_000 * 365 days);
        assertApproxEqAbs(stakeHub.pendingStakingInflation(block.timestamp), expected, 2);
    }

    // R2-07: governance cannot leave elected validators without inflation or
    // lower the self delegation below the launch value.
    function testGovernanceBounds() public {
        uint256 maxElected = stakeHub.MAX_INFLATION_VALIDATORS();
        vm.startPrank(GOV_HUB_ADDR);
        vm.expectRevert();
        stakeHub.updateParam("maxElectedValidators", abi.encode(maxElected + 1));
        stakeHub.updateParam("maxElectedValidators", abi.encode(maxElected));
        vm.expectRevert();
        stakeHub.updateParam("minSelfDelegationBNB", abi.encode(uint256(99_999 ether)));
        stakeHub.updateParam("minSelfDelegationBNB", abi.encode(uint256(200_000 ether)));
        vm.stopPrank();
    }

    // R2-06: the registered validator set (scanned by the daily election) is bounded.
    function testRegisteredValidatorsCapped() public {
        _createValidator();
        // _validatorSet (EnumerableSet, slot 63): pretend it is full
        vm.store(STAKE_HUB_ADDR, bytes32(uint256(63)), bytes32(stakeHub.MAX_REGISTERED_VALIDATORS()));
        address operator = address(0xFFFF01);
        bytes memory pk = _fakePubKey(999_999);
        address consensus = _consensusOf(pk);
        _acceptPop(pk, consensus, operator);
        vm.deal(operator, 100_001 ether);
        vm.prank(operator);
        vm.expectRevert(StakeHub.TooManyValidators.selector);
        stakeHub.createValidator{ value: 100_001 ether }(
            consensus, _voteId(consensus), _proof(pk), _commission(), _description(999_999)
        );
    }

    // F-01: governance can raise (never lower) the registration cap, so a filled
    // set does not lock out new validators forever.
    function testRegistrationCapRaiseOnly() public {
        _createValidator();
        uint256 cap = stakeHub.MAX_REGISTERED_VALIDATORS();
        uint256 ceiling = stakeHub.MAX_REGISTRATION_CAP();
        vm.store(STAKE_HUB_ADDR, bytes32(uint256(63)), bytes32(cap));
        address operator = address(0xFFFF02);
        bytes memory pk = _fakePubKey(999_998);
        address consensus = _consensusOf(pk);
        _acceptPop(pk, consensus, operator);
        vm.deal(operator, 100_001 ether);

        vm.startPrank(GOV_HUB_ADDR);
        vm.expectRevert();
        stakeHub.updateParam("maxRegisteredValidators", abi.encode(cap)); // not a raise
        vm.expectRevert();
        stakeHub.updateParam("maxRegisteredValidators", abi.encode(ceiling + 1));
        stakeHub.updateParam("maxRegisteredValidators", abi.encode(cap + 1));
        vm.expectRevert();
        stakeHub.updateParam("maxRegisteredValidators", abi.encode(cap)); // cannot lower
        vm.stopPrank();
        assertEq(stakeHub.maxRegisteredValidators(), cap + 1);

        vm.prank(operator);
        stakeHub.createValidator{ value: 100_001 ether }(
            consensus, _voteId(consensus), _proof(pk), _commission(), _description(999_998)
        );
    }

    // The engine reads the validator list for the election at every breathe
    // block through eth_call, capped at RPCGasCap (50M by default). The full
    // list costs ~95k gas per registered validator, so ~530 sybil validators
    // would make the unpaginated read fail on every node (chain halt). The node
    // therefore reads pages of 100 (parlia electionInfoPageSize), which must
    // stay far below the cap.
    function testElectionInfoPageGasBounded() public {
        for (uint256 i; i < 150; ++i) {
            _createValidator();
        }
        uint256 g = gasleft();
        stakeHub.getValidatorElectionInfo(0, 0);
        uint256 full = g - gasleft();
        emit log_named_uint("getValidatorElectionInfo gas per validator", full / 150);
        assertGt((full / 150) * 600, 50_000_000, "unpaginated read stays under the cap");

        g = gasleft();
        (address[] memory page,,, uint256 total) = stakeHub.getValidatorElectionInfo(100, 100);
        uint256 pageGas = g - gasleft();
        assertEq(page.length, 50);
        assertEq(total, 150);
        g = gasleft();
        stakeHub.getValidatorElectionInfo(0, 100);
        pageGas = g - gasleft();
        assertLt(pageGas, 50_000_000 / 4, "a page of 100 validators is too expensive");
    }

    // Even a huge elected set is cut at MAX_INFLATION_VALIDATORS recipients.
    function testInflationRecipientsCapped() public {
        for (uint256 i; i < 120; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        _breathe();
        vm.warp(block.timestamp + 1 days);
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        uint256 capped = (stakeHub.MAX_INFLATION_VALIDATORS() * 100_001 ether * 1200 * 11_000 * 1 days)
            / (100_000_000 * 365 days);
        assertEq(amount, capped);
        uint256 gasUsed = _distribute(amount);
        emit log_named_uint("distributeStakingInflation gas, 120 elected (capped at MAX_INFLATION_VALIDATORS)", gasUsed);
        assertEq(_pooled(119), 100_001 ether);
    }

    // Worst case breathe block system txs at the largest
    // allowed elected set. Inflation: every snapshot pool has a failed payout to
    // retry, is paid again, then re-snapshotted. Validator update: the set grows
    // to its maximum with all new addresses (fresh storage). Both must fit their
    // own reserve (15M inflation, 20M SystemTxsGasHardLimit), and together the
    // 40M block gas limit with room for deposit/slash.
    function _worstCaseDistributeGas(uint256 n) internal returns (uint256 gasUsed) {
        for (uint256 i; i < n; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        _breathe();
        vm.warp(block.timestamp + 1 days);
        for (uint256 i; i < n; ++i) {
            vm.mockCallRevert(
                stakeHub.getValidatorCreditContract(operators[i]),
                abi.encodeWithSelector(IStakeCredit.distributeReward.selector),
                "down"
            );
        }
        _distribute(stakeHub.pendingStakingInflation(block.timestamp));
        vm.clearMockedCalls();
        _setElected(consensusAddrs);
        assertGt(stakeHub.pendingStakerInflation(operators[n - 1]), 0);
        vm.warp(block.timestamp + 1 days);
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        gasUsed = _distribute(amount);
        emit log_named_uint("worst case distributeStakingInflation gas (pools + retries)", gasUsed);
        assertEq(stakeHub.pendingStakerInflation(operators[n - 1]), 0);
    }

    function _updateValidatorSetGas(uint256 n) internal returns (uint256 maxUsed) {
        vm.mockCall(address(0x1001), abi.encodeWithSignature("clean()"), "");
        for (uint256 round; round < 2; ++round) {
            address[] memory addrs = new address[](n);
            uint64[] memory powers = new uint64[](n);
            bytes[] memory votes = new bytes[](n);
            // registered validators, so the jailed check reads StakeHub for each
            for (uint256 i; i < n; ++i) {
                _createValidator();
                addrs[i] = consensusAddrs[consensusAddrs.length - 1];
                powers[i] = 100_000 * 1e8;
                votes[i] = _voteId(addrs[i]);
            }
            vm.prank(coinbase);
            uint256 g = gasleft();
            (bool ok, bytes memory ret) = VALIDATOR_CONTRACT_ADDR.call(
                abi.encodeWithSignature("updateValidatorSetV2(address[],uint64[],bytes[])", addrs, powers, votes)
            );
            uint256 used = g - gasleft();
            assertTrue(ok, string(ret));
            emit log_named_uint("updateValidatorSetV2 gas", used);
            if (used > maxUsed) maxUsed = used;
        }
    }

    // More working candidates than cabinets (both governance params) must not
    // make getMiningValidators revert: the engine reads it at every epoch.
    function testMiningValidatorsCandidatesAboveCabinets() public {
        vm.mockCall(address(0x1001), abi.encodeWithSignature("clean()"), "");
        address[] memory addrs = new address[](3);
        uint64[] memory powers = new uint64[](3);
        bytes[] memory votes = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            _createValidator();
            addrs[i] = consensusAddrs[consensusAddrs.length - 1];
            powers[i] = 100_000 * 1e8;
            votes[i] = _voteId(addrs[i]);
        }
        vm.prank(coinbase);
        (bool ok, bytes memory ret) = VALIDATOR_CONTRACT_ADDR.call(
            abi.encodeWithSignature("updateValidatorSetV2(address[],uint64[],bytes[])", addrs, powers, votes)
        );
        assertTrue(ok, string(ret));
        vm.store(VALIDATOR_CONTRACT_ADDR, bytes32(uint256(12)), bytes32(uint256(1))); // numOfCabinets
        vm.store(VALIDATOR_CONTRACT_ADDR, bytes32(uint256(14)), bytes32(uint256(2))); // maxNumOfWorkingCandidates

        (ok, ret) = VALIDATOR_CONTRACT_ADDR.staticcall(abi.encodeWithSignature("getMiningValidators()"));
        assertTrue(ok, "getMiningValidators reverted");
        (address[] memory mining, bytes[] memory miningVotes) = abi.decode(ret, (address[], bytes[]));
        assertEq(mining.length, 1);
        assertEq(miningVotes.length, 1);
    }

    // numOfCabinets must stay above maxNumOfMaintaining when cabinets change.
    function testCabinetsAboveMaintaining() public {
        vm.mockCall(STAKE_HUB_ADDR, abi.encodeWithSignature("maxElectedValidators()"), abi.encode(uint256(21)));
        vm.store(VALIDATOR_CONTRACT_ADDR, bytes32(uint256(0)), bytes32(uint256(1))); // alreadyInit
        vm.startPrank(GOV_HUB_ADDR);
        // maxNumOfMaintaining unset -> INIT 3
        (bool ok,) = VALIDATOR_CONTRACT_ADDR.call(
            abi.encodeWithSignature("updateParam(string,bytes)", "numOfCabinets", abi.encodePacked(uint256(3)))
        );
        assertFalse(ok, "cabinets == maintaining must revert");
        (ok,) = VALIDATOR_CONTRACT_ADDR.call(
            abi.encodeWithSignature("updateParam(string,bytes)", "numOfCabinets", abi.encodePacked(uint256(4)))
        );
        assertTrue(ok, "cabinets > maintaining must pass");
        vm.stopPrank();
    }

    // BSCGovernor bounds are block counts: 24 h / 30 d / 2 d at 3 s blocks.
    function testGovernorBoundsInBlocks() public {
        address gov = 0x0000000000000000000000000000000000002004;
        vm.etch(gov, vm.getDeployedCode("BSCGovernor.sol:BSCGovernor"));
        vm.startPrank(GOV_HUB_ADDR);
        (bool ok,) = gov.call(abi.encodeWithSignature("updateParam(string,bytes)", "votingDelay", abi.encode(uint256(28_801))));
        assertFalse(ok);
        (ok,) = gov.call(abi.encodeWithSignature("updateParam(string,bytes)", "votingDelay", abi.encode(uint256(28_800))));
        assertTrue(ok);
        (ok,) = gov.call(abi.encodeWithSignature("updateParam(string,bytes)", "votingPeriod", abi.encode(uint256(864_001))));
        assertFalse(ok);
        (ok,) = gov.call(abi.encodeWithSignature("updateParam(string,bytes)", "votingPeriod", abi.encode(uint256(864_000))));
        assertTrue(ok);
        (ok,) = gov.call(abi.encodeWithSignature("updateParam(string,bytes)", "minPeriodAfterQuorum", abi.encodePacked(uint64(57_601))));
        assertFalse(ok);
        (ok,) = gov.call(abi.encodeWithSignature("updateParam(string,bytes)", "minPeriodAfterQuorum", abi.encodePacked(uint64(57_600))));
        assertTrue(ok);
        vm.stopPrank();
    }

    function testBreatheBlockGasAtMaxElected() public {
        uint256 n = stakeHub.MAX_INFLATION_VALIDATORS();
        uint256 d = _worstCaseDistributeGas(n);
        uint256 u = _updateValidatorSetGas(n);
        emit log_named_uint("breathe block system gas at max elected (update + inflation)", d + u);
        assertLt(d, 15_000_000, "inflation exceeds stakingInflationReservedGas");
        assertLt(u, SYSTEM_TXS_GAS_HARD_LIMIT, "validator update exceeds SystemTxsGasHardLimit");
        assertLt(d + u, 30_000_000, "breathe block system txs too close to the 40M gas limit");
    }

    // ---------------- consensus key rotation (R2-04) ----------------

    address constant SLASH_ADDR = 0x0000000000000000000000000000000000001001;

    function _rotate(uint256 i, uint256 seed) internal returns (address newConsensus) {
        bytes memory pk = _fakePubKey(seed);
        newConsensus = _consensusOf(pk);
        _acceptPop(pk, newConsensus, operators[i]);
        vm.prank(operators[i]);
        stakeHub.editConsensusAddress(newConsensus, _proof(pk));
    }

    // With R2-04 the old key cannot seal from the block after the edit, and the
    // new key only joins Parlia's validator set after the next breathe block and
    // epoch. With 3 validators the Parlia recents rule needs 2 live signers, so a
    // second rotation in that window halts the chain for good (no block can reach
    // the breathe block that would install the new keys).
    function testRotationCannotHaltChain() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        vm.warp(block.timestamp + 2 days);
        _rotate(0, 5000);
        vm.expectRevert(StakeHub.TooManyPendingRotations.selector);
        this.rotateExternal(1, 5001);
        // the first rotation counts until a breathe block has put its new key in
        // the elected set and Parlia's epoch has installed it (the election of a
        // breathe block reads the parent state, so it must come in a later block)
        vm.roll(block.number + 1);
        _breathe();
        vm.expectRevert(StakeHub.RotationFrozen.selector);
        this.rotateExternal(1, 5001);
        vm.roll(block.number + stakeHub.ROTATION_FREEZE_BLOCKS() + 1);
        vm.warp(block.timestamp + 2 days);
        _rotate(1, 5001);
    }

    // R4-01: right after a breathe block the contract's elected set and
    // Parlia's set can differ, so rotations wait for the epoch to install it.
    function testRotationFrozenAfterElection() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        vm.warp(block.timestamp + 2 days);
        _breathe();
        vm.expectRevert(StakeHub.RotationFrozen.selector);
        this.rotateExternal(0, 5000);
        vm.roll(block.number + stakeHub.ROTATION_FREEZE_BLOCKS() + 1);
        _rotate(0, 5000);
    }

    // R6: Parlia switches to the set of epoch block E only when it applies header
    // E + minerHistoryCheckLen, with checkLen = (n/2 + 1) * turnLength - 1 of the
    // outgoing set (snapshot.go apply). A breathe block that IS an epoch block is
    // not in that epoch's header (prepareValidators reads the parent state), so
    // its set is installed only after B + 1000 + checkLen. Governance allows
    // turnLength up to 64 (BSCValidatorSet) and up to MAX_INFLATION_VALIDATORS (50)
    // cabinets. A rotation in block R revokes the old key from R + 1, so every
    // block up to the switch must still be frozen.
    function testFreezeCoversWorstCaseParliaSwitch() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        vm.warp(block.timestamp + 2 days);
        uint256 breathe = 5000; // lands exactly on an epoch block
        vm.roll(breathe);
        _breathe();
        uint256 checkLen = (stakeHub.MAX_INFLATION_VALIDATORS() / 2 + 1) * 64 - 1;
        uint256 lastOldSetBlock = breathe + 1000 + checkLen; // still sealed by the old set
        vm.roll(lastOldSetBlock - 1);
        vm.expectRevert(StakeHub.RotationFrozen.selector);
        this.rotateExternal(0, 5000);
        vm.roll(breathe + stakeHub.ROTATION_FREEZE_BLOCKS() + 1);
        _rotate(0, 5000);
    }

    // R4-03: when no snapshot pool earns, the inflation is burned, not carried
    // (the carry could pay it back to the forfeiting pools later).
    function testNoEligiblePoolBurns() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        vm.warp(block.timestamp + 2 days);
        _breathe();
        // pools 1 and 2 jailed (the last validator can never be jailed), pool 0
        // rotated after the snapshot: no pool earns this distribution
        vm.startPrank(0x0000000000000000000000000000000000001001); // SlashIndicator
        stakeHub.downtimeSlash(consensusAddrs[1]);
        stakeHub.downtimeSlash(consensusAddrs[2]);
        vm.stopPrank();
        vm.roll(block.number + stakeHub.ROTATION_FREEZE_BLOCKS() + 1);
        _rotate(0, 5000);
        vm.warp(block.timestamp + 1 days);
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        assertGt(amount, 0);
        uint256 deadBefore = address(0xdEaD).balance;
        _distribute(amount);
        // only the per-pool rounding dust (a few wei) stays in the carry
        assertApproxEqAbs(address(0xdEaD).balance - deadBefore, amount, 3, "forfeited inflation not burned");
        assertLe(stakeHub.inflationCarry(), 3);
    }

    function rotateExternal(uint256 i, uint256 seed) external {
        _rotate(i, seed);
    }

    // A validator whose old key was revoked cannot produce until the next
    // breathe block; it must not be downtime slashed and jailed for that.
    function testRotatedValidatorNotDowntimeJailed() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        vm.etch(SLASH_ADDR, vm.getDeployedCode("SlashIndicator.sol:SlashIndicator"));
        (bool ok,) = SLASH_ADDR.call(abi.encodeWithSignature("init()"));
        assertTrue(ok);
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("isCurrentValidator(address)"), abi.encode(true));
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("felony(address)"), "");
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("misdemeanor(address)"), "");
        vm.warp(block.timestamp + 2 days);
        _rotate(0, 5000);
        // the old key misses every in-turn slot until the breathe block (thousands per day)
        for (uint256 i; i < 150; ++i) {
            vm.roll(block.number + 1);
            vm.prank(coinbase);
            (ok,) = SLASH_ADDR.call(abi.encodeWithSignature("slash(address)", consensusAddrs[0]));
            assertTrue(ok);
        }
        (, bool jailed,) = stakeHub.getValidatorBasicInfo(operators[0]);
        assertFalse(jailed, "honest key rotation got the validator downtime jailed");
        // an offline validator that did not rotate is still jailed
        for (uint256 i; i < 150; ++i) {
            vm.roll(block.number + 1);
            vm.prank(coinbase);
            (ok,) = SLASH_ADDR.call(abi.encodeWithSignature("slash(address)", consensusAddrs[1]));
            assertTrue(ok);
        }
        (, jailed,) = stakeHub.getValidatorBasicInfo(operators[1]);
        assertTrue(jailed);
    }

    // The downtime exemption must not let an offline validator keep earning by
    // rotating its key every day: a pool whose key was rotated after the
    // snapshot forfeits that distribution (it is burned).
    function testRotationForfeitsThatDaysInflation() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        vm.warp(block.timestamp + 2 days);
        _breathe();
        vm.roll(block.number + stakeHub.ROTATION_FREEZE_BLOCKS() + 1);
        _rotate(0, 5000);
        vm.warp(block.timestamp + 1 days);
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        uint256 before0 = _pooled(0);
        uint256 before1 = _pooled(1);
        uint256 deadBefore = address(0xdEaD).balance;
        _distribute(amount);
        assertEq(_pooled(0), before0, "rotated (non-producing) pool still earned");
        // the forfeited third is burned: it neither raises the other pools'
        // share nor stays in the carry to flow back to the forfeiting pool
        assertApproxEqAbs(_pooled(1) - before1, amount / 3, 3);
        assertApproxEqAbs(address(0xdEaD).balance - deadBefore, amount / 3, 3);
        assertLe(stakeHub.inflationCarry(), 3);
    }

    // Regression: a big pool getting itself jailed right before the
    // breathe block must not multiply a small pool's reward.
    function testJailedPoolShareIsNotRedistributed() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        // pool 0 is about 90% of the stake
        address whale = address(0x9A1E);
        vm.deal(whale, 2_000_000 ether);
        vm.prank(whale);
        stakeHub.delegate{ value: 2_000_000 ether }(operators[0], false);
        _setElected(consensusAddrs);
        vm.warp(block.timestamp + 2 days);
        _breathe();
        vm.warp(block.timestamp + 1 days);
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        (, uint256[] memory weights, uint256 total) = stakeHub.getInflationSnapshot();
        uint256 fair1 = (amount * weights[1]) / total;
        vm.prank(0x0000000000000000000000000000000000001001); // SlashIndicator
        stakeHub.downtimeSlash(consensusAddrs[0]);
        uint256 before1 = _pooled(1);
        uint256 deadBefore = address(0xdEaD).balance;
        _distribute(amount);
        assertApproxEqAbs(_pooled(1) - before1, fair1, 3, "small pool got the jailed pool's share");
        assertApproxEqAbs(address(0xdEaD).balance - deadBefore, (amount * weights[0]) / total, 3);
    }

    // R3-02: a rotation while another current validator is missing its turns
    // would leave too few signers; it is refused until that validator is back.
    function testRotationRefusedWhileValidatorMissing() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        vm.warp(block.timestamp + 2 days);
        vm.roll(1000);
        vm.mockCall(
            SLASH_ADDR,
            abi.encodeWithSignature("getSlashIndicator(address)", consensusAddrs[2]),
            abi.encode(uint256(995), uint256(3))
        );
        vm.expectRevert(StakeHub.TooManyPendingRotations.selector);
        this.rotateExternal(0, 5000);
        // C has produced again for a while (no miss in the last RECENT_MISS_BLOCKS)
        vm.roll(995 + stakeHub.RECENT_MISS_BLOCKS() + 1);
        _rotate(0, 5000);
    }

    // R3-05: a rate change after a halt longer than 30 days books the whole
    // halt at the old rate.
    function testRateChangeAfterLongHaltKeepsOldRate() public {
        _createValidator();
        _setElected(consensusAddrs);
        _breathe();
        vm.warp(block.timestamp + 60 days);
        vm.prank(GOV_HUB_ADDR);
        stakeHub.updateParam("stakingAprBps", abi.encode(uint256(2000)));
        uint256 stake = 100_001 ether;
        uint256 expected = (stake * 1200 * 11_000 * 60 days) / (100_000_000 * 365 days);
        assertApproxEqAbs(stakeHub.pendingStakingInflation(block.timestamp), expected, 2);
    }

    // R3-06: rewards accrued before a validator bonus change keep the split they
    // were earned with.
    function testBonusChangeKeepsAccruedSplit() public {
        _createValidator();
        _setElected(consensusAddrs);
        _breathe();
        vm.warp(block.timestamp + 1 days);
        vm.prank(GOV_HUB_ADDR);
        stakeHub.updateParam("validatorRewardBps", abi.encode(uint256(5000)));
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        uint256 validatorPart = (amount * 1000) / 11_000;
        address credit = stakeHub.getValidatorCreditContract(operators[0]);
        vm.expectCall(
            credit, validatorPart, abi.encodeWithSelector(IStakeCredit.distributeReward.selector, uint64(10_000))
        );
        vm.expectCall(
            credit, amount - validatorPart, abi.encodeWithSelector(IStakeCredit.distributeReward.selector, uint64(0))
        );
        _distribute(amount);
    }

    // Regression: validators in maintenance still count in Parlia's set, so
    // they count as members that cannot seal.
    function testRotationCountsMaintaining() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
        vm.warp(block.timestamp + 2 days);
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("numOfMaintaining()"), abi.encode(uint256(1)));
        vm.expectRevert(StakeHub.TooManyPendingRotations.selector);
        this.rotateExternal(0, 5000);
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("numOfMaintaining()"), abi.encode(uint256(0)));
        _rotate(0, 5000);
    }

    // Regression: a rate change in the breathe block after a long halt; the
    // parent-state mint covers the whole backlog and nothing is lost or left.
    function testBacklogNotLostOnSameBlockRateChange() public {
        _createValidator();
        _setElected(consensusAddrs);
        _breathe();
        vm.warp(block.timestamp + 60 days);
        uint256 minted = stakeHub.pendingStakingInflation(block.timestamp); // parent view
        vm.prank(GOV_HUB_ADDR);
        stakeHub.updateParam("stakingAprBps", abi.encode(uint256(1500)));
        uint256 before = _pooled(0);
        _distribute(minted);
        uint256 stake = 100_001 ether;
        uint256 sixtyDays = (stake * 1200 * 11_000 * 60 days) / (100_000_000 * 365 days);
        assertApproxEqAbs(_pooled(0) - before, sixtyDays, 4);
        assertEq(stakeHub.accruedInflation(), 0);
    }

    function _initValidatorSet() internal returns (IFLValidatorSet vs) {
        vs = IFLValidatorSet(VALIDATOR_CONTRACT_ADDR);
        vs.init();
        uint64[] memory powers = new uint64[](consensusAddrs.length);
        bytes[] memory votes = new bytes[](consensusAddrs.length);
        for (uint256 i; i < consensusAddrs.length; ++i) {
            powers[i] = 1;
            votes[i] = _voteId(consensusAddrs[i]);
        }
        vm.prank(coinbase);
        vs.updateValidatorSetV2(consensusAddrs, powers, votes);
    }

    // Regression: self-stake (and downtime) evictions shrink the working set
    // without touching the double-sign felony count, while Parlia's epoch set
    // still holds the removed keys. Rotations must wait for the next election.
    function testRotationFrozenAfterEviction() public {
        for (uint256 i; i < 5; ++i) {
            _createValidator();
        }
        IFLValidatorSet vs = _initValidatorSet();
        assertEq(vs.getValidators().length, 5);
        vm.warp(block.timestamp + 2 days);
        vm.roll(10000);
        _breathe();
        vm.roll(13000);
        // real StakeHub -> ValidatorSet.felony path, no _felonyMap increment
        for (uint256 i = 3; i < 5; ++i) {
            vm.prank(operators[i]);
            stakeHub.undelegate(operators[i], 2 ether);
        }
        assertEq(vs.getValidators().length, 3);
        assertEq(vs.lastEvictionBlock(), 13000);
        vm.expectRevert(StakeHub.RotationFrozen.selector);
        this.rotateExternal(0, 6000);
        // the next epoch header (13001..14000) carries the working set without
        // them and Parlia installs it within the freeze window, independent of
        // breathe blocks (the last one, at 10000, stopped freezing at 12664)
        uint256 freeUntil = 13000 + stakeHub.ROTATION_FREEZE_BLOCKS();
        vm.roll(freeUntil);
        vm.expectRevert(StakeHub.RotationFrozen.selector);
        this.rotateExternal(0, 6000);
        vm.roll(freeUntil + 1);
        _rotate(0, 6000);
    }

    // Regression: the engine elects from the parent state, so a validator
    // jailed earlier in the breathe block itself must not be installed again.
    function testElectionSkipsValidatorJailedInSameBlock() public {
        for (uint256 i; i < 4; ++i) {
            _createValidator();
        }
        IFLValidatorSet vs = _initValidatorSet();
        assertEq(vs.getValidators().length, 4);
        vm.roll(block.number + 1);
        // self-stake below the minimum: jailed and evicted in this block
        vm.prank(operators[3]);
        stakeHub.undelegate(operators[3], 2 ether);
        assertEq(vs.getValidators().length, 3);
        // the breathe block's election still carries it (parent state)
        uint64[] memory powers = new uint64[](4);
        bytes[] memory votes = new bytes[](4);
        for (uint256 i; i < 4; ++i) {
            powers[i] = 1;
            votes[i] = _voteId(consensusAddrs[i]);
        }
        vm.prank(coinbase);
        vs.updateValidatorSetV2(consensusAddrs, powers, votes);
        address[] memory working = vs.getValidators();
        assertEq(working.length, 3, "jailed validator installed again");
        for (uint256 i; i < working.length; ++i) {
            assertTrue(working[i] != consensusAddrs[3]);
        }
    }

    // Regression: if every validator in the (parent state) election was jailed in
    // the breathe block, the election must keep the current set, not revert
    // on an empty set (a permanent halt).
    function testElectionAllJailedKeepsSet() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        IFLValidatorSet vs = _initValidatorSet();
        vm.roll(block.number + 1);
        vm.prank(SLASH_ADDR);
        stakeHub.downtimeSlash(consensusAddrs[0]);
        address[] memory before = vs.getValidators();
        address[] memory elected = new address[](1);
        elected[0] = consensusAddrs[0];
        uint64[] memory powers = new uint64[](1);
        powers[0] = 1;
        bytes[] memory votes = new bytes[](1);
        votes[0] = _voteId(consensusAddrs[0]);
        vm.prank(coinbase);
        vs.updateValidatorSetV2(elected, powers, votes);
        assertEq(keccak256(abi.encode(vs.getValidators())), keccak256(abi.encode(before)));
    }

    // felony() on a key that is not in the working set removes nothing and
    // must not freeze rotations.
    function testFelonyOnNonMemberRecordsNothing() public {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        IFLValidatorSet vs = _initValidatorSet();
        vm.prank(STAKE_HUB_ADDR);
        IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).felony(address(0xBEEF));
        assertEq(vs.getValidators().length, 3);
        assertEq(vs.lastEvictionBlock(), 0);
    }

    // The last remaining validator is never removed, so no eviction is recorded.
    function testNoEvictionRecordedForLastValidator() public {
        _createValidator();
        IFLValidatorSet vs = _initValidatorSet();
        vm.prank(operators[0]);
        stakeHub.undelegate(operators[0], 2 ether);
        assertEq(vs.getValidators().length, 1);
        assertEq(vs.lastEvictionBlock(), 0);
    }

    // Regression: with up to 50 cabinets the Parlia activation delay
    // (n/2 + 1) * turnLength - 1 must stay within the 1000-block epoch (else the
    // set is never installed) and within the 200-block recovery offset.
    function testTurnLengthBoundedByActivationDelay() public {
        IFLValidatorSet vs = IFLValidatorSet(VALIDATOR_CONTRACT_ADDR);
        vs.init();
        uint256 maxVals = vs.MAX_CONSENSUS_VALIDATORS();
        assertEq(maxVals, stakeHub.MAX_INFLATION_VALIDATORS());
        vm.startPrank(GOV_HUB_ADDR);
        uint256[4] memory ok = [uint256(1), 3, 4, 7];
        for (uint256 i; i < ok.length; ++i) {
            vs.updateParam("turnLength", abi.encode(ok[i]));
            assertEq(vs.getTurnLength(), ok[i]);
            assertLe((maxVals / 2 + 1) * ok[i] - 1, vs.RECOVERY_OFFSET_BLOCKS());
        }
        uint256[4] memory bad = [uint256(8), 16, 39, 64];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert();
            vs.updateParam("turnLength", abi.encode(bad[i]));
        }
        vm.stopPrank();
        assertEq(vs.getTurnLength(), 7);
    }

    // FL5-01: solc 0.6 unchecked arithmetic. 26 * x - 1 wraps below 200 for
    // x = 2^255 + 1 (-> 25) and x = 0x4ec4...4ec5 (-> 1). Parlia truncates the
    // stored value to one header byte (uint8), which parseTurnLength rejects
    // unless it is 1 or 3..7, so an accepted huge value halts the chain at the
    // next epoch block. The setter must bound the value explicitly.
    function testTurnLengthRejectsWrappingValues() public {
        IFLValidatorSet vs = IFLValidatorSet(VALIDATOR_CONTRACT_ADDR);
        vs.init();
        vm.startPrank(GOV_HUB_ADDR);
        uint256[6] memory bad = [
            uint256(0),
            2,
            (1 << 255) + 1, // 26x - 1 wraps to 25; header byte 1
            0x4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec4ec5, // wraps to 1; header byte 197
            type(uint256).max,
            8
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(bytes("the turnLength should be in [3,7] or equal to 1"));
            vs.updateParam("turnLength", abi.encode(bad[i]));
        }
        vm.stopPrank();
        assertEq(vs.getTurnLength(), 1);
    }

    // FL5-03: before the first fee deposit the ratio setters validated the sum
    // against zero base/burn ratios; the first deposit then set base 625 and
    // burn 1000, so a pre-deposit systemRewardAntiMEVRatio above 8375 made the
    // deposit system tx revert on the last block of every turn (chain halt).
    function testPreDepositRatioSettersSeeEffectiveDefaults() public {
        IFLValidatorSet vs = IFLValidatorSet(VALIDATOR_CONTRACT_ADDR);
        vs.init();
        assertFalse(vs.isSystemRewardIncluded());
        vm.startPrank(GOV_HUB_ADDR);
        vs.updateParam("turnLength", abi.encode(uint256(3)));
        vm.expectRevert(
            bytes("the systemRewardAntiMEVRatio plus burnRatio and systemRewardBaseRatio must be no greater than 10000")
        );
        vs.updateParam("systemRewardAntiMEVRatio", abi.encode(uint256(8376)));
        vs.updateParam("systemRewardAntiMEVRatio", abi.encode(uint256(8375)));
        vm.stopPrank();
        assertEq(vs.systemRewardBaseRatio(), 625);
        assertEq(vs.burnRatio(), 1000);
        // last block of a turn: ratio = 625 + 8375, plus burn 1000 = exactly 100%
        vm.roll(5);
        vm.deal(coinbase, 1 ether);
        vm.prank(coinbase);
        vs.deposit{ value: 1 ether }(coinbase);
        assertEq(address(0x0000000000000000000000000000000000001002).balance, 0.9 ether);
        assertEq(address(0x000000000000000000000000000000000000dEaD).balance, 0.1 ether);
    }

    // FL5-05: SystemReward creates its operator set lazily in the first
    // claimRewards; a governance deleteOperator before that was silently
    // undone. Also, the system callers can never be removed, since
    // distributeFinalityReward (a system tx) claims from SystemReward.
    function testSystemRewardOperatorChangesSurviveLazyInit() public {
        address payable sr = payable(0x0000000000000000000000000000000000001002);
        address lightClient = 0x0000000000000000000000000000000000001003;
        vm.etch(sr, vm.getDeployedCode("SystemReward.sol:SystemReward"));
        IFLSystemReward reward = IFLSystemReward(sr);
        assertFalse(reward.alreadyInit());
        vm.startPrank(GOV_HUB_ADDR);
        reward.updateParam("deleteOperator", abi.encodePacked(lightClient));
        vm.expectRevert(bytes("system contracts are permanent operators"));
        reward.updateParam("deleteOperator", abi.encodePacked(VALIDATOR_CONTRACT_ADDR));
        vm.expectRevert(bytes("system contracts are permanent operators"));
        reward.updateParam("deleteOperator", abi.encodePacked(SLASH_ADDR));
        vm.stopPrank();
        // first claim (what distributeFinalityReward does every 200 blocks)
        vm.deal(sr, 1 ether);
        vm.prank(VALIDATOR_CONTRACT_ADDR);
        reward.claimRewards(payable(address(0xB0B)), 1 ether);
        assertTrue(reward.alreadyInit());
        assertFalse(reward.isOperator(lightClient), "pre-init deleteOperator was undone by lazy init");
        assertTrue(reward.isOperator(VALIDATOR_CONTRACT_ADDR));
        assertTrue(reward.isOperator(SLASH_ADDR));
    }

    // N-12: current set [A maintaining, B working], B not registered
    // in StakeHub (genesis validator before createValidator), so the election
    // returns only [A]. A abused maintenance long enough for the forced exit
    // to be a felony: _exitMaintenance evicts A, then the "at least one
    // validator" fallback reinstalled the evicted A as the sole validator and
    // B, the only signer, was dropped: stall. Now the empty election result
    // keeps the current set, i.e. B.
    function testForcedMaintenanceFelonyKeepsWorkingSigner() public {
        _createValidator();
        address a = consensusAddrs[0];
        address b = address(0xB0B);
        IFLValidatorSet vs = IFLValidatorSet(VALIDATOR_CONTRACT_ADDR);
        vs.init();
        address[] memory set = new address[](2);
        set[0] = a;
        set[1] = b;
        uint64[] memory powers = new uint64[](2);
        powers[0] = 1;
        powers[1] = 1;
        bytes[] memory votes = new bytes[](2);
        votes[0] = _voteId(a);
        votes[1] = _voteId(b);
        vm.prank(coinbase);
        vs.updateValidatorSetV2(set, powers, votes);
        assertEq(vs.getValidators().length, 2);

        vm.etch(SLASH_ADDR, vm.getDeployedCode("SlashIndicator.sol:SlashIndicator"));
        (bool ok,) = SLASH_ADDR.call(abi.encodeWithSignature("init()"));
        assertTrue(ok);

        vm.prank(a);
        vs.enterMaintenance();
        assertEq(vs.getValidators().length, 1); // only B works
        // slashCount = blocks / miningValidatorCount(1) / maintainSlashScale(2) >= felonyThreshold(150)
        vm.roll(block.number + 300);

        // daily election from StakeHub: only A is registered
        address[] memory elected = new address[](1);
        elected[0] = a;
        uint64[] memory ePowers = new uint64[](1);
        ePowers[0] = 1;
        bytes[] memory eVotes = new bytes[](1);
        eVotes[0] = _voteId(a);
        vm.prank(coinbase);
        vs.updateValidatorSetV2(elected, ePowers, eVotes);

        address[] memory after_ = vs.getValidators();
        bool hasB;
        for (uint256 i; i < after_.length; ++i) {
            if (after_[i] == b) hasB = true;
            assertTrue(after_[i] != a, "evicted maintaining validator reinstalled");
        }
        assertTrue(hasB, "working signer B dropped by the forced-exit fallback");
        assertEq(after_.length, 1);
        assertEq(vs.lastEvictionBlock(), block.number);
    }
}
