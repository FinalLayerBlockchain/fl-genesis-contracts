# Final Layer genesis contracts (fl-genesis-contracts)

System contracts deployed in the genesis of Final Layer (chain ID `20261012`), the post-quantum
EVM Layer 1 built on the [BNB Smart Chain client](https://github.com/bnb-chain/bsc). This is a fork
of [bnb-chain/bsc-genesis-contract](https://github.com/bnb-chain/bsc-genesis-contract), changed so
that validators, staking and governance work with ML-DSA-87 consensus keys and pay daily staking
inflation.

Final Layer previously ran on a java-tron based codebase. That network is retired; these
contracts belong to the current bsc-geth based chain, whose node is
[fl-node](https://github.com/FinalLayerBlockchain/fl-node).

## What Final Layer changed

| Area | Summary |
| --- | --- |
| Consensus keys | Validators register an ML-DSA-87 consensus key with a proof of possession; key rotation is frozen while Parlia's set and the contract's set differ, and blocked if it would take the chain below liveness |
| Staking inflation | 12% APR (`stakingAprBps = 1200`, hard cap 20%) minted daily by the node and split across the elected pools by a previous-breathe snapshot; a validator bonus share (cap 50%); retries, carry and a full backlog after a halt |
| Election bounds | At most 50 inflation validators, a raise-only registration cap (default 500, ceiling 2,000), 100,000 FL minimum self-delegation |
| Slashing | Double-sign evidence is ML-DSA seals over the real chain ID; rotated keys are not charged downtime |
| Governance | Governor bounds expressed in blocks (3 s), failed GovHub updates revert, cabinet count stays above the maintaining count, no protector address (`0xdEaD`: nobody can pause or blacklist unless governance appoints one) |

The file-by-file map is in [`docs/FINAL-LAYER-CHANGES.md`](docs/FINAL-LAYER-CHANGES.md).

## For auditors

1. The first commit is the unmodified upstream snapshot; every Final Layer change is a separate
   commit on top, so `git diff $(git rev-list --max-parents=0 HEAD) HEAD` is the full delta
   (12 files).
2. Final Layer tests: `test/FinalLayerInflation.t.sol` and `test/FinalLayerGovernance.t.sol`.
3. [`SECURITY.md`](SECURITY.md) for scope and vulnerability reporting.

## Build and test

```shell
npm install
git clone --depth 1 --recurse-submodules --shallow-submodules --branch v1.7.3 https://github.com/foundry-rs/forge-std lib/forge-std
forge test --match-path 'test/FinalLayer*.t.sol'
```

The genesis allocation is produced from these contracts by `make_genesis.py` in
[fl-network](https://github.com/FinalLayerBlockchain/fl-network).

## License

Apache 2.0, as upstream (see `LICENCE`). The upstream README is kept as
[`README.bsc.md`](README.bsc.md).
