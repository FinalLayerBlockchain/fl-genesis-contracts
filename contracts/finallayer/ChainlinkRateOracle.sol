// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.17;

import "./IFeeCurrency.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @dev Prepared for later, NOT deployed at genesis: a price source that reads
 * Chainlink USD feeds once Chainlink (or a compatible reporter network) serves
 * Final Layer. Governance switches a token to it by deploying this contract and
 * voting setCurrencyConfig(token, <this>, gas) on the FeeCurrencyDirectory; the
 * node needs no change.
 *
 * Needs two feeds: FL/USD (shared) and TOKEN/USD (per token). When either feed
 * is missing, unreachable, non-positive or stale, the token falls back to its
 * last governance-set rate in the FixedRateOracle (0x...5053). Only if that
 * fallback is also missing or expired does the call revert, which turns the
 * token off as a fee currency rather than pricing gas wrongly. Governance
 * should therefore keep a fixed rate on file for every Chainlink-priced token.
 *     tokenAmount = flWei * flUsd * 10^tokenDecimals * 10^tokenFeedDecimals
 *                   / (tokenUsd * 10^18 * 10^flFeedDecimals)
 */
contract ChainlinkRateOracle is IFeeCurrencyOracle {
    address public constant FALLBACK = 0x0000000000000000000000000000000000005053; // FixedRateOracle
    address public immutable governance;

    struct TokenFeed {
        AggregatorV3Interface feed; // TOKEN/USD
        uint8 tokenDecimals;
        uint64 maxAge; // seconds
    }

    AggregatorV3Interface public flUsdFeed;
    uint64 public flUsdMaxAge;
    mapping(address => TokenFeed) public tokenFeeds;

    event FlUsdFeedSet(address feed, uint64 maxAge);
    event TokenFeedSet(address indexed token, address feed, uint8 tokenDecimals, uint64 maxAge);

    modifier onlyGovernance() {
        require(msg.sender == governance, "only governance");
        _;
    }

    constructor(address _governance) {
        require(_governance != address(0), "zero governance");
        governance = _governance;
    }

    function setFlUsdFeed(address feed, uint64 maxAge) external onlyGovernance {
        require(feed.code.length > 0 && maxAge > 0, "bad feed");
        flUsdFeed = AggregatorV3Interface(feed);
        flUsdMaxAge = maxAge;
        emit FlUsdFeedSet(feed, maxAge);
    }

    function setTokenFeed(address token, address feed, uint8 tokenDecimals, uint64 maxAge) external onlyGovernance {
        require(feed.code.length > 0 && maxAge > 0 && tokenDecimals <= 36, "bad feed");
        tokenFeeds[token] = TokenFeed(AggregatorV3Interface(feed), tokenDecimals, maxAge);
        emit TokenFeedSet(token, feed, tokenDecimals, maxAge);
    }

    // Gas given to each feed call. The node reads a rate with a 200k budget
    // (core/fee_currency.go feeCurrencyLookupGas); two feeds at these caps plus
    // the directory and the fallback stay inside it, so a feed that burns gas
    // falls back instead of switching the token off. A Chainlink proxy needs
    // roughly 25k for latestRoundData and 8k for decimals.
    uint256 private constant FEED_GAS = 50_000;
    uint256 private constant DECIMALS_GAS = 15_000;

    /// @dev Reads a feed without reverting; ok == false on any problem.
    /// Low-level calls on purpose: try/catch does not catch a reply that fails
    /// to decode (empty, short, or a value outside the declared type), and a
    /// plain call would hand the feed all of the node's lookup budget.
    function _read(AggregatorV3Interface feed, uint64 maxAge) internal view returns (bool ok, uint256 price, uint8 dec) {
        if (address(feed) == address(0) || address(feed).code.length == 0) return (false, 0, 0);
        (bool success, bytes memory ret) =
            address(feed).staticcall{ gas: FEED_GAS }(abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector));
        if (!success || ret.length < 160) return (false, 0, 0);
        (uint256 roundId, int256 answer,, uint256 updatedAt, uint256 answeredInRound) =
            abi.decode(ret, (uint256, int256, uint256, uint256, uint256));
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return (false, 0, 0);
        if (block.timestamp - updatedAt > maxAge || answeredInRound < roundId) return (false, 0, 0);
        price = uint256(answer);
        (success, ret) = address(feed).staticcall{ gas: DECIMALS_GAS }(abi.encodeWithSelector(AggregatorV3Interface.decimals.selector));
        if (!success || ret.length < 32) return (false, 0, 0);
        uint256 d = abi.decode(ret, (uint256));
        if (d > 36) return (false, 0, 0);
        dec = uint8(d);
        ok = true;
    }

    /// @dev Chainlink price if both feeds are healthy, else the fixed-rate fallback.
    function getExchangeRate(address token) external view override returns (uint256 numerator, uint256 denominator) {
        (bool ok, uint256 n, uint256 d) = chainlinkRate(token);
        if (ok) return (n, d);
        return IFeeCurrencyOracle(FALLBACK).getExchangeRate(token);
    }

    /// @dev The Chainlink-only rate (ok == false when it is unusable).
    function chainlinkRate(address token) public view returns (bool ok, uint256 numerator, uint256 denominator) {
        TokenFeed memory t = tokenFeeds[token];
        if (address(t.feed) == address(0)) return (false, 0, 0);
        (bool ok1, uint256 flUsd, uint8 flDec) = _read(flUsdFeed, flUsdMaxAge);
        (bool ok2, uint256 tokenUsd, uint8 tokenFeedDec) = _read(t.feed, t.maxAge);
        if (!ok1 || !ok2) return (false, 0, 0);
        // keep the math from overflowing (an overflow would revert instead of falling back)
        if (flUsd >= 2 ** 128 || tokenUsd >= 2 ** 128) return (false, 0, 0);
        if (uint256(t.tokenDecimals) + tokenFeedDec > 38 || 18 + uint256(flDec) > 38) return (false, 0, 0);
        numerator = flUsd * 10 ** (uint256(t.tokenDecimals) + tokenFeedDec);
        denominator = tokenUsd * 10 ** (18 + uint256(flDec));
        ok = numerator > 0 && denominator > 0;
    }
}
