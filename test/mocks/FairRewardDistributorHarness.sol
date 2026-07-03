// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { FairRewardDistributor } from "../../src/FairRewardDistributor.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title FairRewardDistributorHarness
 * @dev Test-only concrete implementation of the abstract FairRewardDistributor. Uses 1:1
 *      conversion between raw liquidity and internal stake units and no-op post hooks so tests
 *      can exercise the pure accounting layer without token transfer semantics interfering.
 */
contract FairRewardDistributorHarness is FairRewardDistributor {
    using SafeCast for uint256;

    // ============ External Write Functions ============

    /**
     * @dev Exposes `_stake` to tests.
     * @param liquidity Raw stake amount.
     * @param recipient Account credited with the stake.
     * @return Internal stake units credited.
     */
    function stake(uint256 liquidity, address recipient) external returns (uint256) {
        return _stake(liquidity, recipient);
    }

    /**
     * @dev Exposes `_withdraw` to tests.
     * @param liquidity Raw withdrawal amount.
     * @param user Account whose position is reduced.
     * @param recipient Address that would receive the underlying (unused since post hooks are no-ops).
     * @return Internal stake units withdrawn.
     */
    function withdraw(uint256 liquidity, address user, address recipient) external returns (uint256) {
        return _withdraw(liquidity, user, recipient);
    }

    /**
     * @dev Exposes `_distribute` to tests.
     * @param reward Raw reward amount.
     * @return The original `reward` echoed back.
     */
    function distribute(uint256 reward) external returns (uint256) {
        return _distribute(reward);
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

    // ============ Internal View Functions ============

    /**
     * @inheritdoc FairRewardDistributor
     */
    function _preStake(uint256 liquidity) internal pure override returns (uint128) {
        return liquidity.toUint128();
    }

    /**
     * @inheritdoc FairRewardDistributor
     */
    function _preWithdraw(uint256 liquidity) internal pure override returns (uint128) {
        return liquidity.toUint128();
    }

    /**
     * @inheritdoc FairRewardDistributor
     */
    function _preDistribute(uint256 reward) internal pure override returns (uint128) {
        return reward.toUint128();
    }

    // ============ Internal Write Functions ============

    /**
     * @inheritdoc FairRewardDistributor
     */
    function _postStake(uint128, address) internal pure override {}

    /**
     * @inheritdoc FairRewardDistributor
     */
    function _postWithdraw(uint128, address, address) internal pure override {}

    /**
     * @inheritdoc FairRewardDistributor
     */
    function _postDistribute(uint128) internal pure override {}
}
