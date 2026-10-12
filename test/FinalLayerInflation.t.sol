pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import "../contracts/StakeHub.sol";

// Final Layer staking inflation: the system transaction that distributes the
// daily inflation is gas metered and counted in header.GasUsed, so its cost
// must stay bounded no matter how many validators register.
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

    // FL-11: after a halt longer than 30 days the missed time is paid on the
    // following breathe blocks instead of being forfeited.
    function testLongHaltIsCaughtUp() public {
        _createValidator();
        _setElected(consensusAddrs);
        _breathe();
        uint256 start = stakeHub.lastInflationTime();
        vm.warp(start + 60 days);
        uint256 stake = 100_001 ether;
        uint256 perDay = (stake * 1200 * 11_000 * 1 days) / (100_000_000 * 365 days);
        uint256 first = stakeHub.pendingStakingInflation(block.timestamp);
        _distribute(first);
        assertEq(stakeHub.lastInflationTime(), start + 30 days);
        uint256 second = stakeHub.pendingStakingInflation(block.timestamp);
        _distribute(second);
        assertEq(stakeHub.lastInflationTime(), start + 60 days);
        // the second catch-up pays on the grown (compounded) snapshot, so allow ~1.5%
        assertApproxEqRel(first + second, perDay * 60, 2e16);
        assertGe(first + second, perDay * 60);
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
        vm.startPrank(GOV_HUB_ADDR);
        vm.expectRevert();
        stakeHub.updateParam("maxElectedValidators", abi.encode(uint256(101)));
        stakeHub.updateParam("maxElectedValidators", abi.encode(uint256(100)));
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
        emit log_named_uint("distributeStakingInflation gas, 120 elected (capped at 100)", gasUsed);
        assertEq(_pooled(119), 100_001 ether);
    }
}
