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
    }

    function testEditVoteAddressDisabled() public {
        _createValidator();
        vm.warp(block.timestamp + 2 days);
        vm.prank(operators[0]);
        vm.expectRevert(StakeHub.InvalidVoteAddress.selector);
        stakeHub.editVoteAddress(_voteId(address(0x1)), "");
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

    // Anyone can register validators (2,000 FL each, still earning the APR).
    // The breathe block system transaction must not grow with that number,
    // otherwise header.GasUsed exceeds the block gas limit and every breathe
    // block is invalid: a permanent chain halt.
    function testInflationGasBoundedBySybilValidators() public {
        for (uint256 i; i < 200; ++i) {
            _createValidator();
        }
        address[] memory elected = new address[](21);
        for (uint256 i; i < 21; ++i) {
            elected[i] = consensusAddrs[i];
        }
        _setElected(elected);

        vm.warp(block.timestamp + 1 days);
        uint256 amount = stakeHub.pendingStakingInflation(block.timestamp);
        assertGt(amount, 0);
        uint256 gasUsed = _distribute(amount);
        emit log_named_uint("distributeStakingInflation gas, 200 registered / 21 elected", gasUsed);
        assertLt(gasUsed, SYSTEM_TXS_GAS_HARD_LIMIT / 4, "inflation system tx gas grows with registered validators");
    }

    // Only working validators earn; the minted amount equals what is paid out
    // (up to rounding dust) and the expected 12% * 1.1 per year.
    function testInflationPaysElectedValidatorsOnly() public {
        for (uint256 i; i < 5; ++i) {
            _createValidator();
        }
        address[] memory elected = new address[](3);
        elected[0] = consensusAddrs[0];
        elected[1] = consensusAddrs[2];
        elected[2] = consensusAddrs[2]; // duplicates are ignored
        _setElected(elected);

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
        assertEq(stakeHub.lastInflationTime(), block.timestamp);
        assertEq(stakeHub.pendingStakingInflation(block.timestamp), 0);
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

    // Even a huge elected set (maxElectedValidators can be raised to 500) is cut
    // at MAX_INFLATION_VALIDATORS recipients.
    function testInflationRecipientsCapped() public {
        for (uint256 i; i < 120; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
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
