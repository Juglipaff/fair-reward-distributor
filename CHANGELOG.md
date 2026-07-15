# Changelog

## [4.0.0](https://github.com/Juglipaff/fair-reward-distributor/compare/v3.0.0...v4.0.0) (2026-07-15)


### ⚠ BREAKING CHANGES

* separate reward collection from stake withdrawal ([#13](https://github.com/Juglipaff/fair-reward-distributor/issues/13))

### Features

* separate reward collection from stake withdrawal ([#13](https://github.com/Juglipaff/fair-reward-distributor/issues/13)) ([374bad7](https://github.com/Juglipaff/fair-reward-distributor/commit/374bad7785bf5bb8f5d4faa312efc29b524e58c3))

## [3.0.0](https://github.com/Juglipaff/fair-reward-distributor/compare/v2.0.0...v3.0.0) (2026-07-14)


### ⚠ BREAKING CHANGES

* `_postStake` / `_postWithdraw` / `_postDistribute` are removed.

### Features

* FairRewardDistributorERC4626 wrapper + ABI export + CI hardening ([#11](https://github.com/Juglipaff/fair-reward-distributor/issues/11)) ([1094ed4](https://github.com/Juglipaff/fair-reward-distributor/commit/1094ed49611951f6a11aef0f84bb2747331905d4))

## [2.0.0](https://github.com/Juglipaff/fair-reward-distributor/compare/v1.0.6...v2.0.0) (2026-07-06)


### ⚠ BREAKING CHANGES

* `_preStake` / `_preWithdraw` / `_preDistribute` are removed. `_stake`, `_withdraw`, `_distribute` now accept `uint128` liquidity directly, so consumers must narrow (e.g. via `SafeCast.toUint128`) at the external boundary. `InsufficientStake` is renamed to `InsufficientLiquidity` and now carries the raw `uint256`.

### Features

* remove pre-hooks; internal API now takes uint128 directly ([d05708a](https://github.com/Juglipaff/fair-reward-distributor/commit/d05708ac30f90090cee9a52a1de7304f430342a8))


### Documentation

* assorted README + CONTRIBUTING polish ([f14814b](https://github.com/Juglipaff/fair-reward-distributor/commit/f14814b9196d950d1b446d237b144346a3bd4c16))

## [1.0.6](https://github.com/Juglipaff/fair-reward-distributor/compare/v1.0.5...v1.0.6) (2026-07-05)


### Bug Fixes

* preserve per-user stakeAge across re-stake within a window ([c2cd24c](https://github.com/Juglipaff/fair-reward-distributor/commit/c2cd24c46b5cc567862e5003737a115ecb3edeb9))


### Documentation

* fix stake-age sum rendering with MathJax ([c84f337](https://github.com/Juglipaff/fair-reward-distributor/commit/c84f337a141cfb0be360cad775be6511cb784c95))
* revert block-range MathJax on line 54 ([5cc9ff3](https://github.com/Juglipaff/fair-reward-distributor/commit/5cc9ff34d35e6bb66a2d22b287f35d9df56b540d))
* unify inline math to MathJax style ([377aadf](https://github.com/Juglipaff/fair-reward-distributor/commit/377aadfa7ea495790ba0c8f35dcb38a83ac4ca85))
* wrap remaining range expressions in MathJax ([2cc1192](https://github.com/Juglipaff/fair-reward-distributor/commit/2cc11921ff4d73245a07df04ecc5d7c0e4db63f0))

## [1.0.5](https://github.com/Juglipaff/fair-reward-distributor/compare/v1.0.4...v1.0.5) (2026-07-04)


### Chores

* trigger release ([67d75b5](https://github.com/Juglipaff/fair-reward-distributor/commit/67d75b55577b2f66e6f869d4360e5f1df072a8e3))

## [1.0.4](https://github.com/Juglipaff/fair-reward-distributor/compare/v1.0.3...v1.0.4) (2026-07-04)


### Chores

* trigger release ([931095f](https://github.com/Juglipaff/fair-reward-distributor/commit/931095fc59621d33e11b0ba97b7f83502c6c2106))

## [1.0.3](https://github.com/Juglipaff/fair-reward-distributor/compare/v1.0.2...v1.0.3) (2026-07-04)


### Bug Fixes

* **pkg:** drop remappings.txt from npm tarball ([286ac8d](https://github.com/Juglipaff/fair-reward-distributor/commit/286ac8d23bd3155c2d33f9bb1bbe16bba0482137))


### Documentation

* switch license badge to github source ([d187df6](https://github.com/Juglipaff/fair-reward-distributor/commit/d187df68a310e648d5c92813d31e899e15d15a3f))

## [1.0.2](https://github.com/Juglipaff/fair-reward-distributor/compare/fair-reward-distributor-v1.0.1...fair-reward-distributor-v1.0.2) (2026-07-04)


### Bug Fixes

* **pkg:** drop remappings.txt from npm tarball ([286ac8d](https://github.com/Juglipaff/fair-reward-distributor/commit/286ac8d23bd3155c2d33f9bb1bbe16bba0482137))


### Documentation

* switch license badge to github source ([d187df6](https://github.com/Juglipaff/fair-reward-distributor/commit/d187df68a310e648d5c92813d31e899e15d15a3f))
