// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

//TODO; vault wrapper?
//TODO: upgradeable?

abstract contract FairRewardDistributor {
    using SafeCast for uint256;

    // ============ Types ============

    struct DistributionInfo {
        uint64 block;
        uint256 rewardPerStakeAge;
        uint256 cumRewardAgePerStakeAge;
    }

    struct UserInfo {
        uint192 stake;
        uint64 lastDistributionId;
        uint192 reward;
        uint64 lastUpdateBlock;
        uint256 stakeAge;
    }

    // ============ Storage ============

    uint192 private __totalStake;
    uint192 private _lastUpdateBlock;
    uint256 private _totalStakeAge;

    uint64 private _distributionId;
    mapping(address user => UserInfo) private _userInfo;
    mapping(uint64 distributionId => DistributionInfo) private _distributionInfo;

    uint256 private constant DENOMINATOR = 1 ether;

    // ============ Errors ============

    error InsufficientStake(uint192 stake);

    error InsufficientBalance(uint256 needed, uint256 actual);

    error DistributionNotAvailable();

    // ============ Constructor ============

    constructor() {
        uint64 block64 = block.number.toUint64();
        _distributionInfo[0] = DistributionInfo({
            block: block64,
            rewardPerStakeAge: 0,
            cumRewardAgePerStakeAge: 0
        });
        _distributionId = 1;
        _lastUpdateBlock = block64;
    }

    // ============ Internal Write Functions ============

    function _stake(uint256 liquidity, address recipient) internal returns(uint256) {
        uint192 stake = _preStake(liquidity);
        if(stake == 0) revert InsufficientStake(stake);

        _updateStake(recipient);
        __totalStake += stake;
        // prettier-ignore 
        unchecked { _userInfo[recipient].stake += stake; }

        _postStake(stake, recipient);
        return stake;
    }

    function _preStake(uint256 liquidity) internal virtual returns(uint192);

    function _postStake(uint192 depositStake, address recipient) internal virtual;

    function _withdraw(uint256 liquidity, address from, address recipient) internal returns(uint256) {
        uint192 stake = _preWithdraw(liquidity, recipient);
        if(stake == 0) revert InsufficientStake(stake);

        _updateStake(from);

		UserInfo storage user = _userInfo[from];
		uint192 reward = user.reward;
		if (stake > reward) {
			uint192 balance = user.stake + reward;
            if(stake > balance) revert InsufficientBalance(stake, balance);

            unchecked {
			    user.stake = balance - stake;
			    __totalStake = __totalStake + reward - stake;
            }
			user.reward = 0;
		} else {
            // prettier-ignore
			unchecked { user.reward = reward - stake; }
		}

        _postWithdraw(stake, from, recipient);
        return stake;
    }

    function _preWithdraw(uint256 liquidity, address recipient) internal virtual returns(uint192);
    
    function _postWithdraw(uint192 stake, address from, address recipient) internal virtual;

    function _distribute(uint256 reward) internal returns(uint256) {
        uint192 rewardStake = _preDistribute(reward);
        if(rewardStake == 0) revert InsufficientStake(rewardStake);

        uint256 totalStakeAge = _totalStakeAge + __totalStake * (block.number - _lastUpdateBlock);
        if(totalStakeAge == 0) revert DistributionNotAvailable();
        uint256 rewardPerStakeAge = rewardStake * DENOMINATOR / totalStakeAge;

        uint64 distributionId = _distributionId;
        DistributionInfo storage prevDistributionInfo = _distributionInfo[distributionId - 1];
        uint256 cumRewardAgePerStakeAge = prevDistributionInfo.cumRewardAgePerStakeAge + rewardPerStakeAge * (block.number - prevDistributionInfo.block);
        
        uint64 block64 = block.number.toUint64();
        _distributionInfo[distributionId] = DistributionInfo({
            block: block64,
            rewardPerStakeAge: rewardPerStakeAge,
            cumRewardAgePerStakeAge: cumRewardAgePerStakeAge
        });

        _distributionId = distributionId + 1;
        _lastUpdateBlock = block64;
        _totalStakeAge = 0;

        _postDistribute(rewardStake);
        return reward;
    }

    function _preDistribute(uint256 reward) internal virtual returns(uint192);
    
    function _postDistribute(uint192 rewardStake) internal virtual;

    // ============ Internal View Functions ============

    function _totalStake() internal view returns (uint256) {
        return __totalStake;
    }

    function _userStake(address user) internal view returns (uint256) {
        return _userInfo[user].stake;
    }

    function _userReward(address user) internal view returns (uint256) {
        UserInfo storage userInfo = _userInfo[user];

        uint64 distributionId = _distributionId;
        uint64 userLastDistributionId = userInfo.lastDistributionId;
        uint256 userReward = userInfo.reward;
        if (userLastDistributionId == distributionId) return userReward;

        DistributionInfo memory lastUserDistributionInfo = _distributionInfo[userLastDistributionId];

        uint256 blockDelta;
        uint256 rangeRewardAgePerStakeAge;
        unchecked { 
            blockDelta = lastUserDistributionInfo.block - userInfo.lastUpdateBlock; 
            rangeRewardAgePerStakeAge = _distributionInfo[distributionId - 1].cumRewardAgePerStakeAge - lastUserDistributionInfo.cumRewardAgePerStakeAge;
        }

        uint256 userStake = userInfo.stake;
        uint256 userStakeAge = userInfo.stakeAge + userStake * blockDelta;

        uint256 rewardBeforeDistibution = Math.mulDiv(userStakeAge, lastUserDistributionInfo.rewardPerStakeAge, DENOMINATOR);
        uint256 rewardAfterDistribution = Math.mulDiv(userStake, rangeRewardAgePerStakeAge, DENOMINATOR);
        return userReward + rewardBeforeDistibution + rewardAfterDistribution;
    }

    // ============ Private Write Functions ============

    function _updateStake(address user) private {
        UserInfo storage userInfo = _userInfo[user];

        uint256 fromBlock;
        uint64 distributionId = _distributionId;
        if (userInfo.lastDistributionId == distributionId) {
            fromBlock = userInfo.lastUpdateBlock;
        } else {
            userInfo.reward = _userReward(user).toUint192();
            // prettier-ignore
            unchecked { fromBlock = _distributionInfo[distributionId - 1].block; }
        }

        uint64 block64 = block.number.toUint64();

        userInfo.stakeAge = userInfo.stake * (block.number - fromBlock);
        userInfo.lastDistributionId = distributionId;
        userInfo.lastUpdateBlock = block64;

        _totalStakeAge += __totalStake * (block.number - _lastUpdateBlock);
        _lastUpdateBlock = block64;
    }
}
