pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "../contracts/BSCGovernor.sol";
import "../contracts/BSCTimelock.sol";
import "../contracts/finallayer/FeeCurrencyDirectory.sol";
import "../contracts/finallayer/FixedRateOracle.sol";
import "../contracts/finallayer/ChainlinkRateOracle.sol";
import "../contracts/finallayer/FeeCurrencyERC20.sol";

// Stand-in for GovToken: same IVotes interface, freely mintable.
contract MockVotes is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("gov", "gov") ERC20Permit("gov") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._mint(to, amount);
    }

    function _burn(address from, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._burn(from, amount);
    }
}

contract MockFeed2 {
    int256 public answer;
    uint256 public updatedAt;
    bool public broken;

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function breakIt() external {
        broken = true;
    }

    function decimals() external view returns (uint8) {
        require(!broken, "down");
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}


// A feed whose latestRoundData() answers with no data at all (a fallback
// function): the call succeeds but the reply cannot be decoded.
contract EmptyReplyFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

// A feed whose decimals() is not a uint8.
contract BigDecimalsFeed {
    function decimals() external pure returns (uint256) {
        return 300;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 100_000_000, block.timestamp, block.timestamp, 1);
    }
}

// A feed that burns whatever gas it is given.
contract GasBurnerFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        uint256 x;
        while (true) {
            x = uint256(keccak256(abi.encode(x)));
        }
        return (1, int256(x), 0, 0, 1);
    }
}

