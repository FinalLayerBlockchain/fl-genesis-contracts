# Final Layer changes to upstream bsc-genesis-contract

12 files changed, about 2,220 lines added and 100 removed (tests included). Everything else is
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
| `contracts/BSCGovernor.sol` | Voting delay, voting period and minimum period after quorum bounded in blocks (3 s blocks) instead of seconds |
| `contracts/GovHub.sol` | A failed parameter update reverts the whole call (atomic multi-action proposals, retryable) |
| `contracts/StakeCredit.sol` | Unbond queue unlock times never decrease after the unbond period is lowered |
| `contracts/SystemReward.sol` | `updateParam` runs init first; the validator and slash contracts cannot be removed as operators |
| `contracts/TokenRecoverPortal.sol` | Protector set to `0xdEaD` (no pause or blacklist authority) |
| `contracts/interface/*` | Interface updates for the above |
| `test/FinalLayerInflation.t.sol` | Inflation, election, rotation, slashing and halt-recovery tests |
| `test/FinalLayerGovernance.t.sol` | Blacklist routes, GovHub failure propagation, unbond queue ordering |

Genesis parameters: 5,000,000,000 FL to the treasury, PQ validator set, protector `0xdEaD`.
