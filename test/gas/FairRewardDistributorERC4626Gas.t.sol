// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { FairRewardDistributorERC4626 } from "../../src/FairRewardDistributorERC4626.sol";

/**
 * @title MockAsset
 * @dev Minimal ERC20 with public mint used as the ERC4626 underlying asset.
 */
contract MockAsset is ERC20 {
    /**
     * @dev Deploys the mock with fixed name and symbol.
     */
    constructor() ERC20("Mock", "MCK") { }

    /**
     * @dev Mints `amount` tokens to `to`.
     * @param to Recipient of the minted tokens.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title FairRewardDistributorERC4626GasTest
 * @dev Gas benchmarks for hot-path operations of the ERC4626 wrapper. Each test isolates a single
 *      SUT call inside `vm.startSnapshotGas` / `vm.stopSnapshotGas` fences so the recorded number
 *      covers ONLY the target operation. Storage slots and token allowances are warmed up during
 *      setup so cold-slot overhead does not contaminate the measurement, except in the "first"
 *      benchmarks where the cold write is the point of the measurement.
 */
contract FairRewardDistributorERC4626GasTest is Test {
    // ============ Storage ============

    ///@dev Contract under test.
    FairRewardDistributorERC4626 internal vault;
    ///@dev Underlying asset.
    MockAsset internal asset;

    ///@dev Test user Alice.
    address internal alice = address(0xA11CE);
    ///@dev Test user Bob.
    address internal bob = address(0xB0B);
    ///@dev Test user Carol.
    address internal carol = address(0xCAB01);

    ///@dev Genesis block used for deployment. Chosen to leave headroom for `vm.roll` deltas without
    ///     touching the block 0 edge case.
    uint256 internal constant GENESIS_BLOCK = 1_000_000;

    ///@dev Standard stake unit used across benchmarks.
    uint128 internal constant STAKE = 1_000e18;

    ///@dev Standard reward unit used across benchmarks.
    uint128 internal constant REWARD = 100e18;

    // ============ Setup ============

    /**
     * @dev Deploys the mock asset and the vault at a fixed genesis block for determinism.
     */
    function setUp() public {
        vm.roll(GENESIS_BLOCK);
        asset = new MockAsset();
        vault = new FairRewardDistributorERC4626("Vault Share", "vMCK", IERC20(address(asset)));
    }

    // ============ Helpers ============

    /**
     * @dev Mints `amount` of the underlying asset to `user` and grants the vault unlimited allowance.
     * @param user Account to fund.
     * @param amount Asset amount to mint.
     */
    function _fund(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }

    // ============ External Write Functions ============

    /**
     * @dev `deposit` from a fresh user with no prior vault state. Cold storage writes.
     */
    function test_Gas_Deposit_First() public {
        _fund(alice, STAKE);

        vm.prank(alice);
        vm.startSnapshotGas("deposit_first");
        vault.deposit(STAKE, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `deposit` on top of an existing position. Warm user slots, no distribution settlement.
     */
    function test_Gas_Deposit_AddToExistingPosition() public {
        _fund(alice, STAKE * 2);
        vm.prank(alice);
        vault.deposit(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);

        vm.prank(alice);
        vm.startSnapshotGas("deposit_add_to_existing");
        vault.deposit(STAKE, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `mint` from a fresh user with no prior vault state. Cold storage writes.
     */
    function test_Gas_Mint_First() public {
        _fund(alice, STAKE);

        vm.prank(alice);
        vm.startSnapshotGas("mint_first");
        vault.mint(STAKE, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `withdraw` from principal only, no reward realization.
     */
    function test_Gas_Withdraw_FromStakeOnly() public {
        _fund(alice, STAKE);
        vm.prank(alice);
        vault.deposit(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);

        vm.prank(alice);
        vm.startSnapshotGas("withdraw_from_stake");
        vault.withdraw(STAKE / 2, alice, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `withdraw` after a distribution, forcing reward settlement through the prefix-sum path.
     */
    function test_Gas_Withdraw_AfterDistribution_SettlesReward() public {
        _fund(alice, STAKE);
        vm.prank(alice);
        vault.deposit(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);
        _fund(bob, REWARD);
        vm.prank(bob);
        vault.distribute(REWARD);
        vm.roll(GENESIS_BLOCK + 200);

        vm.prank(alice);
        vm.startSnapshotGas("withdraw_after_distribution");
        vault.withdraw(STAKE / 2, alice, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `redeem` after a distribution, forcing reward settlement through the prefix-sum path.
     */
    function test_Gas_Redeem_AfterDistribution_SettlesReward() public {
        _fund(alice, STAKE);
        vm.prank(alice);
        vault.deposit(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);
        _fund(bob, REWARD);
        vm.prank(bob);
        vault.distribute(REWARD);
        vm.roll(GENESIS_BLOCK + 200);

        vm.prank(alice);
        vm.startSnapshotGas("redeem_after_distribution");
        vault.redeem(STAKE / 2, alice, alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `distribute` with a single staker, warm storage.
     */
    function test_Gas_Distribute_SingleStaker() public {
        _fund(alice, STAKE);
        vm.prank(alice);
        vault.deposit(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);
        _fund(carol, REWARD);

        vm.prank(carol);
        vm.startSnapshotGas("distribute_single_staker");
        vault.distribute(REWARD);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `distribute` with two stakers. Compared to the single-staker case, verifies the O(1)
     *      property (no per-participant scaling).
     */
    function test_Gas_Distribute_TwoStakers() public {
        _fund(alice, STAKE);
        vm.prank(alice);
        vault.deposit(STAKE, alice);
        _fund(bob, STAKE);
        vm.prank(bob);
        vault.deposit(STAKE, bob);
        vm.roll(GENESIS_BLOCK + 100);
        _fund(carol, REWARD);

        vm.prank(carol);
        vm.startSnapshotGas("distribute_two_stakers");
        vault.distribute(REWARD);
        vm.stopSnapshotGas();
    }

    // ============ External View Functions ============

    /**
     * @dev `maxWithdraw` with reward outstanding. Exercises the `previewRedeemFor` mulDiv path.
     */
    function test_Gas_MaxWithdraw_WithReward() public {
        _fund(alice, STAKE);
        vm.prank(alice);
        vault.deposit(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);
        _fund(bob, REWARD);
        vm.prank(bob);
        vault.distribute(REWARD);
        vm.roll(GENESIS_BLOCK + 200);

        vm.startSnapshotGas("maxWithdraw_with_reward");
        vault.maxWithdraw(alice);
        vm.stopSnapshotGas();
    }

    /**
     * @dev `previewRedeem` with reward outstanding.
     */
    function test_Gas_PreviewRedeem_WithReward() public {
        _fund(alice, STAKE);
        vm.prank(alice);
        vault.deposit(STAKE, alice);
        vm.roll(GENESIS_BLOCK + 100);
        _fund(bob, REWARD);
        vm.prank(bob);
        vault.distribute(REWARD);
        vm.roll(GENESIS_BLOCK + 200);

        vm.prank(alice);
        vm.startSnapshotGas("previewRedeem_with_reward");
        vault.previewRedeem(STAKE);
        vm.stopSnapshotGas();
    }
}