contract FinalLayerFeeGovernanceTest is Test {
    address constant GOVERNOR = 0x0000000000000000000000000000000000002004;
    address constant GOV_TOKEN = 0x0000000000000000000000000000000000002005;
    address constant TIMELOCK = 0x0000000000000000000000000000000000002006;
    address constant GOV_HUB = 0x0000000000000000000000000000000000001007;
    address constant VALSET = 0x0000000000000000000000000000000000001000;
    address constant STAKE_HUB = 0x0000000000000000000000000000000000002002;
    address constant DIRECTORY = 0x0000000000000000000000000000000000005052;
    address constant ORACLE = 0x0000000000000000000000000000000000005053;
    address constant TOKEN = 0x0000000000000000000000000000000000005054;

    BSCGovernor gov = BSCGovernor(payable(GOVERNOR));
    MockVotes votes;
    FeeCurrencyDirectory dir = FeeCurrencyDirectory(DIRECTORY);
    FixedRateOracle oracle = FixedRateOracle(ORACLE);
    address evil;

    address alice = address(0xA11CE); // 40% of voting power
    address bob = address(0xB0B); // 25%
    address carol = address(0xCA201); // 35%

    address[] vals;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(100);
        vm.etch(GOVERNOR, vm.getDeployedCode("BSCGovernor.sol:BSCGovernor"));
        vm.etch(TIMELOCK, vm.getDeployedCode("BSCTimelock.sol:BSCTimelock"));
        vm.etch(GOV_HUB, vm.getDeployedCode("GovHub.sol:GovHub"));
        vm.etch(GOV_TOKEN, address(new MockVotes()).code);
        vm.etch(DIRECTORY, address(new FeeCurrencyDirectory()).code);
        vm.etch(ORACLE, address(new FixedRateOracle()).code);
        vm.etch(TOKEN, address(new FLTestDollar()).code);
        votes = MockVotes(GOV_TOKEN);
        address cb = address(0xC0FFEE);
        vm.coinbase(cb);
        vm.txGasPrice(0);
        vm.startPrank(cb);
        gov.initialize();
        BSCTimelock(payable(TIMELOCK)).initialize();
        vm.stopPrank();

        votes.mint(alice, 8_000_000 ether);
        votes.mint(bob, 5_000_000 ether);
        votes.mint(carol, 7_000_000 ether);
        vm.prank(alice);
        votes.delegate(alice);
        vm.prank(bob);
        votes.delegate(bob);
        vm.prank(carol);
        votes.delegate(carol);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3);

        evil = address(new FLTestDollar());

        for (uint160 i = 1; i <= 6; ++i) vals.push(address(0x7000 + i));
        _setValidators(vals);
    }

    // ---------------------------------------------------------------- helpers
    /// equal stake (voting power 100 each)
    function _setValidators(address[] memory set) internal {
        uint64[] memory powers = new uint64[](set.length);
        for (uint256 i; i < set.length; ++i) powers[i] = 100;
        _setValidators(set, powers);
    }

    function _setValidators(address[] memory set, uint64[] memory powers) internal {
        vm.mockCall(VALSET, abi.encodeWithSignature("getValidators()"), abi.encode(set));
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("consensusToOperator(address)"), abi.encode(address(0)));
        for (uint256 i; i < set.length; ++i) {
            vm.mockCall(VALSET, abi.encodeWithSignature("currentValidatorSetMap(address)", set[i]), abi.encode(i + 1));
            vm.mockCall(
                VALSET,
                abi.encodeWithSignature("currentValidatorSet(uint256)", i),
                abi.encode(set[i], set[i], address(0), powers[i], false, uint256(0))
            );
        }
    }

    function _one(address target, bytes memory data)
        internal
        pure
        returns (address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = target;
        c[0] = data;
    }

    function _propose(address target, bytes memory data, string memory desc) internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(target, data);
        vm.prank(alice);
        id = gov.propose(t, v, c, desc);
        vm.roll(block.number + 1);
    }

    function _finish(uint256 id) internal {
        vm.roll(gov.proposalDeadline(id) + 1);
    }

    function _listCall() internal view returns (bytes memory) {
        return abi.encodeWithSelector(FeeCurrencyDirectory.setCurrencyConfig.selector, evil, ORACLE, 50_000);
    }

    // ---------------------------------------------------------------- classification
    function testClassification() public {
        (address[] memory t,, bytes[] memory c) = _one(DIRECTORY, _listCall());
        assertTrue(gov.isStrictProposal(t, c), "listing is strict");
        c[0] = abi.encodeWithSelector(FeeCurrencyDirectory.removeCurrency.selector, evil);
        assertFalse(gov.isStrictProposal(t, c), "removal is normal");
        c[0] = abi.encodeWithSelector(FeeCurrencyDirectory.unsuspend.selector, evil);
        assertTrue(gov.isStrictProposal(t, c), "unsuspend is strict");
        t[0] = ORACLE;
        c[0] = abi.encodeWithSelector(FixedRateOracle.setRate.selector, evil, 1, 1, 0);
        assertTrue(gov.isStrictProposal(t, c), "rate change is strict");
        c[0] = abi.encodeWithSelector(FixedRateOracle.removeRate.selector, evil);
        assertFalse(gov.isStrictProposal(t, c), "rate removal is normal");
        t[0] = GOV_HUB;
        bytes4 up = bytes4(keccak256("updateParam(string,bytes,address)"));
        c[0] = abi.encodeWithSelector(up, "quorumNumerator", abi.encode(uint256(5)), GOVERNOR);
        assertTrue(gov.isStrictProposal(t, c), "governor params are strict");
        c[0] = abi.encodeWithSelector(up, "minDelay", abi.encode(uint256(1)), TIMELOCK);
        assertTrue(gov.isStrictProposal(t, c), "timelock params are strict");
        c[0] = abi.encodeWithSelector(up, "stakeHubProtector", abi.encodePacked(address(1)), STAKE_HUB);
        assertTrue(gov.isStrictProposal(t, c), "protectors are strict");
        c[0] = abi.encodeWithSelector(up, "maxElectedValidators", abi.encode(uint256(3)), STAKE_HUB);
        assertTrue(gov.isStrictProposal(t, c), "validator set size is strict");
        c[0] = abi.encodeWithSelector(up, "numOfCabinets", abi.encode(uint256(4)), VALSET);
        assertTrue(gov.isStrictProposal(t, c), "sealing set size is strict");
        c[0] = abi.encodeWithSelector(up, "felonyThreshold", abi.encode(uint256(4)), address(0x1001));
        assertTrue(gov.isStrictProposal(t, c), "slash thresholds are strict");
        c[0] = abi.encodeWithSelector(up, "minSelfDelegationBNB", abi.encode(uint256(1)), STAKE_HUB);
        assertFalse(gov.isStrictProposal(t, c), "other params stay normal");
        t[0] = address(0xBEEF);
        assertTrue(gov.isStrictProposal(t, c), "unknown targets are strict");
    }

    // ---------------------------------------------------------------- strict thresholds
    function testStrictNeeds30PercentFor() public {
        uint256 id = _propose(DIRECTORY, _listCall(), "list evil, bob only");
        assertTrue(gov.strictProposals(id));
        vm.prank(bob); // 25% for: enough for a normal proposal, not a strict one
        gov.castVote(id, 1);
        _finish(id);
        assertEq(uint256(gov.state(id)), uint256(IGovernorUpgradeable.ProposalState.Defeated));
    }

    function testStrictNeedsTwoThirds() public {
        uint256 id = _propose(DIRECTORY, _listCall(), "list evil, 60/40");
        vm.prank(alice); // 40% for
        gov.castVote(id, 1);
        vm.prank(bob); // 25% against: for = 61.5% of for+against
        gov.castVote(id, 0);
        _finish(id);
        assertEq(uint256(gov.state(id)), uint256(IGovernorUpgradeable.ProposalState.Defeated));
    }

    function testStrictPassesAndExecutes() public {
        vm.prank(TIMELOCK);
        oracle.setRate(evil, 1, 1, 0);
        uint256 id = _propose(DIRECTORY, _listCall(), "list evil, 75 for");
        vm.prank(alice);
        gov.castVote(id, 1);
        vm.prank(carol); // 75% for, 0 against
        gov.castVote(id, 1);
        _finish(id);
        assertEq(uint256(gov.state(id)), uint256(IGovernorUpgradeable.ProposalState.Succeeded));
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(DIRECTORY, _listCall());
        bytes32 dh = keccak256(bytes("list evil, 75 for"));
        gov.queue(t, v, c, dh);
        vm.warp(block.timestamp + 1 days + 1);
        gov.execute(t, v, c, dh);
        (uint256 n,,) = dir.getCurrencyConfigAndRate(evil);
        assertEq(n, 1, "listed through the timelock");
    }

    function testRemovalIsNormal() public {
        uint256 id = _propose(DIRECTORY, abi.encodeWithSelector(FeeCurrencyDirectory.removeCurrency.selector, TOKEN), "rm");
        assertFalse(gov.strictProposals(id));
        vm.prank(bob); // 25% for passes a normal proposal
        gov.castVote(id, 1);
        _finish(id);
        assertEq(uint256(gov.state(id)), uint256(IGovernorUpgradeable.ProposalState.Succeeded));
    }

    function testBravoSignaturePathIsClassified() public {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        string[] memory s = new string[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = DIRECTORY;
        s[0] = "setCurrencyConfig(address,address,uint256)";
        c[0] = abi.encode(evil, ORACLE, uint256(50_000));
        vm.prank(alice);
        uint256 id = gov.propose(t, v, s, c, "bravo style");
        assertTrue(gov.strictProposals(id), "signature-style proposal must be strict too");
    }

    // ---------------------------------------------------------------- validators
    function _listByValidators(address token, uint256 approvers) internal returns (bytes32 id) {
        for (uint256 i; i < approvers; ++i) {
            vm.prank(vals[i]);
            id = dir.validatorSetConfig(token, ORACLE, 50_000, 1, 100, 0);
        }
    }

    function testValidatorListingNeedsTwoThirdsAndWait() public {
        bytes32 id = _listByValidators(evil, 3); // 3 of 6: not enough
        vm.expectRevert("not ready");
        dir.executeValidatorAction(id);
        vm.prank(vals[3]); // 4 of 6 = 2/3
        dir.validatorSetConfig(evil, ORACLE, 50_000, 1, 100, 0);
        vm.expectRevert("not ready");
        dir.executeValidatorAction(id);
        vm.warp(block.timestamp + 1 days);
        dir.executeValidatorAction(id);
        (uint256 n, uint256 d,) = dir.getCurrencyConfigAndRate(evil);
        assertEq(n, 1);
        assertEq(d, 100);
        vm.expectRevert("already executed");
        dir.executeValidatorAction(id);
    }

    function testValidatorsCancelByWithdrawing() public {
        bytes32 id = _listByValidators(evil, 4);
        vm.prank(vals[0]);
        dir.withdrawApproval(id);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("not ready");
        dir.executeValidatorAction(id);
    }

    function testValidatorSetChangeCounts() public {
        bytes32 id = _listByValidators(evil, 4);
        vm.warp(block.timestamp + 1 days);
        // two approvers leave the working set: 2 of 4 remaining is below 2/3
        address[] memory smaller = new address[](4);
        smaller[0] = vals[0];
        smaller[1] = vals[1];
        smaller[2] = vals[4];
        smaller[3] = vals[5];
        _setValidators(smaller);
        vm.expectRevert("approval below 2/3");
        dir.executeValidatorAction(id);
    }

    // ---------------------------------------------------------------- stake weight
    function _unequal() internal {
        // two well-staked validators (1000 each) and four minimum-stake seats (10 each)
        uint64[] memory powers = new uint64[](6);
        powers[0] = 1000;
        powers[1] = 1000;
        for (uint256 i = 2; i < 6; ++i) powers[i] = 10;
        _setValidators(vals, powers);
    }

    function testSeatStuffingCannotActByHeadcount() public {
        _seedToken();
        _unequal();
        // 4 of 6 seats (2/3 by count) but 40 of 2040 power
        for (uint256 i = 2; i < 6; ++i) {
            vm.prank(vals[i]);
            dir.validatorSuspend(TOKEN);
        }
        assertFalse(dir.suspended(TOKEN), "cheap seats alone cannot suspend");
        bytes32 id;
        for (uint256 i = 2; i < 6; ++i) {
            vm.prank(vals[i]);
            id = dir.validatorSetConfig(evil, ORACLE, 50_000, 1, 100, 0);
        }
        (,, uint256 readyAt,, uint256 c, uint256 n) = dir.getAction(id);
        assertEq(c, 40);
        assertEq(n, 2040);
        assertEq(readyAt, 0, "listing never starts its wait");
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("not ready");
        dir.executeValidatorAction(id);
    }

    function testStakeMajorityActs() public {
        _seedToken();
        _unequal();
        // 2 of 6 seats but 2000 of 2040 power
        vm.prank(vals[0]);
        dir.validatorSuspend(TOKEN);
        assertFalse(dir.suspended(TOKEN));
        vm.prank(vals[1]);
        dir.validatorSuspend(TOKEN);
        assertTrue(dir.suspended(TOKEN), "2/3 of stake suspends");
    }

    function testExactlyTwoThirdsOfStake() public {
        _seedToken();
        uint64[] memory powers = new uint64[](6);
        powers[0] = 200;
        powers[1] = 199;
        powers[2] = 1;
        powers[3] = 100;
        powers[4] = 50;
        powers[5] = 50; // total 600, 2/3 = 400
        _setValidators(vals, powers);
        vm.prank(vals[0]);
        dir.validatorSuspend(TOKEN);
        vm.prank(vals[1]);
        dir.validatorSuspend(TOKEN);
        assertFalse(dir.suspended(TOKEN), "399 of 600 is below 2/3");
        vm.prank(vals[2]);
        dir.validatorSuspend(TOKEN);
        assertTrue(dir.suspended(TOKEN), "400 of 600 is 2/3");
    }

    function testPowerChangeAtElectionIsUsedAtExecution() public {
        bytes32 id = _listByValidators(evil, 4); // equal stake: 400 of 600
        vm.warp(block.timestamp + 1 days);
        // next election: the two validators that did not approve gained stake
        uint64[] memory powers = new uint64[](6);
        for (uint256 i; i < 4; ++i) powers[i] = 100;
        powers[4] = 300;
        powers[5] = 300; // 400 of 1000
        _setValidators(vals, powers);
        vm.expectRevert("approval below 2/3");
        dir.executeValidatorAction(id);
    }

    function testOnlyValidatorsAndNoDoubleVote() public {
        _seedToken();
        vm.prank(address(0xBAD));
        vm.expectRevert("not an active validator");
        dir.validatorSuspend(TOKEN);
        vm.prank(vals[0]);
        dir.validatorSuspend(TOKEN);
        vm.prank(vals[0]);
        vm.expectRevert("already approved");
        dir.validatorSuspend(TOKEN);
    }

    function _seedToken() internal {
        vm.prank(TIMELOCK);
        oracle.setRate(TOKEN, 1, 100, 0);
        vm.prank(TIMELOCK);
        dir.setCurrencyConfig(TOKEN, ORACLE, 50_000);
    }

    function testValidatorSuspendIsImmediate() public {
        _seedToken();
        for (uint256 i; i < 4; ++i) {
            vm.prank(vals[i]);
            dir.validatorSuspend(TOKEN);
        }
        assertTrue(dir.suspended(TOKEN));
        vm.expectRevert("suspended");
        dir.getCurrencyConfigAndRate(TOKEN);
        // validators lift it only after the wait
        bytes32 id;
        for (uint256 i; i < 4; ++i) {
            vm.prank(vals[i]);
            id = dir.validatorUnsuspend(TOKEN);
        }
        vm.expectRevert("not ready");
        dir.executeValidatorAction(id);
        vm.warp(block.timestamp + 1 days);
        dir.executeValidatorAction(id);
        dir.getCurrencyConfigAndRate(TOKEN);
    }

    function testGovernanceRemovalVoidsQueuedValidatorListing() public {
        _seedToken();
        bytes32 id;
        for (uint256 i; i < 4; ++i) {
            vm.prank(vals[i]);
            id = dir.validatorSetConfig(TOKEN, ORACLE, 60_000, 1, 1, 0);
        }
        vm.prank(TIMELOCK);
        dir.removeCurrency(TOKEN);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("token changed since approval");
        dir.executeValidatorAction(id);
    }

    function testOperatorKeyCanAct() public {
        _seedToken();
        address op = address(0x0BE7);
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("consensusToOperator(address)", vals[2]), abi.encode(op));
        vm.prank(op);
        dir.validatorSuspend(TOKEN);
        (,,,, uint256 c,) = dir.getAction(keccak256(abi.encode(FeeCurrencyDirectory.ActionKind.Suspend, TOKEN, dir.tokenNonce(TOKEN))));
        assertEq(c, 100);
    }

    // ---------------------------------------------------------------- chainlink fallback
    function testChainlinkFallsBackToFixedRate() public {
        ChainlinkRateOracle cl = new ChainlinkRateOracle(TIMELOCK);
        MockFeed2 flUsd = new MockFeed2();
        MockFeed2 tUsd = new MockFeed2();
        flUsd.set(2_000_000, block.timestamp); // $0.02
        tUsd.set(100_000_000, block.timestamp); // $1
        vm.startPrank(TIMELOCK);
        cl.setFlUsdFeed(address(flUsd), 1 hours);
        cl.setTokenFeed(TOKEN, address(tUsd), 18, 1 hours);
        oracle.setRate(TOKEN, 1, 100, 0); // backup: 1 FL = 0.01
        dir.setCurrencyConfig(TOKEN, address(cl), 50_000);
        vm.stopPrank();
        (uint256 n, uint256 d,) = dir.getCurrencyConfigAndRate(TOKEN);
        assertEq(1e18 * n / d, 2e16, "chainlink price");
        flUsd.breakIt();
        (n, d,) = dir.getCurrencyConfigAndRate(TOKEN);
        assertEq(1e18 * n / d, 1e16, "fixed-rate fallback when the feed reverts");
        MockFeed2 f2 = new MockFeed2();
        f2.set(2_000_000, block.timestamp - 2 hours);
        vm.prank(TIMELOCK);
        cl.setFlUsdFeed(address(f2), 1 hours);
        (n, d,) = dir.getCurrencyConfigAndRate(TOKEN);
        assertEq(1e18 * n / d, 1e16, "fixed-rate fallback when the feed is stale");
        vm.prank(TIMELOCK);
        oracle.removeRate(TOKEN);
        vm.expectRevert("no rate");
        dir.getCurrencyConfigAndRate(TOKEN);
    }

    // ---------------------------------------------------------------- additional cases
    function _chainlinkWithBackup(address flFeed, address tFeed) internal returns (ChainlinkRateOracle cl) {
        cl = new ChainlinkRateOracle(TIMELOCK);
        vm.startPrank(TIMELOCK);
        cl.setFlUsdFeed(flFeed, 1 hours);
        cl.setTokenFeed(TOKEN, tFeed, 18, 1 hours);
        oracle.setRate(TOKEN, 1, 100, 0); // backup: 1 FL = 0.01
        dir.setCurrencyConfig(TOKEN, address(cl), 50_000);
        vm.stopPrank();
    }

    // The node reads the rate with a 200k gas budget (core/fee_currency.go).
    function _nodeLookup() internal view returns (bool ok, uint256 n, uint256 d) {
        (bool success, bytes memory ret) = DIRECTORY.staticcall{gas: 200_000}(
            abi.encodeWithSelector(FeeCurrencyDirectory.getCurrencyConfigAndRate.selector, TOKEN)
        );
        if (!success || ret.length < 96) return (false, 0, 0);
        (n, d,) = abi.decode(ret, (uint256, uint256, uint256));
        ok = true;
    }

    function testChainlinkMalformedReplyFallsBack() public {
        MockFeed2 tUsd = new MockFeed2();
        tUsd.set(100_000_000, block.timestamp);
        _chainlinkWithBackup(address(new EmptyReplyFeed()), address(tUsd));
        (bool ok, uint256 n, uint256 d) = _nodeLookup();
        assertTrue(ok, "a reply that cannot be decoded must fall back, not switch the token off");
        assertEq(1e18 * n / d, 1e16, "fixed-rate fallback");
    }

    function testChainlinkBadDecimalsFallsBack() public {
        MockFeed2 flUsd = new MockFeed2();
        flUsd.set(2_000_000, block.timestamp);
        _chainlinkWithBackup(address(flUsd), address(new BigDecimalsFeed()));
        (bool ok, uint256 n, uint256 d) = _nodeLookup();
        assertTrue(ok, "a decimals() that is not a uint8 must fall back");
        assertEq(1e18 * n / d, 1e16, "fixed-rate fallback");
    }

    function testChainlinkGasBurningFeedFallsBackUnderNodeBudget() public {
        MockFeed2 tUsd = new MockFeed2();
        tUsd.set(100_000_000, block.timestamp);
        ChainlinkRateOracle cl = _chainlinkWithBackup(address(new GasBurnerFeed()), address(tUsd));
        (bool ok, uint256 n, uint256 d) = _nodeLookup();
        assertTrue(ok, "a feed that burns gas must leave enough for the fallback under 200k");
        assertEq(1e18 * n / d, 1e16, "fixed-rate fallback");
        // both feeds burning gas is still inside the budget
        GasBurnerFeed burner2 = new GasBurnerFeed();
        vm.prank(TIMELOCK);
        cl.setTokenFeed(TOKEN, address(burner2), 18, 1 hours);
        (ok, n, d) = _nodeLookup();
        assertTrue(ok, "two gas-burning feeds");
        assertEq(1e18 * n / d, 1e16);
    }

    function testChainlinkHealthyPathUnderNodeBudget() public {
        MockFeed2 flUsd = new MockFeed2();
        MockFeed2 tUsd = new MockFeed2();
        flUsd.set(2_000_000, block.timestamp);
        tUsd.set(100_000_000, block.timestamp);
        _chainlinkWithBackup(address(flUsd), address(tUsd));
        uint256 before = gasleft();
        (bool ok, uint256 n, uint256 d) = _nodeLookup();
        uint256 used = before - gasleft();
        assertTrue(ok);
        assertEq(1e18 * n / d, 2e16, "chainlink price");
        emit log_named_uint("directory lookup gas through ChainlinkRateOracle (mock feeds)", used);
        assertLt(used, 100_000, "healthy chainlink lookup well under the node budget");
    }

    function testCannotUnwhitelistGovHub() public {
        vm.prank(GOV_HUB);
        vm.expectRevert(
            abi.encodeWithSelector(SystemV2.InvalidValue.selector, "unwhitelistTarget", abi.encodePacked(GOV_HUB))
        );
        gov.updateParam("unwhitelistTarget", abi.encodePacked(GOV_HUB));
        assertTrue(gov.whitelistTargets(GOV_HUB));
        // other targets can be dropped and re-added
        vm.prank(GOV_HUB);
        gov.updateParam("unwhitelistTarget", abi.encodePacked(DIRECTORY));
        assertFalse(gov.whitelistTargets(DIRECTORY));
        vm.prank(GOV_HUB);
        gov.updateParam("whitelistTarget", abi.encodePacked(DIRECTORY));
        assertTrue(gov.whitelistTargets(DIRECTORY));
    }

    function testConsensusAndOperatorKeysCountOnce() public {
        _seedToken();
        address op = address(0x0BE7);
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("consensusToOperator(address)", vals[2]), abi.encode(op));
        vm.prank(vals[2]);
        bytes32 id = dir.validatorSuspend(TOKEN);
        vm.prank(op);
        vm.expectRevert("already approved");
        dir.validatorSuspend(TOKEN);
        (,,,, uint256 c,) = dir.getAction(id);
        assertEq(c, 100);
        // the operator can withdraw what the consensus key approved
        vm.prank(op);
        dir.withdrawApproval(id);
        (,,,, c,) = dir.getAction(id);
        assertEq(c, 0);
    }

    function testRotatedConsensusKeyCountsOnce() public {
        _seedToken();
        address op = address(0x0BE7);
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("consensusToOperator(address)", vals[0]), abi.encode(op));
        vm.prank(op);
        bytes32 id = dir.validatorSetConfig(TOKEN, ORACLE, 60_000, 0, 0, 0);
        // the validator rotates its consensus key and the working set picks it up
        address c0b = address(0x7100);
        address[] memory set = new address[](6);
        for (uint256 i; i < 6; ++i) set[i] = vals[i];
        set[0] = c0b;
        _setValidators(set);
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("consensusToOperator(address)", vals[0]), abi.encode(op));
        vm.mockCall(STAKE_HUB, abi.encodeWithSignature("consensusToOperator(address)", c0b), abi.encode(op));
        (,,,, uint256 c,) = dir.getAction(id);
        assertEq(c, 0, "old key no longer in the set");
        vm.prank(op);
        dir.validatorSetConfig(TOKEN, ORACLE, 60_000, 0, 0, 0);
        (,,,, c,) = dir.getAction(id);
        assertEq(c, 100, "re-approval with the new key counts once");
    }

    function testSuspendVoidsPendingListing() public {
        _seedToken();
        bytes32 id;
        for (uint256 i; i < 4; ++i) {
            vm.prank(vals[i]);
            id = dir.validatorSetConfig(TOKEN, ORACLE, 60_000, 1, 1, 0);
        }
        for (uint256 i; i < 4; ++i) {
            vm.prank(vals[i]);
            dir.validatorSuspend(TOKEN);
        }
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("token changed since approval");
        dir.executeValidatorAction(id);
        // the same request after the suspension is a fresh action that starts from zero approvals
        vm.prank(vals[4]);
        bytes32 id2 = dir.validatorSetConfig(TOKEN, ORACLE, 60_000, 1, 1, 0);
        assertTrue(id2 != id, "new nonce, new action id");
        (,,,, uint256 c,) = dir.getAction(id2);
        assertEq(c, 100);
        (,,,, c,) = dir.getAction(id);
        assertEq(c, 400, "the stale action keeps its approvals but can never execute");
    }

    function testMixedProposalIsStrict() public {
        address[] memory t = new address[](2);
        bytes[] memory c = new bytes[](2);
        t[0] = DIRECTORY;
        t[1] = DIRECTORY;
        c[0] = abi.encodeWithSelector(FeeCurrencyDirectory.removeCurrency.selector, TOKEN);
        c[1] = _listCall();
        assertTrue(gov.isStrictProposal(t, c), "one strict call makes the proposal strict");
        // removeCurrency with trailing bytes is not the plain removal
        c[1] = abi.encodePacked(abi.encodeWithSelector(FeeCurrencyDirectory.removeCurrency.selector, TOKEN), uint8(1));
        assertTrue(gov.isStrictProposal(t, c), "non-canonical calldata is strict");
        // a GovHub call that reaches the governor through whitelistTarget is strict
        bytes4 up = bytes4(keccak256("updateParam(string,bytes,address)"));
        t[1] = GOV_HUB;
        c[1] = abi.encodeWithSelector(up, "whitelistTarget", abi.encodePacked(address(0xBEEF)), GOVERNOR);
        assertTrue(gov.isStrictProposal(t, c), "whitelisting a target is strict");
    }

    function testStrictAbstainDoesNotCountAgainst() public {
        uint256 id = _propose(DIRECTORY, _listCall(), "list evil, alice for carol abstains");
        vm.prank(alice); // 40% for
        gov.castVote(id, 1);
        vm.prank(carol); // 35% abstain
        gov.castVote(id, 2);
        _finish(id);
        assertEq(uint256(gov.state(id)), uint256(IGovernorUpgradeable.ProposalState.Succeeded));
        (,,,,, uint256 forVotes, uint256 againstVotes, uint256 abstainVotes,,) = gov.proposals(id);
        assertEq(forVotes, gov.strictForVotes(id), "bravo and strict tallies agree");
        assertEq(againstVotes, gov.strictAgainstVotes(id));
        assertEq(abstainVotes, 7_000_000 ether);
    }

    function testStrictLateQuorumExtendsDeadline() public {
        uint256 id = _propose(DIRECTORY, _listCall(), "late quorum");
        uint256 deadline = gov.proposalDeadline(id);
        vm.roll(deadline - 1);
        vm.prank(bob); // 25%: normal quorum would be reached, strict is not
        gov.castVote(id, 1);
        assertEq(gov.proposalDeadline(id), deadline, "no extension below the strict quorum");
        vm.prank(alice); // now 65% for
        gov.castVote(id, 1);
        assertGt(gov.proposalDeadline(id), deadline, "extension once the strict quorum is reached");
    }
}
