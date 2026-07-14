# Security Policy

## Audit status

This code has **not** been audited. It is provided as-is under the MIT License. Do not deploy to production without an independent security review.

## Supported versions

Security fixes land on the latest `main`. Only the most recent published release receives backported patches.

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |
| older   | :x:                |

## Reporting a vulnerability

**Do not** file a public issue for security-relevant bugs.

Preferred channels:

1. GitHub's [private vulnerability reporting](https://github.com/Juglipaff/fair-reward-distributor/security/advisories/new) - encrypted, keeps disclosure private until a fix ships.
2. Email: juglipaff@gmail.com - PGP not required but welcome.

Please include:

- Affected commit SHA or version.
- Minimal Foundry test or transaction trace that demonstrates the issue.
- Impact assessment: what value is at risk, under what conditions.
- Suggested mitigation, if you have one.

## What to expect

- **Acknowledgement**: within 72 hours.
- **Initial assessment**: within 7 days - confirmed / needs-info / declined with reasoning.
- **Fix timeline**: depends on severity. Critical issues affecting funds → patch and coordinated disclosure within 30 days where feasible. Lower-severity issues follow the normal PR flow.
- **Disclosure**: coordinated. A GitHub Security Advisory will be published after the fix ships. Reporter credit is included unless anonymity is requested.
- **No bug bounty.** This is an unfunded open-source project. Recognition and credit are the only rewards offered.

## Scope

In scope:

- Any bug in `src/` that violates the invariants documented in the README ("What this contract does", "Assumptions and limits").
- Storage layout corruption, unexpected reverts, unbounded gas, incorrect reward accounting, integer overflow / underflow escaping the guards.

Out of scope:

- Bugs in consumer contracts that misuse the abstract contract. Those live in the consumer's audit surface.
- Bugs in third-party dependencies (OpenZeppelin, forge-std). Report those upstream.
