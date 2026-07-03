// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

//TODO; vault wrapper?
//TODO: upgradeable?

//TODO: comms

//assumptions: 
//no block numbers higher than 2**64 - 1 are possible
//stakes can be represented by 2**128 - 1 max
abstract contract FairRewardDistributor {
    using SafeCast for uint256;

    // ============ Types ============

    struct DistributionInfo {
        uint64 block;
        uint192 rewardPerStakeAge;
        uint256 cumRewardAgePerStakeAge;
    }

    struct UserInfo {
        uint128 stake;
        uint64 lastDistributionId;
        uint64 lastUpdateBlock;
        uint192 stakeAge;
        uint192 reward;
    }

    // ============ Storage ============

    uint128 private __totalStake;
    uint128 private _lastUpdateBlock;
    uint192 private _totalStakeAge;
    uint64 private _distributionId;
    
    mapping(address user => UserInfo) private _userInfo;
    mapping(uint64 distributionId => DistributionInfo) private _distributionInfo;

    uint256 private constant DENOMINATOR = type(uint64).max;

    // ============ Errors ============

    error InsufficientStake(uint128 stake);

    error InsufficientBalance(uint256 needed, uint256 actual);

    error DistributionNotAvailable();

    error TotalStakeOverflow();

    error DistributionIdOverflow();

    // ============ Constructor ============

    constructor() {
        uint64 block64 = block.number.toUint64();
        _distributionInfo[0] = DistributionInfo({
            block: block64,
            rewardPerStakeAge: 0,
            cumRewardAgePerStakeAge: 0
        });
        _lastUpdateBlock = block64;
        _distributionId = 1;
    }

    // ============ Internal Write Functions ============

    function _stake(uint256 liquidity, address recipient) internal returns(uint256) {
        uint128 stake = _preStake(liquidity);
        if(stake == 0) revert InsufficientStake(stake);

        _updateStake(recipient);

        unchecked { 
            uint128 totalStake = __totalStake;
            if(totalStake + stake < __totalStake) revert TotalStakeOverflow();
            
            __totalStake = totalStake + stake;
            _userInfo[recipient].stake += stake; 
        }

        _postStake(stake, recipient);
        return stake;
    }

    function _withdraw(uint256 liquidity, address user, address recipient) internal returns(uint256) {
        uint128 stake = _preWithdraw(liquidity);
        if(stake == 0) revert InsufficientStake(stake);

        _updateStake(user);

		UserInfo storage userInfo = _userInfo[user];
		uint192 reward = userInfo.reward;
        unchecked { 
		    if (stake > reward) {
			    uint192 balance = userInfo.stake + reward;
                if(stake > balance) revert InsufficientBalance(stake, balance);

                userInfo.stake = uint128(balance - stake);
                __totalStake += uint128(reward) - stake;
            
			    userInfo.reward = 0;
		    } else {
			    userInfo.reward = reward - stake;
		    }
        }

        _postWithdraw(stake, user, recipient);
        return stake;
    }

    function _distribute(uint256 reward) internal returns(uint256) {
        uint128 rewardStake = _preDistribute(reward);
        if(rewardStake == 0) revert InsufficientStake(rewardStake);

        uint64 block64 = block.number.toUint64();
        uint64 distributionId = _distributionId;

        unchecked { 
            uint64 newDistributionId = distributionId + 1;
            if(newDistributionId == 0) revert DistributionIdOverflow();
            _distributionId = newDistributionId;

            uint192 totalStakeAge = _totalStakeAge + __totalStake * (block64 - _lastUpdateBlock);
            if(totalStakeAge == 0) revert DistributionNotAvailable();

            DistributionInfo storage prevDistributionInfo = _distributionInfo[distributionId - 1];
            uint192 rewardPerStakeAge = rewardStake * uint128(DENOMINATOR) / totalStakeAge;
            uint256 cumRewardAgePerStakeAge = prevDistributionInfo.cumRewardAgePerStakeAge + rewardPerStakeAge * (block64 - prevDistributionInfo.block);
        
            _distributionInfo[distributionId] = DistributionInfo({
                block: block64,
                rewardPerStakeAge: rewardPerStakeAge,
                cumRewardAgePerStakeAge: cumRewardAgePerStakeAge
            });
        }

        _lastUpdateBlock = block64;
        _totalStakeAge = 0;

        _postDistribute(rewardStake);
        return reward;
    }


    function _postStake(uint128 depositStake, address recipient) internal virtual;

    function _postWithdraw(uint128 stake, address user, address recipient) internal virtual;
    
    function _postDistribute(uint128 rewardStake) internal virtual;

    // ============ Internal View Functions ============

    function _preStake(uint256 liquidity) internal view virtual returns(uint128);

    function _preWithdraw(uint256 liquidity) internal view virtual returns(uint128);

    function _preDistribute(uint256 reward) internal view virtual returns(uint128);

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
        if (userLastDistributionId == distributionId) return userInfo.reward;

        DistributionInfo memory lastUserDistributionInfo = _distributionInfo[userLastDistributionId];

        unchecked { 
            uint256 userStake = userInfo.stake;
            uint256 userStakeAge = userInfo.stakeAge + userStake * (lastUserDistributionInfo.block - userInfo.lastUpdateBlock);

            uint256 rewardBeforeDistibution = Math.mulDiv(userStakeAge, lastUserDistributionInfo.rewardPerStakeAge, DENOMINATOR);
            uint256 rewardAfterDistribution = Math.mulDiv(userStake, _distributionInfo[distributionId - 1].cumRewardAgePerStakeAge - lastUserDistributionInfo.cumRewardAgePerStakeAge, DENOMINATOR);

            return userInfo.reward + rewardBeforeDistibution + rewardAfterDistribution; 
        }
    }

    // ============ Private Write Functions ============

    function _updateStake(address user) private {
        UserInfo storage userInfo = _userInfo[user];

        uint64 fromBlock;
        uint64 distributionId = _distributionId;
        if (userInfo.lastDistributionId == distributionId) {
            fromBlock = userInfo.lastUpdateBlock;
        } else {
            userInfo.reward = uint192(_userReward(user));
            // prettier-ignore
            unchecked { fromBlock = _distributionInfo[distributionId - 1].block; }
        }

        uint64 block64 = block.number.toUint64();//TODO: what if its more?
        unchecked {
            userInfo.stakeAge = uint192(userInfo.stake * (block64 - fromBlock));
            _totalStakeAge += uint192(__totalStake * (block64 - _lastUpdateBlock));
        }

        userInfo.lastUpdateBlock = block64;
        _lastUpdateBlock = block64;

        userInfo.lastDistributionId = distributionId;
    }
}
