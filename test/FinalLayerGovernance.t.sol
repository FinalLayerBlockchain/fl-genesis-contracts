pragma solidity ^0.8.10;

import "./FinalLayerInflation.t.sol";
import "../contracts/StakeCredit.sol";

interface IFLGovHub {
    function updateParam(string calldata key, bytes calldata value, address target) external;
}

// Regression: blacklist through agent/consensus routes (R3-GOV-01), GovHub
// failure propagation (R3-GOV-02), unbond queue after a period cut (R3-GOV-03).
contract FinalLayerGovernanceTest is FinalLayerInflationTest {
    address constant TIMELOCK = 0x0000000000000000000000000000000000002006;
    address constant SLASH = 0x0000000000000000000000000000000000001001;

    function _blacklist(address account) internal {
        vm.prank(stakeHub.getProtector());
        stakeHub.addToBlackList(account);
    }

    function _ids(string memory seed) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = keccak256(bytes(seed));
    }

    function _commissionRate(address operator) internal view returns (uint64) {
        return stakeHub.getValidatorCommission(operator).rate;
    }

    // R3-GOV-01: a clean agent cannot administer a blacklisted operator.
    function testAgentCannotAdministerBlacklistedOperator() public {
        _createValidator();
        address operator = operators[0];
        address agent = address(0xA6E7);
        vm.prank(operator);
        stakeHub.updateAgent(agent);
        _blacklist(operator);
        vm.warp(block.timestamp + 2 days); // past the update cooldown

        vm.startPrank(agent);
        vm.expectRevert(Protectable.InBlackList.selector);
        stakeHub.addNodeIDs(_ids("a"));
        vm.expectRevert(Protectable.InBlackList.selector);
        stakeHub.removeNodeIDs(_ids("a"));
        vm.expectRevert(Protectable.InBlackList.selector);
        stakeHub.editCommissionRate(1100);
        vm.expectRevert(Protectable.InBlackList.selector);
        stakeHub.editDescription(_description(77));
        bytes memory pk = _fakePubKey(4242);
        address newConsensus = _consensusOf(pk);
        _acceptPop(pk, newConsensus, operator);
        vm.expectRevert(Protectable.InBlackList.selector);
        stakeHub.editConsensusAddress(newConsensus, _proof(pk));
        vm.stopPrank();

        // the operator itself is still blocked by the raw-caller check
        vm.prank(operator);
        vm.expectRevert(Protectable.InBlackList.selector);
        stakeHub.editCommissionRate(1100);

        // lifting the blacklist restores the agent
        vm.prank(stakeHub.getProtector());
        stakeHub.removeFromBlackList(operator);
        vm.prank(agent);
        stakeHub.editCommissionRate(1100);
        assertEq(_commissionRate(operator), 1100);
        vm.warp(block.timestamp + 2 days); // edits share one update cooldown
        vm.prank(agent);
        stakeHub.editConsensusAddress(newConsensus, _proof(pk));
        assertEq(stakeHub.getValidatorConsensusAddress(operator), newConsensus);
    }

    // R3-GOV-01: the active consensus key cannot edit a blacklisted operator's node IDs.
    function testConsensusCannotAdministerBlacklistedOperator() public {
        _createValidator();
        _blacklist(operators[0]);
        vm.prank(consensusAddrs[0]);
        vm.expectRevert(Protectable.InBlackList.selector);
        stakeHub.addNodeIDs(_ids("c"));
    }

    // A blacklisted agent stays blocked although its operator is clean, and an
    // unrelated validator's agent is unaffected by another operator's blacklist.
    function testBlacklistIsPerAccount() public {
        _createValidator();
        _createValidator();
        address agent0 = address(0xA600);
        address agent1 = address(0xA601);
        vm.prank(operators[0]);
        stakeHub.updateAgent(agent0);
        vm.prank(operators[1]);
        stakeHub.updateAgent(agent1);
        _blacklist(agent0);
        _blacklist(operators[1]);
        vm.prank(agent0);
        vm.expectRevert(Protectable.InBlackList.selector);
        stakeHub.addNodeIDs(_ids("x"));
        vm.prank(operators[0]);
        stakeHub.addNodeIDs(_ids("x"));
        vm.prank(consensusAddrs[0]);
        stakeHub.addNodeIDs(_ids("y"));
    }

    // R3-GOV-01 (unjail is permissionless): a third party cannot unjail a
    // blacklisted operator, but can unjail a clean one.
    function testBlacklistedOperatorCannotBeUnjailedByOthers() public {
        _createValidator();
        _createValidator();
        _createValidator(); // the last active validator is never jailed
        vm.startPrank(SLASH);
        stakeHub.downtimeSlash(consensusAddrs[0]);
        stakeHub.downtimeSlash(consensusAddrs[1]);
        vm.stopPrank();
        for (uint256 i; i < 2; ++i) {
            vm.deal(operators[i], 100 ether);
            vm.prank(operators[i]);
            stakeHub.delegate{ value: 100 ether }(operators[i], false); // back above min self-delegation
        }
        _blacklist(operators[0]);
        vm.warp(block.timestamp + 3 days);
        address friend = address(0xF41E);
        vm.prank(friend);
        vm.expectRevert(Protectable.InBlackList.selector);
        stakeHub.unjail(operators[0]);
        vm.prank(friend);
        stakeHub.unjail(operators[1]);
    }

    function _undelegateSetup() internal returns (address operator, address delegator, StakeCredit credit) {
        _createValidator();
        operator = operators[0];
        delegator = address(0xDE1E6A70);
        credit = StakeCredit(payable(stakeHub.getValidatorCreditContract(operator)));
        vm.deal(delegator, 100 ether);
        vm.prank(delegator);
        stakeHub.delegate{ value: 100 ether }(operator, false);
    }

    function _setUnbondPeriod(uint256 period) internal {
        vm.prank(GOV_HUB_ADDR);
        stakeHub.updateParam("unbondPeriod", abi.encode(period));
    }

    // R3-GOV-03: after the period is cut, the recorded unlock time of a new
    // request is the time it can really be claimed, and the view agrees with claim.
    function testUnbondQueueStaysOrderedAfterPeriodCut() public {
        (address operator, address delegator, StakeCredit credit) = _undelegateSetup();
        _setUnbondPeriod(30 days);
        uint256 started = block.timestamp;
        vm.prank(delegator);
        stakeHub.undelegate(operator, 10 ether);
        vm.warp(started + 1 days);
        _setUnbondPeriod(3 days);
        vm.prank(delegator);
        stakeHub.undelegate(operator, 10 ether);

        StakeCredit.UnbondRequest memory first = credit.unbondRequest(delegator, 0);
        StakeCredit.UnbondRequest memory second = credit.unbondRequest(delegator, 1);
        assertEq(first.unlockTime, started + 30 days);
        assertEq(second.unlockTime, started + 30 days, "unlock time below the request ahead of it");

        vm.warp(started + 4 days);
        assertEq(credit.claimableUnbondRequest(delegator), 0);
        vm.prank(delegator);
        vm.expectRevert(StakeCredit.NoClaimableUnbondRequest.selector);
        stakeHub.claim(operator, 0);

        vm.warp(started + 30 days);
        assertEq(credit.claimableUnbondRequest(delegator), 2);
        uint256 before = delegator.balance;
        vm.prank(delegator);
        stakeHub.claim(operator, 1); // partial claim
        assertEq(delegator.balance - before, first.bnbAmount);
        assertEq(credit.pendingUnbondRequest(delegator), 1);
        vm.prank(delegator);
        stakeHub.claim(operator, 0);
        assertEq(delegator.balance - before, first.bnbAmount + second.bnbAmount);
        assertEq(credit.pendingUnbondRequest(delegator), 0);
        vm.prank(delegator);
        vm.expectRevert(StakeCredit.NoUnbondRequest.selector);
        stakeHub.claim(operator, 0);
    }

    // Unchanged or longer periods are untouched by the clamp, and once the
    // queue drains a request gets the short period again.
    function testUnbondPeriodUnchangedOrRaised() public {
        (address operator, address delegator, StakeCredit credit) = _undelegateSetup();
        _setUnbondPeriod(7 days);
        uint256 t0 = block.timestamp;
        vm.prank(delegator);
        stakeHub.undelegate(operator, 10 ether);
        vm.warp(t0 + 1 days);
        vm.prank(delegator);
        stakeHub.undelegate(operator, 10 ether);
        _setUnbondPeriod(10 days);
        vm.prank(delegator);
        stakeHub.undelegate(operator, 10 ether);
        assertEq(credit.unbondRequest(delegator, 0).unlockTime, t0 + 7 days);
        assertEq(credit.unbondRequest(delegator, 1).unlockTime, t0 + 8 days);
        assertEq(credit.unbondRequest(delegator, 2).unlockTime, t0 + 11 days);

        vm.warp(t0 + 11 days);
        vm.prank(delegator);
        stakeHub.claim(operator, 0);
        _setUnbondPeriod(3 days);
        vm.prank(delegator);
        stakeHub.undelegate(operator, 10 ether);
        assertEq(credit.unbondRequest(delegator, 0).unlockTime, t0 + 14 days);
    }

    // The clamp is per delegator: another delegator's long request does not
    // delay a new request.
    function testUnbondClampIsPerDelegator() public {
        (address operator, address delegator, StakeCredit credit) = _undelegateSetup();
        _setUnbondPeriod(30 days);
        vm.prank(delegator);
        stakeHub.undelegate(operator, 10 ether);
        _setUnbondPeriod(3 days);
        address other = address(0x07E4);
        vm.deal(other, 100 ether);
        vm.startPrank(other);
        stakeHub.delegate{ value: 100 ether }(operator, false);
        stakeHub.undelegate(operator, 10 ether);
        vm.stopPrank();
        assertEq(credit.unbondRequest(other, 0).unlockTime, block.timestamp + 3 days);
    }

    function _etchGovHub() internal {
        vm.etch(GOV_HUB_ADDR, vm.getDeployedCode("GovHub.sol:GovHub"));
    }

    // R3-GOV-02: a rejected update reverts the governance call with the
    // target's own error, so the timelock operation is not marked done.
    function testGovHubPropagatesTargetFailure() public {
        _etchGovHub();
        bytes memory bad = abi.encode(uint256(1 days));
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(SystemV2.InvalidValue.selector, "unbondPeriod", bad));
        IFLGovHub(GOV_HUB_ADDR).updateParam("unbondPeriod", bad, STAKE_HUB_ADDR);

        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(SystemV2.UnknownParam.selector, "noSuchKey", bad));
        IFLGovHub(GOV_HUB_ADDR).updateParam("noSuchKey", bad, STAKE_HUB_ADDR);

        vm.prank(TIMELOCK);
        vm.expectRevert(bytes("the target is not a contract"));
        IFLGovHub(GOV_HUB_ADDR).updateParam("unbondPeriod", abi.encode(uint256(5 days)), address(0xBEEF));

        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("the msg sender must be governor timelock contract"));
        IFLGovHub(GOV_HUB_ADDR).updateParam("unbondPeriod", abi.encode(uint256(5 days)), STAKE_HUB_ADDR);
    }

    function testGovHubAppliesValidUpdate() public {
        _etchGovHub();
        vm.prank(TIMELOCK);
        IFLGovHub(GOV_HUB_ADDR).updateParam("unbondPeriod", abi.encode(uint256(5 days)), STAKE_HUB_ADDR);
        assertEq(stakeHub.unbondPeriod(), 5 days);
    }

    function govBatchExternal(bytes memory secondValue) external {
        IFLGovHub(GOV_HUB_ADDR).updateParam("unbondPeriod", abi.encode(uint256(5 days)), STAKE_HUB_ADDR);
        IFLGovHub(GOV_HUB_ADDR).updateParam("unbondPeriod", secondValue, STAKE_HUB_ADDR);
    }

    // Two actions executed in one call (as the timelock does for a batch): a
    // failing second action rolls back the first.
    function testGovHubBatchIsAtomic() public {
        _etchGovHub();
        uint256 before = stakeHub.unbondPeriod();
        vm.etch(TIMELOCK, address(this).code);
        vm.expectRevert();
        FinalLayerGovernanceTest(TIMELOCK).govBatchExternal(abi.encode(uint256(1 days)));
        assertEq(stakeHub.unbondPeriod(), before);
        FinalLayerGovernanceTest(TIMELOCK).govBatchExternal(abi.encode(uint256(6 days)));
        assertEq(stakeHub.unbondPeriod(), 6 days);
    }
}
