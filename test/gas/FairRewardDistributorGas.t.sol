// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { FairRewardDistributorHarness } from "../mocks/FairRewardDistributorHarness.sol";

/**
 * @title FairRewardDistributorGasTest
 * @dev Gas benchmarks for hot-path operations. Each test isolates a single SUT call inside
 *      `vm.startSnapshotGas` / `vm.stopSnapshotGas` fences so the recorded number covers ONLY
 *      the target operation, not the warm-up setup that precedes it. Results are persisted to
 *      the `snapshots/` directory (one file per group) and committed to the repo. CI diffs the
 *      directory to detect regressions.
 */
contract FairRewardDistributorGasTest is Test {
    // ============ Storage ============

    ///@dev Contract under test.
    FairRewardDistributorHarness internal harness;

    ///@dev Test user Alice.
    address internal alice = address(0xA11CE);
    ///@dev Test user Bob.
    address internal bob = address(0xB0B);

    ///@dev Genesis block used for deployment. Chosen to leave headroom for `vm.roll` deltas without
    ///     touching the block 0 edge case.
    uint256 internal constant GENESIS_BLOCK = 1_000_000;

    ///@dev Standard stake unit used across benchmarks.
    uint128 internal constant STAKE = 1_000e18;

    ///@dev Standard reward unit used across benchmarks.
    uint128 internal constant REWARD = 100e18;

    // ============ Setup ============

    /**
     * @dev Deploys the harness at a fixed genesis block for determinism.
     */
    function setUp() public {
        vm.roll(GENESIS_BLOCK);
        harness = new FairRewardDistributorHarness();
    }

    // ============ External Write Functions ============

    /**
     * @dev `stake` from a fresh user with no prior state. Cold storage writes.
     */
    function test_Gas_Stake_FirstStake() public {
        vm.startSnapshotGas("stake_first");
        harness.stake(STAKE, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `stake` on top of an existing position. Warm user slots, no distribution settlement.
     */
    function test_Gas_Stake_AddToExistingPosition() public {
        harness.stake(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);

        vm.startSnapshotGas("stake_add_to_existing");
        harness.stake(STAKE, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `withdraw` from principal only, no reward realization.
     */
    function test_Gas_Withdraw_FromStakeOnly() public {
        harness.stake(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);

        uint192 liquidity = STAKE / 2;
        vm.startSnapshotGas("withdraw_from_stake");
        harness.withdraw(liquidity, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `withdraw` after a distribution, forcing reward settlement through the prefix-sum path.
     */
    function test_Gas_Withdraw_AfterDistribution_SettlesReward() public {
        harness.stake(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);
        harness.distribute(REWARD);
        vm.roll(GENESIS_BLOCK + 200);

        uint192 liquidity = STAKE / 2;
        vm.startSnapshotGas("withdraw_after_distribution");
        harness.withdraw(liquidity, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `distribute` with a single staker, warm storage.
     */
    function test_Gas_Distribute_SingleStaker() public {
        harness.stake(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);

        vm.startSnapshotGas("distribute_single_staker");
        harness.distribute(REWARD);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `distribute` with two stakers. Compared to the single-staker case, verifies the O(1)
     *      property (no per-participant scaling).
     */
    function test_Gas_Distribute_TwoStakers() public {
        harness.stake(STAKE, alice);
        harness.stake(STAKE, bob);
        vm.roll(GENESIS_BLOCK + 100);

        vm.startSnapshotGas("distribute_two_stakers");
        harness.distribute(REWARD);
        vm.stopSnapshotGas();
    }

    // ============ External View Functions ============

    /**
     * @dev `userReward` on the cached-path early return (user settled through the latest
     *      distribution).
     */
    function test_Gas_UserReward_Cached() public {
        harness.stake(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);
        harness.distribute(REWARD);
        harness.stake(1, alice); // Bumps lastDistributionId to current.

        vm.startSnapshotGas("userReward_cached");
        harness.userReward(alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `userReward` on the full prefix-sum path (user behind the latest distribution).
     */
    function test_Gas_UserReward_UnsettledSincePriorDistribution() public {
        harness.stake(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);
        harness.distribute(REWARD);
        vm.roll(GENESIS_BLOCK + 200);

        vm.startSnapshotGas("userReward_unsettled");
        harness.userReward(alice);
        vm.stopSnapshotGas();
    }
}
