// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { FairRewardDistributor } from "./FairRewardDistributor.sol";

/**
 * @title FairRewardDistributorERC4626
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
contract FairRewardDistributorERC4626 is ERC4626, FairRewardDistributor {
    using SafeCast for uint256;

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
     * @dev Initializes FairRewardDistributorERC4626.
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

        uint256 assets = previewRedeemFor(shares, owner);
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
        return Math.min(previewRedeemFor(maxRedeem(owner), owner), _maxWithdraw(owner));
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
        uint256 userStake;
        unchecked {
            userStake = uint256(_userStake(owner)) + _userReward(owner);
            if (userStake == 0) return 0;
        }
        return Math.mulDiv(assets, balanceOf(owner), userStake);
    }

    /**
     * @inheritdoc ERC4626
     */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return previewRedeemFor(shares, _msgSender());
    }

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their redeem at the current block,
     * given current on-chain conditions for a given account.
     * @param shares Amount of Vault shares to burn.
     * @param owner Account to query the amount of assets for.
     * @return Amount of assets that would be withdrawn in a redeem call in the same transaction.
     */
    function previewRedeemFor(uint256 shares, address owner) public view virtual returns (uint256) {
        uint256 balance = balanceOf(owner);
        if (balance == 0) return 0;
        unchecked { return Math.mulDiv(shares, uint256(_userStake(owner)) + _userReward(owner), balance); } // forgefmt: disable-line
    }

    // ============ Internal Write Functions ============

    /**
     * @inheritdoc ERC4626
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        super._deposit(caller, receiver, assets, shares);
        _stake(assets.toUint128(), receiver);
    }

    /**
     * @inheritdoc ERC4626
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        super._withdraw(caller, receiver, owner, assets, shares);

        uint128 userStake = _userStake(owner);
        uint128 toWithdraw = uint128(Math.min(userStake, assets));
        uint192 toCollect;
        unchecked { toCollect = (assets - toWithdraw).toUint192(); } // forgefmt: disable-line

        _withdraw(toWithdraw, owner);
        if (toCollect > 0) _collectReward(toCollect, owner);
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
