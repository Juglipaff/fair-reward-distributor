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

    ///@dev Relative-error tolerance for reward assertions, in wad (1e18 = 100%). 1e2 = 0.00000000000001%.
    uint256 internal constant REWARD_TOLERANCE = 1e2;

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
        assertLe(reward, 10 ether);
        assertApproxEqRel(reward, 10 ether, REWARD_TOLERANCE);
    }

    function test_Distribute_TwoUsersEqualStakeEqualTime_HalfEach() public {
        harness.stake(100 ether, alice);
        harness.stake(100 ether, bob);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(10 ether);

        uint256 aliceReward = harness.userReward(alice);
        uint256 bobReward = harness.userReward(bob);

        assertLe(aliceReward, 5 ether);
        assertApproxEqRel(aliceReward, 5 ether, REWARD_TOLERANCE);
        assertLe(bobReward, 5 ether);
        assertApproxEqRel(bobReward, 5 ether, REWARD_TOLERANCE);
    }

    function test_Distribute_TwoUsersEqualStakeDifferentTime_EarlierGetsMore() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 100);
        harness.stake(100 ether, bob);
        vm.roll(GENESIS_BLOCK + 200);
        harness.distribute(10 ether);

        uint256 aliceReward = harness.userReward(alice);
        uint256 aliceExpected = (uint256(10 ether) * 200) / 300;

        uint256 bobExpected = (uint256(10 ether) * 100) / 300;
        uint256 bobReward = harness.userReward(bob);

        assertLe(aliceReward, aliceExpected);
        assertApproxEqRel(aliceReward, aliceExpected, REWARD_TOLERANCE);
        assertLe(bobReward, bobExpected);
        assertApproxEqRel(bobReward, bobExpected, REWARD_TOLERANCE);
    }

    function test_Distribute_TwoUsersDifferentStakeSameTime_ProportionalToStake() public {
        harness.stake(100 ether, alice);
        harness.stake(300 ether, bob);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(4 ether);

        uint256 aliceReward = harness.userReward(alice);
        uint256 bobReward = harness.userReward(bob);

        assertLe(aliceReward, 1 ether);
        assertApproxEqRel(aliceReward, 1 ether, REWARD_TOLERANCE);
        assertLe(bobReward, 3 ether);
        assertApproxEqRel(bobReward, 3 ether, REWARD_TOLERANCE);
    }

    function test_Distribute_MultipleDistributions_UserInactive_AccumulatesAll() public {
        harness.stake(100 ether, alice);

        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(5 ether);

        vm.roll(GENESIS_BLOCK + 20);
        harness.distribute(7 ether);

        vm.roll(GENESIS_BLOCK + 30);
        harness.distribute(3 ether);

        uint256 reward = harness.userReward(alice);
        assertLe(reward, 15 ether);
        assertApproxEqRel(reward, 15 ether, REWARD_TOLERANCE);
    }

    function test_Distribute_StakeAgeAccumulatesAcrossCycles_ProportionalShare() public {
        uint128 X = 100 ether;
        uint64 t = 10;

        harness.stake(X, alice);
        vm.roll(GENESIS_BLOCK + t);
        harness.withdraw(X, alice, alice);

        harness.stake(X, alice);
        vm.roll(GENESIS_BLOCK + 2 * t);
        harness.withdraw(X, alice, alice);

        harness.stake(X, alice);
        vm.roll(GENESIS_BLOCK + 3 * t);
        harness.withdraw(X, alice, alice);

        harness.stake(X, bob);
        vm.roll(GENESIS_BLOCK + 4 * t);
        harness.withdraw(X, bob, bob);

        harness.distribute(4 ether);

        uint256 aliceReward = harness.userReward(alice);
        uint256 bobReward = harness.userReward(bob);

        assertLe(aliceReward, 3 ether);
        assertApproxEqRel(aliceReward, 3 ether, REWARD_TOLERANCE);
        assertLe(bobReward, 1 ether);
        assertApproxEqRel(bobReward, 1 ether, REWARD_TOLERANCE);
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
        harness.stake(1 ether, alice);
        vm.roll(GENESIS_BLOCK + 30);

        uint256 reward = harness.userReward(alice);
        assertLe(reward, 10 ether);
        assertApproxEqRel(reward, 10 ether, REWARD_TOLERANCE);
    }

    // ============ Withdraw from realized reward ============

    function test_Withdraw_FromReward_LeavesStakeUnchanged() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(10 ether);
        vm.roll(GENESIS_BLOCK + 20);
        harness.distribute(5 ether);
        vm.roll(GENESIS_BLOCK + 21);
        harness.stake(1 wei, alice);

        uint256 stakeBefore = harness.userStake(alice);
        uint256 rewardBefore = harness.userReward(alice);

        assertLe(rewardBefore, 15 ether);
        assertApproxEqRel(rewardBefore, 15 ether, REWARD_TOLERANCE);

        harness.withdraw(1 ether, alice, alice);

        assertEq(harness.userStake(alice), stakeBefore);
        assertEq(harness.userReward(alice), rewardBefore - 1 ether);
    }

    function test_Withdraw_MixedRewardAndStake_DrainsRewardFirst() public {
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);
        harness.distribute(5 ether);
        vm.roll(GENESIS_BLOCK + 11);
        harness.stake(1 wei, alice);

        uint256 stakeBefore = harness.userStake(alice);
        uint256 rewardBefore = harness.userReward(alice);
        assertGt(rewardBefore, 1 ether);

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
        harness.stake(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 1);

        bytes32 slot1 = vm.load(address(harness), bytes32(uint256(1)));
        uint256 slot1Value = uint256(slot1);
        uint256 mask = ~(uint256(type(uint64).max) << 192);
        slot1Value = (slot1Value & mask) | (uint256(type(uint64).max) << 192);
        vm.store(address(harness), bytes32(uint256(1)), bytes32(slot1Value));

        vm.expectRevert(FairRewardDistributor.DistributionIdOverflow.selector);
        harness.distribute(1 ether);
    }
}
