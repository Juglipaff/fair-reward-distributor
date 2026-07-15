// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { FairRewardDistributor } from "../../src/FairRewardDistributor.sol";

/**
 * @title FairRewardDistributorHarness
 * @dev Test-only concrete implementation of the abstract FairRewardDistributor. Uses 1:1
 *      conversion between raw liquidity and internal stake units so tests can exercise
 *      the pure accounting layer without token transfer semantics interfering.
 */
contract FairRewardDistributorHarness is FairRewardDistributor {
    // ============ External Write Functions ============

    /**
     * @dev Exposes `_stake` to tests.
     * @param liquidity Raw stake amount.
     * @param recipient Account credited with the stake.
     */
    function stake(uint128 liquidity, address recipient) external {
        _stake(liquidity, recipient);
    }

    /**
     * @dev Exposes `_withdraw` to tests.
     * @param liquidity Raw withdrawal amount.
     * @param user Account whose position is reduced.
     */
    function withdraw(uint128 liquidity, address user) external {
        _withdraw(liquidity, user);
    }

    /**
     * @dev Exposes `_collectReward` to tests.
     * @param reward Raw withdrawal amount.
     * @param user Account whose position is reduced.
     */
    function collectReward(uint192 reward, address user) external {
        _collectReward(reward, user);
    }

    /**
     * @dev Exposes `_distribute` to tests.
     * @param reward Raw reward amount.
     */
    function distribute(uint128 reward) external {
        _distribute(reward);
    }

    // ============ External View Functions ============

    /**
     * @dev Exposes `_totalStake` to tests.
     * @return Current total staked amount.
     */
    function totalStake() external view returns (uint256) {
        return _totalStake();
    }

    /**
     * @dev Exposes `_userStake` to tests.
     * @param user Account to inspect.
     * @return Current stake of `user`.
     */
    function userStake(address user) external view returns (uint256) {
        return _userStake(user);
    }

    /**
     * @dev Exposes `_userReward` to tests.
     * @param user Account to inspect.
     * @return Total reward owed to `user` but not yet withdrawn.
     */
    function userReward(address user) external view returns (uint256) {
        return _userReward(user);
    }
}
