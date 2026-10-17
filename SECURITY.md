# Security Policy

## Supported versions

Only the latest commit on `master` is supported. Final
Layer chain ID `20261012` deploys these contracts at genesis; the earlier java-tron based Final Layer
network is retired and its code is not supported.

## Scope

In scope: every contract listed in [`docs/FINAL-LAYER-CHANGES.md`](docs/FINAL-LAYER-CHANGES.md)
and any upstream contract whose behavior those changes affect.

Of most interest:

- minting, redirecting or blocking staking inflation (`distributeStakingInflation` must never revert)
- registering or rotating a consensus key without a valid ML-DSA-87 proof of possession
- any governance-reachable state that halts block production or the daily breathe block
- slashing an honest validator, or escaping a slash for double signing
- gaining pause, blacklist or upgrade authority outside governance

## Audit reports

| Scope | Date | Auditor | Report |
| --- | --- | --- | --- |
| Final Layer contracts | none yet | | No third-party audit has been completed. |

Reports will be published in [`docs/audits/`](docs/audits) as `YYYY-MM-DD_<scope>_<auditor>.pdf`.
Audits of upstream bsc-genesis-contract cover upstream code only.

## Reporting a vulnerability

**Do not open a public issue.** Report privately through GitHub:
**Security → Report a vulnerability** on this repository. Include the affected commit, a
description, and a reproduction (a failing test is ideal).

Published advisories are listed under [Security advisories](../../security/advisories).
