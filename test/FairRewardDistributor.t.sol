// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { FairRewardDistributor } from "../src/FairRewardDistributor.sol";
import { FairRewardDistributorHarness } from "./mocks/FairRewardDistributorHarness.sol";

/**
 * @title FairRewardDistributorTest
 * @dev Unit tests for the FairRewardDistributor accounting layer via a 1:1 harness.
 */
contract FairRewardDistributorTest is Test {
    // ============ Storage ============

    ///@dev Contract under test.
    FairRewardDistributorHarness internal harness;

    ///@dev Test user Alice.
    address internal alice = address(0xA11CE);
    ///@dev Test user Bob.
    address internal bob = address(0xB0B);
    ///@dev Test user Carol.
    address internal carol = address(0xCAB01);

    ///@dev Genesis block used for deployment. Chosen to leave headroom for `vm.roll` deltas without
    ///     touching the block 0 edge case.
    uint256 internal constant GENESIS_BLOCK = 1_000_000;

    ///@dev Fixed-point scale factor mirroring the src DENOMINATOR constant.
    uint256 internal constant DENOMINATOR = type(uint64).max;

    // ============ Internal Pure Functions ============

    /**
     * @dev Strict upper bound on rounding loss for a single user over a single distribution.
     *      Derivation: `R_pSA = floor(reward * D / total_stakeAge)` loses a fractional `f ∈ [0,1)`.
     *      Per-user `mulDiv(stakeAge_u, R_pSA, D)` loses another `< 1` wei. Composed:
     *      `loss < stakeAge_u * f / D + 1 < stakeAge_u / D + 1`.
     * @param stake User's stake for the interval.
     * @param blocks Number of blocks the user held that stake before the distribution.
     * @return Upper bound in wei.
     */
    function _lossBound(uint256 stake, uint256 blocks) internal pure returns (uint256) {
        return (stake * blocks) / DENOMINATOR + 1;
    }

    // ============ Setup ============

    /**
     * @dev Deploys the harness at a fixed genesis block so per-test block deltas are deterministic.
     */
    function setUp() public {
        vm.roll(GENESIS_BLOCK);
        harness = new FairRewardDistributorHarness();
    }

    // ============ Constructor ============

    function test_Constructor_TotalStakeIsZero() public view {
        assertEq(harness.totalStake(), 0);
    }

    function test_Constructor_UserStakesAreZero() public view {
        assertEq(harness.userStake(alice), 0);
        assertEq(harness.userStake(bob), 0);
    }

    function test_Constructor_UserRewardsAreZero() public view {
        assertEq(harness.userReward(alice), 0);
        assertEq(harness.userReward(bob), 0);
    }

    // ============ Stake — happy paths ============

    function test_Stake_SingleUser_UpdatesUserStake() public {
        uint256 credited = harness.stake(100 ether, alice);

        assertEq(credited, 100 ether);
        assertEq(harness.userStake(alice), 100 ether);
    }

    function test_Stake_SingleUser_UpdatesTotalStake() public {
        harness.stake(100 ether, alice);

        assertEq(harness.totalStake(), 100 ether);
    }

    function test_Stake_MultipleUsers_TotalStakeMatchesSum() public {
        harness.stake(100 ether, alice);
        harness.stake(200 ether, bob);
        harness.stake(50 ether, carol);

        assertEq(harness.totalStake(), 350 ether);
        assertEq(harness.userStake(alice), 100 ether);
        assertEq(harness.userStake(bob), 200 ether);
        assertEq(harness.userStake(carol), 50 ether);
    }

    function test_Stake_SameUserTwice_Accumulates() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);
        harness.stake(50 ether, alice);

        assertEq(harness.userStake(alice), 150 ether);
        assertEq(harness.totalStake(), 150 ether);
    }

    // ============ Stake — reverts ============

    function test_Stake_RevertWhen_LiquidityIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(FairRewardDistributor.InsufficientStake.selector, 0));
        harness.stake(0, alice);
    }

    // ============ Withdraw — happy paths ============

    function test_Withdraw_FromStake_ReducesUserStake() public {
        harness.stake(100 ether, alice);
        uint256 withdrawn = harness.withdraw(40 ether, alice, alice);

        assertEq(withdrawn, 40 ether);
        assertEq(harness.userStake(alice), 60 ether);
        assertEq(harness.totalStake(), 60 ether);
    }

    function test_Withdraw_FullStake_ZeroesUser() public {
        harness.stake(100 ether, alice);
        harness.withdraw(100 ether, alice, alice);

        assertEq(harness.userStake(alice), 0);
        assertEq(harness.totalStake(), 0);
    }

    function test_Withdraw_ByThirdParty_ReducesUserNotRecipient() public {
        harness.stake(100 ether, alice);
        harness.withdraw(40 ether, alice, bob);

        assertEq(harness.userStake(alice), 60 ether);
        assertEq(harness.userStake(bob), 0);
    }

    // ============ Withdraw — reverts ============

    function test_Withdraw_RevertWhen_LiquidityIsZero() public {
        harness.stake(100 ether, alice);
        vm.expectRevert(abi.encodeWithSelector(FairRewardDistributor.InsufficientStake.selector, 0));
        harness.withdraw(0, alice, alice);
    }

    function test_Withdraw_RevertWhen_ExceedsBalance() public {
        harness.stake(100 ether, alice);
        vm.expectRevert(
            abi.encodeWithSelector(FairRewardDistributor.InsufficientBalance.selector, 101 ether, 100 ether)
        );
        harness.withdraw(101 ether, alice, alice);
    }

    // ============ Distribute — happy paths ============

    function test_Distribute_SingleUser_ReceivesFullReward() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(10 ether);

        uint256 reward = harness.userReward(alice);
        uint256 bound = _lossBound(100 ether, 10);

        assertLe(reward, 10 ether); // never over-pays
        assertGe(reward, 10 ether - bound); // within closed-form rounding budget
    }

    function test_Distribute_TwoUsersEqualStakeEqualTime_HalfEach() public {
        harness.stake(100 ether, alice);
        harness.stake(100 ether, bob);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(10 ether);

        uint256 aliceReward = harness.userReward(alice);
        uint256 bobReward = harness.userReward(bob);
        uint256 bound = _lossBound(100 ether, 10);

        assertLe(aliceReward, 5 ether);
        assertGe(aliceReward, 5 ether - bound);
        assertLe(bobReward, 5 ether);
        assertGe(bobReward, 5 ether - bound);
    }

    function test_Distribute_TwoUsersEqualStakeDifferentTime_EarlierGetsMore() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 100);
        harness.stake(100 ether, bob);
        vm.roll(GENESIS_BLOCK + 200);
        harness.distribute(10 ether);

        // Alice stakeAge = 100e * 200 blocks; Bob stakeAge = 100e * 100 blocks; total = 100e * 300.
        // Exact expected: Alice = 10e * 200 / 300 = 20/3 ether; Bob = 10e * 100 / 300 = 10/3 ether.

        uint256 aliceReward = harness.userReward(alice);
        uint256 aliceExpected = (uint256(10 ether) * 200) / 300;
        uint256 aliceBound = _lossBound(100 ether, 200);

        uint256 bobExpected = (uint256(10 ether) * 100) / 300;
        uint256 bobBound = _lossBound(100 ether, 100);
        uint256 bobReward = harness.userReward(bob);

        assertLe(aliceReward, aliceExpected);
        assertGe(aliceReward, aliceExpected - aliceBound);
        assertLe(bobReward, bobExpected);
        assertGe(bobReward, bobExpected - bobBound);
    }

    function test_Distribute_TwoUsersDifferentStakeSameTime_ProportionalToStake() public {
        harness.stake(100 ether, alice);
        harness.stake(300 ether, bob);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(4 ether);

        uint256 aliceReward = harness.userReward(alice);
        uint256 aliceBound = _lossBound(100 ether, 10);

        uint256 bobReward = harness.userReward(bob);
        uint256 bobBound = _lossBound(300 ether, 10);

        // total stakeAge = 400e * 10; Alice share = 100/400; Bob share = 300/400.
        assertLe(aliceReward, 1 ether);
        assertGe(aliceReward, 1 ether - aliceBound);
        assertLe(bobReward, 3 ether);
        assertGe(bobReward, 3 ether - bobBound);
    }

    function test_Distribute_MultipleDistributions_UserInactive_AccumulatesAll() public {
        harness.stake(100 ether, alice);

        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(5 ether);

        vm.roll(GENESIS_BLOCK + 20);
        harness.distribute(7 ether);

        vm.roll(GENESIS_BLOCK + 30);
        harness.distribute(3 ether);

        // Alice is the sole staker across all three intervals of 10 blocks each. Per-distribution
        // loss bound compounds linearly.
        uint256 reward = harness.userReward(alice);
        uint256 totalBound = _lossBound(100 ether, 10) * 3;

        assertLe(reward, 15 ether);
        assertGe(reward, 15 ether - totalBound);
    }

    // ============ Distribute — reverts ============

    function test_Distribute_RevertWhen_RewardIsZero() public {
        harness.stake(100 ether, alice);
        vm.expectRevert(abi.encodeWithSelector(FairRewardDistributor.InsufficientStake.selector, 0));
        harness.distribute(0);
    }

    function test_Distribute_RevertWhen_NoStakeExists() public {
        vm.expectRevert(FairRewardDistributor.DistributionNotAvailable.selector);
        harness.distribute(10 ether);
    }

    // ============ Reward view ============

    function test_UserReward_BeforeAnyDistribution_IsZero() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);

        assertEq(harness.userReward(alice), 0);
    }

    function test_UserReward_ForNonParticipant_IsZero() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(10 ether);

        assertEq(harness.userReward(bob), 0);
    }

    function test_UserReward_ReturnsCachedValue_WhenUserActedAfterLatestDistribution() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        // Alice acts (deposits again) — this internally realizes her reward and updates her
        // `lastDistributionId` to the current distribution id.
        harness.stake(1 ether, alice);

        // Subsequent read hits the cached-early-return branch.
        vm.roll(GENESIS_BLOCK + 30);

        uint256 reward = harness.userReward(alice);
        uint256 lossBound = _lossBound(100 ether, 10);

        assertLe(reward, 10 ether);
        assertGt(reward, 10 ether - lossBound);
    }

    // ============ Withdraw from realized reward ============

    function test_Withdraw_FromReward_LeavesStakeUnchanged() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(10 ether);

        // Force reward to become "realized" on Alice's UserInfo by triggering an update.
        // A stake of 0 would revert; instead do a second distribution then a withdrawal from
        // the accumulated realized reward.
        vm.roll(GENESIS_BLOCK + 20);
        harness.distribute(5 ether);

        // Trigger reward realization by staking a tiny amount to update her state.
        vm.roll(GENESIS_BLOCK + 21);
        harness.stake(1 wei, alice);

        uint256 stakeBefore = harness.userStake(alice);
        uint256 rewardBefore = harness.userReward(alice);
        uint256 lossBound = _lossBound(100 ether, 30);

        assertLt(rewardBefore, 15 ether);
        assertGt(rewardBefore, 15 ether - lossBound);

        harness.withdraw(1 ether, alice, alice);

        assertEq(harness.userStake(alice), stakeBefore);
        assertEq(harness.userReward(alice), rewardBefore - 1 ether);
    }

    //TODO
    function test_Withdraw_MixedRewardAndStake_DrainsRewardFirst() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(5 ether);

        vm.roll(GENESIS_BLOCK + 11);
        harness.stake(1 wei, alice); // realize the ~5 ether reward

        uint256 stakeBefore = harness.userStake(alice);
        uint256 rewardBefore = harness.userReward(alice);
        assertGt(rewardBefore, 1 ether);

        // Withdraw slightly more than the realized reward — should drain reward to zero and
        // reduce stake by the remainder.
        uint256 withdrawAmount = rewardBefore + 1 ether;
        harness.withdraw(withdrawAmount, alice, alice);

        assertEq(harness.userReward(alice), 0);
        assertEq(harness.userStake(alice), stakeBefore - 1 ether);
    }

    // ============ Overflow reverts ============

    function test_Stake_RevertWhen_TotalStakeOverflow() public {
        harness.stake(type(uint128).max - 100, alice);
        vm.expectRevert(FairRewardDistributor.TotalStakeOverflow.selector);
        harness.stake(101, bob);
    }

    function test_Distribute_RevertWhen_DistributionIdOverflow() public {
        // First establish some stake so we don't hit DistributionNotAvailable.
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 1);

        // Slot 1: [_totalStakeAge (uint192, offset 0)] + [_distributionId (uint64, offset 24)]
        // Force _distributionId to type(uint64).max while preserving _totalStakeAge.
        bytes32 slot1 = vm.load(address(harness), bytes32(uint256(1)));
        uint256 slot1Value = uint256(slot1);
        // Clear high 8 bytes (offset 24..31) and set to uint64 max.
        uint256 mask = ~(uint256(type(uint64).max) << 192);
        slot1Value = (slot1Value & mask) | (uint256(type(uint64).max) << 192);
        vm.store(address(harness), bytes32(uint256(1)), bytes32(slot1Value));

        vm.expectRevert(FairRewardDistributor.DistributionIdOverflow.selector);
        harness.distribute(1 ether);
    }
}
