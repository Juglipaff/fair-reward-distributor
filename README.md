# Fair Reward Distributor

[![release](https://img.shields.io/github/v/release/Juglipaff/fair-reward-distributor?sort=semver)](https://github.com/Juglipaff/fair-reward-distributor/releases)
[![npm](https://img.shields.io/npm/v/@juglipaff/fair-reward-distributor.svg)](https://www.npmjs.com/package/@juglipaff/fair-reward-distributor)
[![coverage](https://coveralls.io/repos/github/Juglipaff/fair-reward-distributor/badge.svg?branch=main)](https://coveralls.io/github/Juglipaff/fair-reward-distributor?branch=main)
[![license](https://img.shields.io/github/license/Juglipaff/fair-reward-distributor.svg)](./LICENSE)

> [!CAUTION]
> This code has **not** been audited. Use at your own risk. No warranty is provided, express or implied. Do not deploy to production without an independent security review.

Constant-gas, deposit-time-weighted, front-run-resistant on-chain reward distribution.

## Algorithm

[Full Algorithm derivation](https://juglipaff.github.io/Token-Distribution-Algorithm/) by [Ivan Menshchikov](https://github.com/Juglipaff) and [Roman Vinogradov](https://github.com/sapph1re).

### The problem

Three approaches have historically dominated on-chain reward distribution. Each has significant drawbacks:

**1. Merkle-tree airdrops**:
An off-chain process computes each user's earned share (typically weighted by activity over some window), builds a Merkle tree of `(address, amount)` leaves, and publishes the root on-chain. Users claim by submitting a proof. This approach is flexible, as the off-chain computation can weight by anything. However, it is fundamentally centralized and trust-based: the root is produced by a single operator who can change the rules, alter weights, or exclude addresses between snapshots, and nothing on-chain constrains them. Users must trust the operator's data pipeline, or the project must fund extra infrastructure (indexers, ZK proofs, redundant computation) to make the tree verifiable.

**2. Fixed-emission-rate pools** (SushiSwap's `MasterChef`, Synthetix's `StakingRewards`, etc.): 
A constant emission rate is streamed to whoever is staked at each block. Fully on-chain and trustless, but rigid, as the reward budget must be committed ahead of time as an emission rate over a window, not a discrete amount tied to when revenue actually arrives. Adjusting mid-window requires a governance / owner action. This rate is a policy parameter, not a market outcome, which makes it hard to align it with irregular revenue sources (e.g. protocol fees that arrive lumpy).

**3. Naïve pull-distribution pools**:
A `distribute()` function splits an arbitrary amount proportionally to stake at the moment of the call. Discrete like a Merkle drop, permissionless like MasterChef, and made O(1) by the prefix-sum accumulator described in Batog, Boca, and Johnson's [Scalable Reward Distribution on the Ethereum Blockchain](https://batog.info/papers/scalable-reward-distribution.pdf). But it suffers two well-known failures. First, front-running: an attacker sees a pending `distribute()` in the mempool, deposits a large stake just before it lands, and withdraws right after, capturing a share of the reward without providing liquidity over time. Second, late-joiner dilution: a user who staked for the whole interval between distributions receives the same per-token share as a user who staked one block before distribution. Proposals like Centrifuge's [epoch-based reward distribution](https://centrifuge.hackmd.io/@Luis/SkB07jq8o) address front-running by locking rewards behind an epoch boundary, but at the cost of UX (no claiming immediately after a distribution, painful for weekly / monthly cadences) and without eliminating late-joiner dilution precisely.

This contract is a fourth option: discrete pull-distribution like (3), fully on-chain and permissionless like (2) and (3), but time-weighted like (1), closing the front-running and dilution gaps without off-chain infrastructure, a fixed emission schedule, or an epoch lockout on claims.

### What this contract does

Rewards accrue proportionally to each user's share of total stake-age over the inter-distribution interval, where stake-age captures both how much and how long each user was staked. Payouts are relative: a sole participant collects everything regardless of duration, and with multiple participants, a user staked for the whole interval captures a much larger share than one staked briefly. Front-running is defeated because a last-block depositor's contribution to total stake-age is negligible next to participants who accrued it over the full interval.

### Why it's O(1)

The naïve implementation forces one of two unbounded loops: iterate all users on every distribution (to snapshot their stake-age), or iterate all past distributions on every user action (to compute owed reward). This contract eliminates both using a prefix-sum accumulator.

On every distribution at index `d`, the contract records:

- `rewardPerStakeAge[d] = reward / distributionStakeAge`
- `cumRewardAgePerStakeAge[d] = cumRewardAgePerStakeAge[d-1] + rewardPerStakeAge[d] × (block[d] − block[d-1])` 

The second field is a running prefix sum of reward-per-stake-age integrated over blocks, across every distribution so far. The key insight is that if a user's stake stays constant across distributions `a+1..b`, their total owed reward across that run is $stake \times \sum_{i=a+1}^{b} (rewardPerStakeAge[i] \times (block[i] - block[i-1]))$ - exactly the increments folded into `cumRewardAgePerStakeAge`. Subtracting two snapshots of that prefix sum recovers any range, so the whole sum equals `stake × (cumRewardAgePerStakeAge[b] − cumRewardAgePerStakeAge[a])`. Thus, an arbitrary number of distributions collapses to O(1) work.

Each user stores:

- `lastDistributionId` - the distribution they were last settled through
- `lastUpdateBlock` - the block they made their last action at.
- `stakeAge` - stake-age accumulated across the user's actions within the interval they haven't yet been settled through
- `stake`, `reward`

Owed reward is then a subtraction of two prefix-sum snapshots covering the block range `(block[user.lastDistributionId], block[latestDistributionId]]`, plus a partial term for `(user.lastUpdateBlock, block[user.lastDistributionId]]` - the interval between the user's last action and the next distribution that closed after it. That partial is just the user's stake-age over the range multiplied by `rewardPerStakeAge` at `user.lastDistributionId`, which every distribution stores. Each of the three terms is O(1) to compute, so any user's owed reward is O(1) at any moment. 

On every user action (stake or withdraw), the owed reward is collapsed into the stored `reward`, and `stake` / `stakeAge` / `lastDistributionId` / `lastUpdateBlock` are re-anchored to the current state, turning a sequence of stakes and withdrawals into a chain of O(1) settlements, accumulating `stakeAge` within an inter-distribution window and resetting it across window boundaries. Re-anchoring thus preserves the invariant that the stake was constant across the range being summed. No loop over users, no loop over distributions.

## Assumptions and limits

- **Block numbers stored as `uint64`.** Rewards stop accruing beyond `block.number > 2⁶⁴ − 1` (≈1.8 × 10¹⁹). No mainnet or L2 comes near this. Stated so integrators of exotic execution environments know the horizon.
- **Stakes stored as `uint128`.** Both individual stakes and the pool total. `_stake` reverts with `TotalStakeOverflow` if the pool total would wrap. `_preStake` implementations must reject any input that would overflow when converted to internal units.
- **Distribution count stored as `uint64`.** Up to `2⁶⁴ − 1` distributions before `DistributionIdOverflow` reverts and further distributions become impossible. Unreachable in practice.
- **Consumer owns asset movement.** The contract is abstract and tracks accounting only. The inheriting contract is responsible for pulling / pushing the underlying tokens in the `_postStake` / `_postWithdraw` / `_postDistribute` hooks. Token semantics (allowance, fee-on-transfer, rebasing, non-standard `bool` returns) are the consumer's responsibility.
- **Withdraw draws from reward first, then principal.** A user's realized reward acts as an implicit balance that can be withdrawn without touching stake. This is a design choice - noted so consumers understand the semantics of `_withdraw`.
- **Integer rounding leaves dust.** Reward accounting uses fixed-point arithmetic with `DENOMINATOR = 2⁶⁴ − 1`. Each distribution computes `rewardPerStakeAge = (rewardStake × DENOMINATOR) / distributionStakeAge`, and each per-user reward computes `stakeAge × rewardPerStakeAge / DENOMINATOR`. Two truncations per user per distribution mean the sum of all users' payouts is bounded above by the distributed amount but may be strictly less. Undistributed dust remains in the contract balance (never lost, never over-paid) and is silently absorbed into the next distribution's `distributionStakeAge` denominator. For distributions much larger than the participant count this is negligible; for pathological cases (tiny reward split across many stakers), some wei may sit un-withdrawable until a later distribution.

## Dependencies

Runtime (Solidity):

- [`@openzeppelin/contracts`](https://github.com/OpenZeppelin/openzeppelin-contracts) - uses `utils/math/Math.sol` (`mulDiv` for overflow-safe fixed-point arithmetic) and `utils/math/SafeCast.sol` (checked narrowing to `uint64`).

Development / testing:

- [`forge-std`](https://github.com/foundry-rs/forge-std) - Foundry standard library (`Test`, `console`, cheatcodes).
- [`foundry`](https://github.com/foundry-rs/foundry) - build, test, coverage, formatter. Install via [`foundryup`](https://book.getfoundry.sh/getting-started/installation).

Foundry pulls Solidity dependencies as git submodules under `lib/`.

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

Extend the abstract contract and implement six hooks. The example below wraps a single ERC-20 as both stake and reward token, and demonstrates the `recipient` / `user` distinction - the caller can stake *on behalf of* another account and withdraw *to* an arbitrary address.

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
    // Identity casts here - the pool uses raw token amounts as stake units.
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

- `_preStake` / `_preWithdraw` / `_preDistribute` - pure/view conversion of raw caller input into internal `uint128` stake units.
- `_postStake` / `_postWithdraw` / `_postDistribute` - side-effectful hooks that move the underlying assets after accounting has been updated.

## Development

This repo uses Foundry for development and testing and git submodules for dependency management.
Clone the repo and run `forge test` to run tests. Forge will automatically install any missing dependencies.

```bash
git clone https://github.com/Juglipaff/fair-reward-distributor.git
cd fair-reward-distributor
forge test
```
