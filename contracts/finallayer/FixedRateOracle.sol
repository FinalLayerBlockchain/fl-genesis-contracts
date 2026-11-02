// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.17;

import "./IFeeCurrency.sol";

/**
 * @dev Governance-set exchange rates for fee currencies (the starting price
 * source; no external oracle, and the fallback of ChainlinkRateOracle).
 * Pre-deployed in genesis at 0x0000000000000000000000000000000000005053.
 * Rates are set by a passed governance vote (BSCTimelock, strict vote) or by
 * the directory carrying out a validator listing (2/3 of stake); removing a rate (which
 * switches the token off unless another source is used) is a normal vote.
 *
 * Rate = token units per wei of FL: tokenAmount = flAmount * numerator / denominator.
 * maxAge > 0 makes a rate expire that many seconds after it was set, so a
 * stale price switches the token off instead of mispricing gas.
 * Storage layout is fixed: the genesis generator writes slot 0 directly.
 */
contract FixedRateOracle is IFeeCurrencyOracle {
    address public constant GOVERNANCE = 0x0000000000000000000000000000000000002006; // BSCTimelock
    // The directory sets a rate when validators with 2/3 of the stake listed a token with one
    // (after its 1-day wait); see FeeCurrencyDirectory.validatorSetConfig.
    address public constant DIRECTORY = 0x0000000000000000000000000000000000005052;

    struct Rate {
        uint128 numerator;
        uint128 denominator;
        uint64 updatedAt;
        uint64 maxAge; // seconds, 0 = never expires
    }

    mapping(address => Rate) internal rates; // slot 0

    event RateSet(address indexed token, uint256 numerator, uint256 denominator, uint256 maxAge);
    event RateRemoved(address indexed token);

    modifier onlyGovernance() {
        require(msg.sender == GOVERNANCE, "only governance");
        _;
    }

    function setRate(address token, uint128 numerator, uint128 denominator, uint64 maxAge) external {
        require(msg.sender == GOVERNANCE || msg.sender == DIRECTORY, "only governance");
        require(numerator > 0 && denominator > 0, "zero rate");
        rates[token] = Rate(numerator, denominator, uint64(block.timestamp), maxAge);
        emit RateSet(token, numerator, denominator, maxAge);
    }

    function removeRate(address token) external onlyGovernance {
        delete rates[token];
        emit RateRemoved(token);
    }

    function getRate(address token) external view returns (Rate memory) {
        return rates[token];
    }

    function getExchangeRate(address token) external view override returns (uint256 numerator, uint256 denominator) {
        Rate memory r = rates[token];
        require(r.numerator > 0 && r.denominator > 0, "no rate");
        require(r.maxAge == 0 || block.timestamp <= uint256(r.updatedAt) + r.maxAge, "rate expired");
        return (r.numerator, r.denominator);
    }
}
