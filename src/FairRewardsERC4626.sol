// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { FairRewards } from "./FairRewards.sol";

/**
 * @title FairRewardsERC4626
 * @author Ivan Menshchikov (https://github.com/Juglipaff).
 * @dev ERC4626-compliant implementation of constant-gas, front-run-resistant on-chain reward
 *      distribution algorithm (https://juglipaff.github.io/Token-Distribution-Algorithm/).
 *      Every operation is O(1) regardless of participant count or number of past distributions.
 *
 *      Same overriding rules apply as in base ERC4626 contract by OpenZeppelin.
 *
 *      Assumptions:
 *      - Block numbers don't exceed 2**64 - 1. Rewards stop accruing beyond that horizon.
 *      - Individual and total stakes are bounded by 2**128 - 1.
 *      - Underlying token is reward token.
 */
contract FairRewardsERC4626 is ERC4626, FairRewards {
    using SafeCast for uint256;
    using SafeCast for uint192;

    // ============ Storage ============

    ///@dev Reward that was transfered to owner, but not accounted for in _userReward(owner).
    mapping(address owner => uint192) private __userReward;

    // ============ Events ============

    /**
     * @dev Emitted when an asset distribution is made.
     * @param sender Sender of the assets.
     * @param assets Amount of distributed assets.
     */
    event Distribute(address indexed sender, uint256 assets);

    // ============ Errors ============

    /**
     * @dev Attempted to distribute more assets than the max allowed.
     * @param assets Amount of assets provided.
     * @param max The maximum amount of assets allowed.
     */
    error ERC4626ExceededMaxDistribute(uint256 assets, uint256 max);

    // ============ Constructor ============

    /**
     * @dev Initializes FairRewardsERC4626.
     * @param name_ Name of Vault share token to set.
     * @param symbol_ Symbol of Vault share token to set.
     * @param asset_ Asset to use as underlying.
     */
    constructor(string memory name_, string memory symbol_, IERC20 asset_) ERC20(name_, symbol_) ERC4626(asset_) { }

    // ============ Public Write Functions ============

    /**
     * @dev Distributes assets between all Vault participants in O(1) time complexity.
     * @param assets Amount of assets to distribute.
     */
    function distribute(uint256 assets) public virtual {
        uint256 maxAssets = maxDistribute();
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDistribute(assets, maxAssets);
        }

        _distribute(_msgSender(), assets);
    }

    /**
     * @inheritdoc ERC4626
     */
    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdrawFor(assets, owner);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /**
     * @inheritdoc ERC4626
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        (uint256 fromReward, uint256 fromStake) = previewRedeemFor(shares, owner);
        uint256 assets = fromReward + fromStake;
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    // ============ Public View Functions ============

    /**
     * @inheritdoc ERC4626
     */
    function maxDeposit(address receiver) public view override returns (uint256) {
        uint256 totalStake = _totalStake();
        unchecked { return Math.max(_maxDeposit(receiver), totalStake) - totalStake; } // forgefmt: disable-line
    }

    /**
     * @inheritdoc ERC4626
     */
    function maxMint(address receiver) public view override returns (uint256) {
        return Math.min(previewDeposit(maxDeposit(receiver)), _maxMint(receiver));
    }

    /**
     * @inheritdoc ERC4626
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        (uint256 fromReward, uint256 fromStake) = previewRedeemFor(maxRedeem(owner), owner);
        return Math.min(fromReward + fromStake, _maxWithdraw(owner));
    }

    /**
     * @inheritdoc ERC4626
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(balanceOf(owner), _maxRedeem(owner));
    }

    /**
     * @dev Returns the maximum amount of assets that can be distributed to users.
     * @return The maximum amount of assets that can be distributed.
     */
    function maxDistribute() public view returns (uint256) {
        return _maxDistribute();
    }

    /**
     * @inheritdoc ERC4626
     */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return previewWithdrawFor(assets, _msgSender());
    }

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their withdrawal at the current block,
     * given current on-chain conditions for a given account.
     * @param assets Amount of assets to withdraw.
     * @param owner Account to query the amount of Vault shares for.
     * @return Amount of Vault shares that would be burned in a withdraw call in the same transaction.
     */
    function previewWithdrawFor(uint256 assets, address owner) public view virtual returns (uint256) {
        uint256 balance = balanceOf(owner);
        if (balance == 0) return 0;

        uint256 userStake_ = uint256(_userStake(owner)) + _userReward(owner) + __userReward[owner];
        if (userStake_ == 0) return 0;

        return Math.mulDiv(assets, balance, userStake_);
    }

    /**
     * @inheritdoc ERC4626
     */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        (uint256 fromReward, uint256 fromStake) = previewRedeemFor(shares, _msgSender());
        return fromReward + fromStake;
    }

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their redeem at the current block,
     * given current on-chain conditions for a given account. The total asset amount that would be withdrawn is
     * split across the two accounting buckets in the exact order that `_update` and `_withdraw` consume them:
     * reward first, then principal stake. Reward aggregates both self-accrued reward (`_userReward`) and
     * transfer-credited reward (`__userReward`). The full redeem amount equals `fromReward + fromStake`.
     * @param shares Amount of Vault shares to burn.
     * @param owner Account to query the amount of assets for.
     * @return fromReward Assets drawn from the reward bucket. Equals `min(totalAssets, ownerTotalReward)`.
     * @return fromStake Assets drawn from the principal stake bucket. Equals `totalAssets - fromReward`.
     */
    function previewRedeemFor(uint256 shares, address owner)
        public
        view
        virtual
        returns (uint256 fromReward, uint256 fromStake)
    {
        uint256 balance = balanceOf(owner);
        if (balance == 0) return (0, 0);

        uint256 stake = _userStake(owner);
        uint192 reward = _userReward(owner) + __userReward[owner];
        uint256 assets = Math.mulDiv(shares, stake + reward, balance);

        fromReward = Math.min(assets, reward);
        unchecked { fromStake = assets - fromReward; } // forgefmt: disable-line
    }

    // ============ Internal Write Functions ============

    /**
     * @inheritdoc ERC20
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0)) {
            (uint256 fromReward, uint256 fromStake) = previewRedeemFor(value, from);

            uint256 rewardRemaining = fromReward;
            if (rewardRemaining > 0) {
                uint192 toCollect = uint192(Math.min(__userReward[from], rewardRemaining));
                if (toCollect > 0) {
                    unchecked {
                        rewardRemaining -= toCollect;
                        __userReward[from] -= toCollect;
                    }
                }

                if (rewardRemaining > 0) {
                    toCollect = uint192(Math.min(_userReward(from), rewardRemaining));
                    if (toCollect > 0) _collectReward(toCollect, from);
                }
            }

            if (fromStake > 0) _withdraw(fromStake.toUint128(), from);

            if (to != address(0)) {
                uint256 assets = fromReward + fromStake;
                uint128 stake = uint128(Math.min(assets, type(uint128).max));
                _stake(stake, to);

                unchecked {
                    uint192 reward = uint192(assets - stake);
                    if (reward > 0) __userReward[to] += reward;
                }
            }
        } else if (to != address(0)) {
            _stake(previewMint(value).toUint128(), to);
        }

        super._update(from, to, value);
    }

    /**
     * @dev Distribute workflow.
     * @param caller Address making a call.
     * @param assets Amount of assets being distributed.
     */
    function _distribute(address caller, uint256 assets) internal virtual {
        _transferIn(caller, assets);
        _distribute(assets.toUint128());

        emit Distribute(caller, assets);
    }

    // ============ Internal View Functions ============

    /**
     * @inheritdoc ERC4626
     */
    function _convertToShares(
        uint256 assets,
        Math.Rounding /*rounding*/
    )
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return assets;
    }

    /**
     * @inheritdoc ERC4626
     */
    function _convertToAssets(
        uint256 shares,
        Math.Rounding /*rounding*/
    )
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return shares;
    }

    /**
     * @dev Returns the maximum amount of the underlying asset that can be deposited into the Vault for the receiver,
     * through a deposit call.
     * @param receiver Account that the limit is imposed on.
     * @return The maximum amount of the underlying asset that can be deposited.
     */
    function _maxDeposit(address receiver) internal view virtual returns (uint128) {
        return type(uint128).max;
    }

    /**
     * @dev Returns the maximum amount of the Vault shares that can be minted for the receiver, through a mint call.
     * @param receiver Account that the limit is imposed on.
     * @return The maximum amount of the Vault shares.
     */
    function _maxMint(address receiver) internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev Returns the maximum amount of the underlying asset that can be withdrawn from the owner balance in the
     * Vault, through a withdraw call.
     * @param owner Account that the limit is imposed on.
     * @return The maximum amount of the underlying asset that can be withdrawn.
     */
    function _maxWithdraw(address owner) internal view virtual returns (uint192) {
        return type(uint192).max;
    }

    /**
     * @dev Returns the maximum amount of Vault shares that can be redeemed from the owner balance in the Vault,
     * through a redeem call.
     * @param owner Account that the limit is imposed on.
     * @return The maximum amount of Vault shares that can be redeemed.
     */
    function _maxRedeem(address owner) internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev Returns the maximum amount of assets that can be distributed to users.
     * @return The maximum amount of assets that can be distributed.
     */
    function _maxDistribute() internal view virtual returns (uint128) {
        return type(uint128).max;
    }
}
