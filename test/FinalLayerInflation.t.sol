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

    function _createValidator() internal {
        address operator = address(uint160(uint256(keccak256(abi.encode("op", nextUser)))));
        address consensus = address(uint160(uint256(keccak256(abi.encode("cons", nextUser)))));
        bytes memory voteAddress = bytes.concat(bytes28(0), bytes20(consensus));
        StakeHub.Commission memory commission = StakeHub.Commission({ rate: 1000, maxRate: 5000, maxChangeRate: 500 });
        StakeHub.Description memory description =
            StakeHub.Description({ moniker: _moniker(nextUser), identity: "", website: "", details: "" });
        nextUser++;
        vm.deal(operator, 2_001 ether);
        vm.prank(operator);
        stakeHub.createValidator{ value: 2_001 ether }(consensus, voteAddress, "", commission, description);
        operators.push(operator);
        consensusAddrs.push(consensus);
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
        uint256 base = 2 * 2_001 ether;
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
        uint256 capped = (stakeHub.MAX_INFLATION_VALIDATORS() * 2_001 ether * 1200 * 11_000 * 1 days)
            / (100_000_000 * 365 days);
        assertEq(amount, capped);
        uint256 gasUsed = _distribute(amount);
        emit log_named_uint("distributeStakingInflation gas, 120 elected (capped at 100)", gasUsed);
        assertEq(_pooled(119), 2_001 ether);
    }
}
