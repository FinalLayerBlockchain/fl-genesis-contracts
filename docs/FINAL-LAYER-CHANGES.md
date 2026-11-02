# Final Layer changes to upstream bsc-genesis-contract

19 files changed, about 4,050 lines added and 100 removed (tests included). Everything else is
unmodified upstream code.

```shell
BASE=$(git rev-list --max-parents=0 HEAD)
git diff --stat $BASE HEAD
```

| File | Change |
| --- | --- |
| `contracts/StakeHub.sol` | ML-DSA-87 consensus key registration with proof of possession (`PQ_PROOF_LENGTH` = 1 + 2592 + 4627 bytes); `editConsensusAddress` rotation with a liveness guard and a freeze window (`ROTATION_FREEZE_BLOCKS`); daily staking inflation: `pendingStakingInflation`, `distributeStakingInflation` (called by the node in the breathe block, must never revert), `retryStakingInflation`, inflation snapshot, validator bonus split; raise-only registration cap; consensus-key jail tracking (`isConsensusJailed`) |
| `contracts/BSCValidatorSet.sol` | Election and working-set rules for PQ validators; mining validators clamped to cabinets; forced-maintenance felony keeps the working signers; explicit turn length range {1, 3..7}; fee ratio setters validated before the first deposit; records the last removal of a working validator so StakeHub can freeze rotations |
| `contracts/SlashIndicator.sol` | Double-sign evidence verified against ML-DSA seals with the real chain ID (`20261012` does not fit upstream's `uint16`); a replaced consensus key is not charged downtime; `felonyThreshold >= DECREASE_RATE` so `clean()` entries always decay |
| `contracts/BSCGovernor.sol` | Voting delay, voting period and minimum period after quorum bounded in blocks (3 s blocks) instead of seconds; strict proposals (`isStrictProposal`): listing a fee currency, changing its rate or price source, unsuspending, and changes to governance machinery or validator-set / slash parameters need FOR votes of at least 30% of voting supply and at least 2/3 of votes cast (own tally in `_countVote`); removing a fee currency stays a normal proposal; the directory and fixed-rate oracle are whitelisted targets and GovHub cannot be unwhitelisted |
| `contracts/GovHub.sol` | A failed parameter update reverts the whole call (atomic multi-action proposals, retryable) |
| `contracts/StakeCredit.sol` | Unbond queue unlock times never decrease after the unbond period is lowered |
| `contracts/SystemReward.sol` | `updateParam` runs init first; the validator and slash contracts cannot be removed as operators |
| `contracts/TokenRecoverPortal.sol` | Protector set to `0xdEaD` (no pause or blacklist authority) |
| `contracts/interface/*` | Interface updates for the above |
| `contracts/finallayer/FeeCurrencyDirectory.sol` | Genesis contract at `0x...5052`: the list of ERC-20s that may pay gas (max 32), each with a price source and the token's intrinsic gas (40,000 to 200,000). Governance (timelock) lists and removes. Validators, weighted by voting power from the last election (2/3 of the working set), can suspend a token immediately and can list, change a rate or unsuspend only after a 1-day delay that they can cancel; a token nonce voids stale approvals |
| `contracts/finallayer/FixedRateOracle.sol` | Genesis contract at `0x...5053`: governance-set FL-to-token rates with a maximum age |
| `contracts/finallayer/ChainlinkRateOracle.sol` | Optional Chainlink price source (not deployed at genesis); feed reads are gas-capped static calls and any failure or malformed reply falls back to the fixed rate |
| `contracts/finallayer/FeeCurrencyERC20.sol`, `IFeeCurrency.sol` | Minimal fee-payable ERC-20 (debit/credit callable only by the protocol, `address(0)`) and the interface the node calls; the test token FLTD at `0x...5054` uses it |
| `test/FinalLayerInflation.t.sol` | Inflation, election, rotation, slashing and halt-recovery tests |
| `test/FinalLayerGovernance.t.sol` | Blacklist routes, GovHub failure propagation, unbond queue ordering |
| `test/FinalLayerFeeCurrency.t.sol`, `test/FinalLayerFeeGovernance.t.sol` | Fee currency listing, rates, debit/credit, strict votes, validator actions and delays |

Genesis parameters: 5,000,000,000 FL to the treasury, PQ validator set, protector `0xdEaD`, fee currency directory `0x...5052`, fixed-rate oracle `0x...5053`, test fee token FLTD `0x...5054`. Current network genesis hash `0x7112dbb0c7524c3c0b15a04be6d69ea1c8976309bcaa02f9b132ff385fbe69d2`.
