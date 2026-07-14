// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title FairRewardDistributor
 * @author Ivan Menshchikov (https://github.com/Juglipaff).
 *      Algorithm co-authored with Roman Vinogradov. See https://juglipaff.github.io/Token-Distribution-Algorithm/
 * @dev Constant-gas, front-run-resistant on-chain reward distribution using deposit-age weighting.
 *      A user's reward is proportional to (stake × time-in-pool). Every operation is O(1)
 *      regardless of participant count or number of past distributions, achieved by storing a
 *      running prefix-sum accumulator on every distribution and remembering the user's last
 *      touched distribution index on every user action.
 *
 *      Assumptions:
 *      - Block numbers don't exceed 2**64 - 1. Rewards stop accruing beyond that horizon.
 *      - Individual and total stakes are bounded by 2**128 - 1.
 */
abstract contract FairRewardDistributor {
    using SafeCast for uint256;

    // ============ Types ============

    /**
     * @dev Snapshot recorded on every distribution.
     * @param block Block number at which this distribution was performed.
     * @param rewardPerStakeAge Reward tokens per unit of stake-age, scaled by DENOMINATOR.
     * @param cumRewardAgePerStakeAge Running prefix sum of (rewardPerStakeAge × interval length)
     *        across all distributions up to and including this one. Used to compute a user's
     *        reward for the range (userLastDistribution, currentDistribution] via subtraction.
     */
    struct DistributionInfo {
        uint64 block;
        uint192 rewardPerStakeAge;
        uint256 cumRewardAgePerStakeAge;
    }

    /**
     * @dev Per-user accounting state. Rewritten on every user action (stake / withdraw).
     * @param stake Current staked amount.
     * @param lastDistributionId Distribution index at which this user last acted; anchors the
     *        prefix-sum range for O(1) reward computation.
     * @param lastUpdateBlock Block number at which the user last acted.
     * @param stakeAge Accumulated (stake × block-delta) since lastUpdateBlock, up to the
     *        distribution after which the user has not yet been settled.
     * @param reward Already-realized reward owed to the user, not yet withdrawn.
     */
    struct UserInfo {
        uint128 stake;
        uint64 lastDistributionId;
        uint64 lastUpdateBlock;
        uint192 stakeAge;
        uint192 reward;
    }

    // ============ Storage ============

    ///@dev Sum of all users' current stakes.
    uint128 private __totalStake;
    ///@dev Block number at which pool-level state (__totalStake, _distributionStakeAge) was last updated.
    uint128 private _lastUpdateBlock;
    ///@dev Accumulated (__totalStake × block-delta) since the previous distribution. Consumed and reset to zero on each distribution.
    uint192 private _distributionStakeAge;
    ///@dev Next distribution index. Distributions are numbered 0..N; 0 is the bootstrap sentinel installed in the constructor.
    uint64 private _distributionId;

    ///@dev Per-user accounting state keyed by user address.
    mapping(address user => UserInfo) private _userInfo;
    ///@dev Per-distribution snapshot keyed by distribution id.
    mapping(uint64 distributionId => DistributionInfo) private _distributionInfo;

    ///@dev Fixed-point scale factor to preserve precision under integer math.
    uint256 private constant DENOMINATOR = type(uint64).max;

    // ============ Errors ============

    /**
     * @dev Thrown when zero liquidity is provided to stake / withdraw / distribute calls.
     * @param liquidity The rejected stake value.
     */
    error InsufficientLiquidity(uint256 liquidity);

    /**
     * @dev Thrown when a withdrawal exceeds the user's stake + realized reward balance.
     * @param requested Amount requested.
     * @param actual Amount available.
     */
    error InsufficientBalance(uint256 requested, uint256 actual);

    /**
     * @dev Thrown when distribution is called before any positive total stake-age has accrued,
     *      meaning no participants are eligible to receive a share of the reward.
     */
    error DistributionNotAvailable();

    /**
     * @dev Thrown when adding a new stake would overflow the uint128 __totalStake accumulator.
     */
    error TotalStakeOverflow();

    /**
     * @dev Thrown when the uint64 distribution counter would wrap around, which would brick
     *      further distributions.
     */
    error DistributionIdOverflow();

    // ============ Constructor ============

    /**
     * @dev Installs a bootstrap distribution at index 0 anchored to the deployment block. This
     *      guarantees `_distributionInfo[distributionId - 1]` is always addressable inside
     *      `_distribute` without a special case for the first real distribution.
     */
    constructor() {
        uint64 block64 = block.number.toUint64();
        _distributionInfo[0] = DistributionInfo({ block: block64, rewardPerStakeAge: 0, cumRewardAgePerStakeAge: 0 });
        _lastUpdateBlock = block64;
        _distributionId = 1;
    }

    // ============ Internal Write Functions ============

    /**
     * @dev Adds a user's stake to the pool. Settles their prior stake-age first so the new stake
     *      begins accruing cleanly from this block.
     * @param liquidity Liquidity amount to stake.
     * @param recipient User to credit with the stake.
     */
    function _stake(uint128 liquidity, address recipient) internal {
        if (liquidity == 0) revert InsufficientLiquidity(liquidity);

        _updateStake(recipient);

        unchecked {
            uint128 totalStake = __totalStake;
            if (totalStake + liquidity < __totalStake) revert TotalStakeOverflow();

            __totalStake = totalStake + liquidity;
            _userInfo[recipient].stake += liquidity;
        }
    }

    /**
     * @dev Withdraws liquidity for a user, drawing first from their realized reward balance and
     *      then from their principal stake.
     * @param liquidity Liquidity amount requested by the caller.
     * @param user Account whose position is being reduced.
     */
    function _withdraw(uint192 liquidity, address user) internal {
        if (liquidity == 0) revert InsufficientLiquidity(liquidity);

        _updateStake(user);

        UserInfo storage userInfo = _userInfo[user];
        uint192 reward = userInfo.reward;
        unchecked {
            if (liquidity > reward) {
                uint192 balance = userInfo.stake + reward;
                if (liquidity > balance) revert InsufficientBalance(liquidity, balance);

                userInfo.stake = uint128(balance - liquidity);
                __totalStake += uint128(reward - liquidity);

                userInfo.reward = 0;
            } else {
                userInfo.reward = reward - liquidity;
            }
        }
    }

    /**
     * @dev Records a new distribution: consumes the accumulated `_distributionStakeAge` from the previous
     *      distribution and stores the prefix-sum needed for O(1) per-user reward lookup.
     * @param liquidity Reward liquidity amount.
     */
    function _distribute(uint128 liquidity) internal {
        if (liquidity == 0) revert InsufficientLiquidity(liquidity);

        uint64 block64 = block.number.toUint64();
        uint64 distributionId = _distributionId;

        unchecked {
            uint64 newDistributionId = distributionId + 1;
            if (newDistributionId == 0) revert DistributionIdOverflow();
            _distributionId = newDistributionId;

            uint192 distributionStakeAge = _distributionStakeAge + uint192(__totalStake) * (block64 - _lastUpdateBlock);
            if (distributionStakeAge == 0) revert DistributionNotAvailable();

            DistributionInfo storage prevDistributionInfo = _distributionInfo[distributionId - 1];
            uint192 rewardPerStakeAge = (liquidity * uint192(DENOMINATOR)) / distributionStakeAge;
            uint256 cumRewardAgePerStakeAge = prevDistributionInfo.cumRewardAgePerStakeAge + uint256(rewardPerStakeAge)
                * (block64 - prevDistributionInfo.block);

            _distributionInfo[distributionId] = DistributionInfo({
                block: block64, rewardPerStakeAge: rewardPerStakeAge, cumRewardAgePerStakeAge: cumRewardAgePerStakeAge
            });
        }

        _lastUpdateBlock = block64;
        _distributionStakeAge = 0;
    }

    // ============ Internal View Functions ============

    /**
     * @dev Reads the current sum of all users' stakes.
     * @return Current total staked amount.
     */
    function _totalStake() internal view returns (uint128) {
        return __totalStake;
    }

    /**
     * @dev Reads a specific user's current stake.
     * @param user Account to inspect.
     * @return Current stake of `user`.
     */
    function _userStake(address user) internal view returns (uint128) {
        return _userInfo[user].stake;
    }

    /**
     * @dev Computes a specific user's total unclaimed reward, including rewards accrued through
     *      the most recent distribution. Combines the already-realized reward with the partial
     *      first-distribution term (`rewardBeforeDistribution`) and the prefix-sum range term
     *      (`rewardAfterDistribution`).
     * @param user Account to inspect.
     * @return Total reward owed to `user` but not yet withdrawn.
     */
    function _userReward(address user) internal view returns (uint192) {
        UserInfo storage userInfo = _userInfo[user];

        uint64 distributionId = _distributionId;
        uint64 userLastDistributionId = userInfo.lastDistributionId;
        if (userLastDistributionId == distributionId) return userInfo.reward;

        DistributionInfo memory lastUserDistributionInfo = _distributionInfo[userLastDistributionId];

        unchecked {
            uint256 userStake = userInfo.stake;
            uint256 userStakeAge =
                userInfo.stakeAge + userStake * (lastUserDistributionInfo.block - userInfo.lastUpdateBlock);

            uint256 rewardBeforeDistibution =
                Math.mulDiv(userStakeAge, lastUserDistributionInfo.rewardPerStakeAge, DENOMINATOR);
            uint256 rewardAfterDistribution = Math.mulDiv(
                userStake,
                _distributionInfo[distributionId - 1].cumRewardAgePerStakeAge
                    - lastUserDistributionInfo.cumRewardAgePerStakeAge,
                DENOMINATOR
            );

            return userInfo.reward + uint192(rewardBeforeDistibution + rewardAfterDistribution);
        }
    }

    // ============ Private Write Functions ============

    /**
     * @dev Settles a user's accumulated stake-age up to the current block. If a new distribution
     *      has occurred since the user's last action, first realizes their reward through that
     *      distribution and resets their stake-age accumulator to start counting from the last
     *      distribution's block.
     * @param user Account whose state is being brought current.
     */
    function _updateStake(address user) private {
        UserInfo storage userInfo = _userInfo[user];

        uint64 fromBlock;
        uint192 cachedStakeAge;
        uint64 distributionId = _distributionId;
        if (userInfo.lastDistributionId == distributionId) {
            fromBlock = userInfo.lastUpdateBlock;
            cachedStakeAge = userInfo.stakeAge;
        } else {
            userInfo.reward = uint192(_userReward(user));
            unchecked { fromBlock = _distributionInfo[distributionId - 1].block; } // forgefmt: disable-line
        }

        uint64 block64 = block.number > type(uint64).max ? type(uint64).max : uint64(block.number);
        unchecked {
            userInfo.stakeAge = cachedStakeAge + uint192(userInfo.stake) * (block64 - fromBlock);
            _distributionStakeAge += uint192(__totalStake) * (block64 - _lastUpdateBlock);
        }

        userInfo.lastUpdateBlock = block64;
        _lastUpdateBlock = block64;

        userInfo.lastDistributionId = distributionId;
    }
}
