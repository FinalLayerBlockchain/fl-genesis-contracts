pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../contracts/finallayer/FeeCurrencyDirectory.sol";
import "../contracts/finallayer/FixedRateOracle.sol";
import "../contracts/finallayer/ChainlinkRateOracle.sol";
import "../contracts/finallayer/FeeCurrencyERC20.sol";

contract MockFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 d) {
        decimals = d;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function setRounds(uint80 r, uint80 a) external {
        roundId = r;
        answeredInRound = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

contract RevertingOracle is IFeeCurrencyOracle {
    function getExchangeRate(address) external pure returns (uint256, uint256) {
        revert("down");
    }
}

contract FinalLayerFeeCurrencyTest is Test {
    address constant GOV = 0x0000000000000000000000000000000000002006;
    address constant DIRECTORY = 0x0000000000000000000000000000000000005052;
    address constant ORACLE = 0x0000000000000000000000000000000000005053;
    address constant TOKEN = 0x0000000000000000000000000000000000005054;
    address constant TREASURY = address(0x7EA5);

    FeeCurrencyDirectory dir;
    FixedRateOracle oracle;
    FLTestDollar token;

    function setUp() public {
        vm.warp(1_800_000_000);
        // Same bytecode placement as the genesis generator.
        vm.etch(DIRECTORY, address(new FeeCurrencyDirectory()).code);
        vm.etch(ORACLE, address(new FixedRateOracle()).code);
        vm.etch(TOKEN, address(new FLTestDollar()).code);
        dir = FeeCurrencyDirectory(DIRECTORY);
        oracle = FixedRateOracle(ORACLE);
        token = FLTestDollar(TOKEN);
    }

    // ---------------------------------------------------------------- genesis layout
    // Mirrors scripts/make_genesis.py: if a storage slot moves, this fails.
    function _genesisStorage(uint256 num, uint256 den, uint256 gas, uint256 supply) internal {
        bytes32 cfg = keccak256(abi.encode(TOKEN, uint256(0)));
        vm.store(DIRECTORY, cfg, bytes32(uint256(uint160(ORACLE))));
        vm.store(DIRECTORY, bytes32(uint256(cfg) + 1), bytes32(gas));
        vm.store(DIRECTORY, bytes32(uint256(1)), bytes32(uint256(1)));
        vm.store(DIRECTORY, keccak256(abi.encode(uint256(1))), bytes32(uint256(uint160(TOKEN))));

        bytes32 r = keccak256(abi.encode(TOKEN, uint256(0)));
        vm.store(ORACLE, r, bytes32((den << 128) | num));
        vm.store(ORACLE, bytes32(uint256(r) + 1), bytes32(uint256(block.timestamp)));

        vm.store(TOKEN, keccak256(abi.encode(TREASURY, uint256(0))), bytes32(supply));
        vm.store(TOKEN, bytes32(uint256(2)), bytes32(supply));
    }

    function testGenesisLayout() public {
        _genesisStorage(1, 100, 50_000, 1e27);
        address[] memory list = dir.getCurrencies();
        assertEq(list.length, 1);
        assertEq(list[0], TOKEN);
        (uint256 n, uint256 d, uint256 g) = dir.getCurrencyConfigAndRate(TOKEN);
        assertEq(n, 1);
        assertEq(d, 100);
        assertEq(g, 50_000);
        FixedRateOracle.Rate memory rate = oracle.getRate(TOKEN);
        assertEq(rate.updatedAt, block.timestamp);
        assertEq(rate.maxAge, 0);
        assertEq(token.balanceOf(TREASURY), 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.symbol(), "FLTD");
        assertEq(token.decimals(), 18);
    }

    // ---------------------------------------------------------------- directory
    function testDirectoryOnlyGovernance() public {
        vm.expectRevert("only governance");
        dir.setCurrencyConfig(TOKEN, ORACLE, 50_000);
        vm.expectRevert("only governance");
        oracle.setRate(TOKEN, 1, 1, 0);
    }

    function testDirectoryAddChangeRemove() public {
        vm.startPrank(GOV);
        oracle.setRate(TOKEN, 3, 7, 0);
        dir.setCurrencyConfig(TOKEN, ORACLE, 50_000);
        dir.setCurrencyConfig(TOKEN, ORACLE, 60_000); // change, not a second entry
        vm.stopPrank();
        assertEq(dir.getCurrencies().length, 1);
        (uint256 n, uint256 d, uint256 g) = dir.getCurrencyConfigAndRate(TOKEN);
        assertEq(n, 3);
        assertEq(d, 7);
        assertEq(g, 60_000);

        vm.prank(GOV);
        dir.removeCurrency(TOKEN);
        assertEq(dir.getCurrencies().length, 0);
        vm.expectRevert("not a fee currency");
        dir.getCurrencyConfigAndRate(TOKEN);
    }

    function testDirectoryBounds() public {
        vm.startPrank(GOV);
        vm.expectRevert("intrinsic gas out of range");
        dir.setCurrencyConfig(TOKEN, ORACLE, 9_999);
        vm.expectRevert("intrinsic gas out of range");
        dir.setCurrencyConfig(TOKEN, ORACLE, 200_001);
        vm.expectRevert("token has no code");
        dir.setCurrencyConfig(address(0xBEEF), ORACLE, 50_000);
        vm.expectRevert("oracle has no code");
        dir.setCurrencyConfig(TOKEN, address(0xBEEF), 50_000);
        vm.stopPrank();
    }

    function testUnlistedTokenAndOracleFailure() public {
        vm.expectRevert("not a fee currency");
        dir.getExchangeRate(TOKEN);
        RevertingOracle bad = new RevertingOracle();
        vm.prank(GOV);
        dir.setCurrencyConfig(TOKEN, address(bad), 50_000);
        vm.expectRevert(bytes("down"));
        dir.getExchangeRate(TOKEN);
    }

    function testRateExpiry() public {
        vm.startPrank(GOV);
        oracle.setRate(TOKEN, 1, 100, 1 days);
        dir.setCurrencyConfig(TOKEN, ORACLE, 50_000);
        vm.stopPrank();
        dir.getExchangeRate(TOKEN);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert("rate expired");
        dir.getExchangeRate(TOKEN);
        vm.prank(GOV);
        vm.expectRevert("zero rate");
        oracle.setRate(TOKEN, 0, 1, 0);
    }

    // ---------------------------------------------------------------- token
    function testDebitCreditOnlyNode() public {
        _genesisStorage(1, 1, 50_000, 1000);
        vm.expectRevert("only the node");
        token.debitGasFees(TREASURY, 1);
        address[] memory r = new address[](1);
        uint256[] memory a = new uint256[](1);
        vm.expectRevert("only the node");
        token.creditGasFees(r, a);
    }

    function testDebitCreditConserves() public {
        _genesisStorage(1, 1, 50_000, 1000);
        address producer = address(0xC0FFEE);
        vm.startPrank(address(0));
        token.debitGasFees(TREASURY, 300);
        assertEq(token.totalSupply(), 700);
        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](2);
        r[0] = TREASURY;
        r[1] = producer;
        a[0] = 120;
        a[1] = 180;
        token.creditGasFees(r, a);
        vm.stopPrank();
        assertEq(token.balanceOf(TREASURY), 820);
        assertEq(token.balanceOf(producer), 180);
        assertEq(token.totalSupply(), 1000);
    }

    function testDebitInsufficientReverts() public {
        _genesisStorage(1, 1, 50_000, 10);
        vm.prank(address(0));
        vm.expectRevert("insufficient balance for gas");
        token.debitGasFees(TREASURY, 11);
    }

    function testCreditLengthMismatch() public {
        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](1);
        vm.prank(address(0));
        vm.expectRevert("length mismatch");
        token.creditGasFees(r, a);
    }

    function testErc20Basics() public {
        _genesisStorage(1, 1, 50_000, 1000);
        address bob = address(0xB0B);
        vm.prank(TREASURY);
        token.transfer(bob, 10);
        vm.prank(bob);
        token.approve(address(this), 4);
        token.transferFrom(bob, TREASURY, 4);
        assertEq(token.balanceOf(bob), 6);
        vm.expectRevert("insufficient allowance");
        token.transferFrom(bob, TREASURY, 1);
        vm.prank(bob);
        vm.expectRevert("insufficient balance");
        token.transfer(TREASURY, 7);
    }

    // ---------------------------------------------------------------- chainlink (prepared)
    function testChainlinkRate() public {
        ChainlinkRateOracle cl = new ChainlinkRateOracle(GOV);
        MockFeed flUsd = new MockFeed(8);
        MockFeed usdcUsd = new MockFeed(8);
        flUsd.set(5_000_000, block.timestamp); // FL = $0.05
        usdcUsd.set(100_000_000, block.timestamp); // USDC = $1.00
        vm.startPrank(GOV);
        cl.setFlUsdFeed(address(flUsd), 1 hours);
        cl.setTokenFeed(TOKEN, address(usdcUsd), 6, 1 days);
        vm.stopPrank();
        (uint256 n, uint256 d) = cl.getExchangeRate(TOKEN);
        // 1 FL (1e18 wei) = 0.05 USDC = 50,000 units (6 decimals)
        assertEq(1e18 * n / d, 50_000);

        // a stale, unfinished or zero price is unusable; with no fixed rate on
        // file the token is off (the fallback reverts)
        vm.warp(block.timestamp + 1 hours + 1);
        (bool ok,,) = cl.chainlinkRate(TOKEN);
        assertFalse(ok, "stale");
        vm.expectRevert("no rate");
        cl.getExchangeRate(TOKEN);
        flUsd.set(5_000_000, block.timestamp);
        flUsd.setRounds(2, 1);
        (ok,,) = cl.chainlinkRate(TOKEN);
        assertFalse(ok, "unfinished round");
        flUsd.setRounds(2, 2);
        (ok,,) = cl.chainlinkRate(TOKEN);
        assertTrue(ok, "healthy again");
        usdcUsd.set(0, block.timestamp);
        (ok,,) = cl.chainlinkRate(TOKEN);
        assertFalse(ok, "zero price");
    }

    function testChainlinkPluggedIntoDirectory() public {
        ChainlinkRateOracle cl = new ChainlinkRateOracle(GOV);
        MockFeed flUsd = new MockFeed(8);
        MockFeed tUsd = new MockFeed(8);
        flUsd.set(2_000_000, block.timestamp);
        tUsd.set(100_000_000, block.timestamp);
        vm.startPrank(GOV);
        cl.setFlUsdFeed(address(flUsd), 1 hours);
        cl.setTokenFeed(TOKEN, address(tUsd), 18, 1 hours);
        dir.setCurrencyConfig(TOKEN, address(cl), 50_000);
        vm.stopPrank();
        (uint256 n, uint256 d,) = dir.getCurrencyConfigAndRate(TOKEN);
        assertEq(1e18 * n / d, 2e16); // 1 FL = 0.02 tokens
        vm.expectRevert("only governance");
        cl.setFlUsdFeed(address(flUsd), 1);
    }
}
