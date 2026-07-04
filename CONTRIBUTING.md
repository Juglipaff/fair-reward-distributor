# Contributing

Thanks for your interest. This is a small library repo — contributions are welcome but scope is deliberately narrow.

## Scope

The library provides one thing: a constant-gas, stake-age-weighted, front-run-resistant reward distribution primitive. Changes that fit this scope are welcome:

- Bug fixes with an accompanying test that fails without the fix.
- Gas optimizations backed by `forge snapshot` before/after numbers.
- Documentation clarifications.
- Additional test cases covering under-tested paths (fuzz seeds, invariants).

Out of scope:

- New reward-distribution primitives (open a discussion first — likely a separate repo).
- Additional token standards, wrappers, or example integrations in this repo (belongs downstream).
- Style refactors that don't fix a bug or improve a measurable metric.

## Development setup

```bash
git clone https://github.com/Juglipaff/fair-reward-distributor.git
cd fair-reward-distributor
forge test
```

Foundry pulls Solidity dependencies as git submodules under `lib/` on first build. Node tooling (formatter) is optional:

```bash
pnpm install
pnpm exec prettier --check "src/**/*.sol" "test/**/*.sol"
```

## Style

- Solidity style follows the pattern documented in existing sources: named imports only, section headers (`// ============ ... ============`), full NatSpec on every declaration, `///@dev` inline comments on state variables. Match what's already there.
- Formatter is `forge fmt` + `prettier-plugin-solidity`. Both must pass.
- No new external dependencies without a strong justification. The runtime footprint is currently OpenZeppelin `Math` + `SafeCast` only.

## Testing

Every behavioral change needs test coverage. This repo aims for 100% branch coverage.

```bash
forge test               # unit + fuzz
forge coverage           # coverage report
forge snapshot           # gas snapshot; commit if the change is intentional
```

New tests should be property-based / fuzz where the invariant is universal (conservation of reward, monotonicity of `stakeAge`, etc.). Reserve unit tests for specific edge cases and error paths.

## Commits

- One logical change per commit.
- Conventional-commit prefixes: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`.
- Subject in imperative mood, ≤ 72 chars.
- Body explains **why**, not what — the diff shows what.

## Pull requests

- Open against `main`.
- Fill in the PR template.
- CI (`forge test`) must pass. Coverage upload to Coveralls must not regress.
- Squash-merge is the default. Keep the PR title clean — it becomes the merged commit subject.

## Security

Do **not** file security-relevant issues in the public tracker. Email juglipaff@gmail.com. This repo has not been audited; treat vulnerabilities accordingly.

## License

By contributing, you agree that your contributions will be licensed under the MIT License (see [LICENSE](./LICENSE)).
