# Fair Reward Distributor

[![release](https://img.shields.io/github/v/release/Juglipaff/fair-reward-distributor?sort=semver)](https://github.com/Juglipaff/fair-reward-distributor/releases)
[![npm](https://img.shields.io/npm/v/@juglipaff/fair-reward-distributor.svg)](https://www.npmjs.com/package/@juglipaff/fair-reward-distributor)
[![coverage](https://coveralls.io/repos/github/Juglipaff/fair-reward-distributor/badge.svg?branch=main)](https://coveralls.io/github/Juglipaff/fair-reward-distributor?branch=main)
[![license](https://img.shields.io/npm/l/@juglipaff/fair-reward-distributor.svg)](./LICENSE)

> [!CAUTION]
> This code has **not** been audited. Use at your own risk. No warranty is provided, express or implied. Do not deploy to production without an independent security review.

Constant-gas, deposit-age-weighted, front-run-resistant on-chain reward distribution.

## Algorithm

Algorithm by [Ivan Menshchikov](https://github.com/Juglipaff) and [Roman Vinogradov](https://github.com/sapph1re). 
Full derivation: https://juglipaff.github.io/Token-Distribution-Algorithm/

### The problem

Three approaches have historically dominated on-chain reward distribution. Each has significant drawbacks:

**1. Merkle-tree airdrops.** An off-chain process computes each user's earned share (typically weighted by activity over some window), builds a Merkle tree of `(address, amount)` leaves, and publishes the root on-chain. Users claim by submitting a proof. Fair *by construction* — the off-chain computation can weight by anything — but **fundamentally centralized**:

- The operator computing the tree can include or exclude anyone, unilaterally.
- Users must trust the operator's data pipeline, or the project must fund extra infrastructure (indexers, ZK proofs, redundant computation) to make the tree verifiable.
- Distribution is discrete, gated by the operator publishing a new root.

**2. Fixed-emission-rate pools** (SushiSwap's `MasterChef`, Synthetix's `StakingRewards`, etc.). A constant `rewardPerBlock` or `rewardPerSecond` is set up front and streamed to whoever is staked at each block. Fully on-chain and trustless, but rigid:

- The reward budget must be committed ahead of time as an *emission schedule*, not a discrete amount. Adjusting mid-stream requires a governance / owner action.
- The rate is a policy parameter, not a market outcome — hard to align with irregular revenue sources (e.g. protocol fees that arrive lumpy).
- Susceptible to yield dilution when unrelated stakers park capital for the emission alone.

**3. Naïve pull-distribution pools.** A `distribute()` function splits an arbitrary amount proportionally to stake *at the moment of the call*. Discrete like a Merkle drop, permissionless like MasterChef — but suffers two well-known failures:

- **Front-running.** An attacker sees a pending `distribute()` in the mempool, deposits a large stake just before it lands, and withdraws right after. They capture a share of the reward without providing liquidity over time.
- **Late-joiner dilution.** A user who staked for the whole interval between distributions receives the same per-token share as a user who staked one block before distribution.

This contract is a **fourth option**: discrete pull-distribution like (3), fully on-chain and permissionless like (2) and (3), but time-weighted like (1) — closing the front-running and dilution gaps without off-chain infrastructure or a fixed emission schedule.

### What this contract does

Rewards accrue proportionally to **stake-age** — the integral of a user's stake over time, i.e. `Σ (stake_i × Δblocks_i)`. A user staked for the whole inter-distribution interval receives their full weight; a user staked one block before distribution receives one block's worth. Front-running is defeated because the attacker's stake-age contribution is negligible relative to the incumbents'.

### Why it's O(1)

The naïve implementation forces one of two unbounded loops: iterate all users on every distribution (to snapshot their stake-age), or iterate all past distributions on every user action (to compute owed reward). This contract eliminates both using a **prefix-sum accumulator**.

On every distribution at index `d`, the contract records:

- `rewardPerStakeAge[d] = rewardStake / totalStakeAge_over_last_interval`
- `cumRewardAgePerStakeAge[d] = cumRewardAgePerStakeAge[d-1] + rewardPerStakeAge[d] × (block[d] − block[d-1])`

The second field is a running prefix sum of reward-per-stake-age integrated over blocks, across every distribution so far.

Each user stores:

- `lastDistributionId` — the distribution they were last settled through
- `stakeAge` — local accumulator since their last action
- `stake`, `reward`

Owed reward for the range `(lastDistributionId, currentDistributionId]` is then a **subtraction of two prefix-sum snapshots** (O(1)) plus a single partial term for the interval between the user's last action and the next distribution. No loop over users, no loop over distributions.

Every user-facing operation — `stake`, `withdraw`, `distribute`, reward query — is a fixed number of storage reads and writes independent of participant count or distribution history.

## Assumptions and limits

- **Block numbers stored as `uint64`.** Rewards stop accruing beyond `block.number > 2⁶⁴ − 1` (≈1.8 × 10¹⁹). No mainnet or L2 comes near this. Stated so integrators of exotic execution environments know the horizon.
- **Stakes stored as `uint128`.** Both individual stakes and the pool total. `_stake` reverts with `TotalStakeOverflow` if the pool total would wrap. `_preStake` implementations must reject any input that would overflow when converted to internal units.
- **Distribution count stored as `uint64`.** Up to `2⁶⁴ − 1` distributions before `DistributionIdOverflow` reverts and further distributions become impossible. Unreachable in practice.
- **Consumer owns asset movement.** The contract is abstract and tracks accounting only. The inheriting contract is responsible for pulling / pushing the underlying tokens in the `_postStake` / `_postWithdraw` / `_postDistribute` hooks. Token semantics (allowance, fee-on-transfer, rebasing, non-standard `bool` returns) are the consumer's responsibility.
- **Withdraw draws from reward first, then principal.** A user's realized reward acts as an implicit balance that can be withdrawn without touching stake. This is a design choice — noted so consumers understand the semantics of `_withdraw`.
- **Integer rounding leaves dust.** Reward accounting uses fixed-point arithmetic with `DENOMINATOR = 2⁶⁴ − 1`. Each distribution computes `rewardPerStakeAge = (rewardStake × DENOMINATOR) / totalStakeAge`, and each per-user reward computes `stakeAge × rewardPerStakeAge / DENOMINATOR`. Two truncations per user per distribution mean the sum of all users' payouts is bounded above by the distributed amount but may be strictly less. Undistributed dust remains in the contract balance (never lost, never over-paid) and is silently absorbed into the next distribution's `totalStakeAge` denominator. For distributions much larger than the participant count this is negligible; for pathological cases (tiny reward split across many stakers), some wei may sit un-withdrawable until a later distribution.

## Dependencies

Runtime (Solidity):

- [`@openzeppelin/contracts`](https://github.com/OpenZeppelin/openzeppelin-contracts) — uses `utils/math/Math.sol` (`mulDiv` for overflow-safe fixed-point arithmetic) and `utils/math/SafeCast.sol` (checked narrowing to `uint64`).

Development / testing:

- [`forge-std`](https://github.com/foundry-rs/forge-std) — Foundry standard library (`Test`, `console`, cheatcodes).
- [`foundry`](https://github.com/foundry-rs/foundry) — build, test, coverage. Install via [`foundryup`](https://book.getfoundry.sh/getting-started/installation).
- [`prettier`](https://prettier.io/) + [`prettier-plugin-solidity`](https://github.com/prettier-solidity/prettier-plugin-solidity) — source formatting.

Foundry pulls Solidity dependencies as git submodules under `lib/`. `pnpm install` fetches formatter tooling.

## Usage

### Install

#### **Foundry** (git submodule):

```bash
forge install Juglipaff/fair-reward-distributor
```

Then add to `remappings.txt`:

```
@juglipaff/fair-reward-distributor/=lib/fair-reward-distributor/
```

#### **npm** (Hardhat, Truffle, or any Node-based toolchain):

```bash
npm install @juglipaff/fair-reward-distributor
```

### Integration

Extend the abstract contract and implement six hooks. The example below wraps a single ERC-20 as both stake and reward token, and demonstrates the `recipient` / `user` distinction — the caller can stake *on behalf of* another account and withdraw *to* an arbitrary address.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { FairRewardDistributor } from "@juglipaff/fair-reward-distributor/src/FairRewardDistributor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MyPool is FairRewardDistributor {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    constructor(IERC20 token_) {
        token = token_;
    }

    // Stake `amount` and credit the position to `recipient`. The caller (msg.sender)
    // pays the tokens; `recipient` owns the resulting stake and future rewards.
    function stakeFor(uint256 amount, address recipient) external {
        _stake(amount, recipient);
    }

    // Withdraw from msg.sender's own position and send the tokens to `recipient`.
    function withdrawTo(uint256 amount, address recipient) external {
        _withdraw(amount, msg.sender, recipient);
    }

    function distribute(uint256 amount) external {
        _distribute(amount);
    }

    // ---- pre-hooks: convert raw input into internal stake units ----
    // Identity casts here — the pool uses raw token amounts as stake units.
    function _preStake(uint256 liquidity) internal pure override returns (uint128) {
        return uint128(liquidity);
    }
    function _preWithdraw(uint256 liquidity) internal pure override returns (uint128) {
        return uint128(liquidity);
    }
    function _preDistribute(uint256 liquidity) internal pure override returns (uint128) {
        return uint128(liquidity);
    }

    // ---- post-hooks: move the underlying ----
    // Pull from the CALLER (msg.sender), not `recipient`. `recipient` is the
    // beneficiary of the position, but the caller is who authorized the transfer.
    function _postStake(uint128 stake_, address /*recipient*/) internal override {
        token.safeTransferFrom(msg.sender, address(this), stake_);
    }

    // `user` is whose position was reduced; `recipient` is who receives the funds.
    // In this pool the two can differ (see withdrawTo).
    function _postWithdraw(uint128 stake_, address /*user*/, address recipient) internal override {
        token.safeTransfer(recipient, stake_);
    }

    function _postDistribute(uint128 stake_) internal override {
        token.safeTransferFrom(msg.sender, address(this), stake_);
    }
}
```

Hook contract:

- `_preStake` / `_preWithdraw` / `_preDistribute` — pure/view conversion of raw caller input into internal `uint128` stake units. Return zero to reject.
- `_postStake` / `_postWithdraw` / `_postDistribute` — side-effectful hooks that move the underlying assets after accounting has been updated.

## Development

This repo uses Foundry for development and testing and git submodules for dependency management.
Clone the repo and run `forge test` to run tests. Forge will automatically install any missing dependencies.

```bash
git clone https://github.com/Juglipaff/fair-reward-distributor.git
cd fair-reward-distributor
forge test
```
