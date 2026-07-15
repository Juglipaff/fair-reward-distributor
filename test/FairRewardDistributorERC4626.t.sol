// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FairRewardDistributor } from "../src/FairRewardDistributor.sol";
import { FairRewardDistributorERC4626 } from "../src/FairRewardDistributorERC4626.sol";

/**
 * @title MockAsset
 * @dev Minimal ERC20 with public mint used as the ERC4626 underlying asset. Kept in the same file
 *      to avoid polluting `test/mocks/` for a single-purpose test double.
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
 * @title MockVault2x
 * @dev Extends the wrapper with a fixed 2:1 asset-to-share conversion (two shares per asset). Used
 *      to verify that downstream vaults can install a custom exchange rate by overriding
 *      `_convertToShares` and `_convertToAssets`.
 */
contract MockVault2x is FairRewardDistributorERC4626 {
    /**
     * @dev Deploys the mock with the given vault metadata and underlying asset.
     * @param name_ Name of Vault share token to set.
     * @param symbol_ Symbol of Vault share token to set.
     * @param asset_ Asset to use as underlying.
     */
    constructor(string memory name_, string memory symbol_, IERC20 asset_)
        FairRewardDistributorERC4626(name_, symbol_, asset_)
    { }

    /**
     * @inheritdoc ERC4626
     */
    function _convertToShares(
        uint256 assets,
        Math.Rounding /*rounding*/
    )
        internal
        pure
        override
        returns (uint256)
    {
        return assets * 2;
    }

    /**
     * @inheritdoc ERC4626
     */
    function _convertToAssets(
        uint256 shares,
        Math.Rounding /*rounding*/
    )
        internal
        pure
        override
        returns (uint256)
    {
        return shares / 2;
    }
}

/**
 * @title FairRewardDistributorERC4626Test
 * @dev Unit tests for the ERC4626 wrapper. Uses a 1:1 mock ERC20 asset so preview and conversion
 *      results can be checked against exact expected values.
 */
contract FairRewardDistributorERC4626Test is Test {
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

    ///@dev Relative-error tolerance for reward assertions, in wad (1e18 = 100%). 1e2 = 0.00000000000001%.
    uint256 internal constant REWARD_TOLERANCE = 1e2;

    // ============ Events ============

    /**
     * @dev Mirror of the wrapper's Distribute event used in expectEmit calls.
     * @param sender Sender of the assets.
     * @param assets Amount of distributed assets.
     */
    event Distribute(address indexed sender, uint256 assets);

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

    /**
     * @dev Funds `user` and performs a deposit against the vault.
     * @param user Depositor.
     * @param amount Asset amount to deposit.
     * @return shares Shares minted to `user`.
     */
    function _depositAs(address user, uint256 amount) internal returns (uint256 shares) {
        _fund(user, amount);
        vm.prank(user);
        shares = vault.deposit(amount, user);
    }

    /**
     * @dev Funds `user` and performs a distribute against the vault.
     * @param user Distributor.
     * @param amount Asset amount to distribute.
     */
    function _distributeAs(address user, uint256 amount) internal {
        _fund(user, amount);
        vm.prank(user);
        vault.distribute(amount);
    }

    // ============ Constructor ============

    function test_Constructor_NameAndSymbolSet() public view {
        assertEq(vault.name(), "Vault Share");
        assertEq(vault.symbol(), "vMCK");
    }

    function test_Constructor_AssetSet() public view {
        assertEq(vault.asset(), address(asset));
    }

    function test_Constructor_DecimalsMatchAsset() public view {
        assertEq(vault.decimals(), asset.decimals());
    }

    function test_Constructor_TotalSupplyZero() public view {
        assertEq(vault.totalSupply(), 0);
    }

    function test_Constructor_TotalAssetsZero() public view {
        assertEq(vault.totalAssets(), 0);
    }

    // ============ Deposit — happy paths ============

    function test_Deposit_MintsSharesOneToOne() public {
        uint256 shares = _depositAs(alice, 100 ether);

        assertEq(shares, 100 ether);
        assertEq(vault.balanceOf(alice), 100 ether);
    }

    function test_Deposit_TransfersAssetsFromCaller() public {
        _depositAs(alice, 100 ether);

        assertEq(asset.balanceOf(alice), 0);
        assertEq(asset.balanceOf(address(vault)), 100 ether);
    }

    function test_Deposit_ToReceiver_CreditsReceiver() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        vault.deposit(100 ether, bob);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 100 ether);
    }

    function test_Deposit_TwoUsers_IndependentBalances() public {
        _depositAs(alice, 100 ether);
        _depositAs(bob, 250 ether);

        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.balanceOf(bob), 250 ether);
        assertEq(vault.totalSupply(), 350 ether);
    }

    function test_Deposit_AtAdvertisedMax_Succeeds() public {
        uint256 max = vault.maxDeposit(alice);
        uint256 shares = _depositAs(alice, max);

        assertEq(shares, max);
        assertEq(vault.balanceOf(alice), max);
    }

    // ============ Deposit — reverts ============

    function test_Deposit_ZeroAmount_IsNoop() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(0, alice);

        assertEq(shares, 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_Deposit_RevertWhen_ExceedsMax() public {
        uint256 max = vault.maxMint(alice);
        uint256 amount = max + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, amount, max));
        vault.deposit(amount, alice);
    }

    // ============ Mint — happy paths ============

    function test_Mint_TransfersAssetsOneToOne() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        uint256 assets = vault.mint(100 ether, alice);

        assertEq(assets, 100 ether);
        assertEq(asset.balanceOf(alice), 0);
        assertEq(asset.balanceOf(address(vault)), 100 ether);
    }

    function test_Mint_CreditsShares() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        vault.mint(100 ether, alice);

        assertEq(vault.balanceOf(alice), 100 ether);
    }

    // ============ Mint — reverts ============

    function test_Mint_ZeroAmount_IsNoop() public {
        vm.prank(alice);
        uint256 assets = vault.mint(0, alice);

        assertEq(assets, 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_Mint_RevertWhen_ExceedsMax() public {
        uint256 max = vault.maxMint(alice);
        uint256 shares = max + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, alice, shares, max));
        vault.mint(shares, alice);
    }

    // ============ Withdraw — happy paths ============

    function test_Withdraw_BurnsShares_ReturnsAssets() public {
        _depositAs(alice, 100 ether);

        vm.prank(alice);
        uint256 shares = vault.withdraw(40 ether, alice, alice);

        assertEq(shares, 40 ether);
        assertEq(vault.balanceOf(alice), 60 ether);
        assertEq(asset.balanceOf(alice), 40 ether);
    }

    function test_Withdraw_ToDifferentReceiver() public {
        _depositAs(alice, 100 ether);

        vm.prank(alice);
        vault.withdraw(40 ether, bob, alice);

        assertEq(vault.balanceOf(alice), 60 ether);
        assertEq(asset.balanceOf(alice), 0);
        assertEq(asset.balanceOf(bob), 40 ether);
    }

    function test_Withdraw_ByApprovedSpender() public {
        _depositAs(alice, 100 ether);
        vm.prank(alice);
        vault.approve(bob, 40 ether);

        vm.prank(bob);
        vault.withdraw(40 ether, bob, alice);

        assertEq(vault.balanceOf(alice), 60 ether);
        assertEq(asset.balanceOf(bob), 40 ether);
        assertEq(vault.allowance(alice, bob), 0);
    }

    function test_Withdraw_AfterDistribution_IncludesRewardBoost() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        uint256 maxAssets = vault.maxWithdraw(alice);
        assertLe(maxAssets, 110 ether);
        assertApproxEqRel(maxAssets, 110 ether, REWARD_TOLERANCE);

        vm.prank(alice);
        uint256 shares = vault.withdraw(maxAssets, alice, alice);

        assertEq(shares, 100 ether);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(asset.balanceOf(alice), maxAssets);
    }

    function test_Withdraw_PartialAfterDistribution_PreviewDoesNotExceedVaultAssets() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        vm.prank(alice);
        vault.withdraw(20 ether, alice, alice);

        uint256 vaultAssets = asset.balanceOf(address(vault));
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 preview = vault.previewRedeemFor(aliceShares, alice);

        assertLe(preview, vaultAssets);
        assertApproxEqRel(preview, 90 ether, REWARD_TOLERANCE);
    }

    // ============ Withdraw — reverts ============

    function test_Withdraw_RevertWhen_ExceedsMax() public {
        _depositAs(alice, 100 ether);
        uint256 max = vault.maxWithdraw(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, max + 1, max));
        vault.withdraw(max + 1, alice, alice);
    }

    // ============ Redeem — happy paths ============

    function test_Redeem_BurnsShares_ReturnsAssets() public {
        _depositAs(alice, 100 ether);

        vm.prank(alice);
        uint256 assets = vault.redeem(40 ether, alice, alice);

        assertEq(assets, 40 ether);
        assertEq(vault.balanceOf(alice), 60 ether);
        assertEq(asset.balanceOf(alice), 40 ether);
    }

    function test_Redeem_ToDifferentReceiver() public {
        _depositAs(alice, 100 ether);

        vm.prank(alice);
        vault.redeem(40 ether, bob, alice);

        assertEq(vault.balanceOf(alice), 60 ether);
        assertEq(asset.balanceOf(alice), 0);
        assertEq(asset.balanceOf(bob), 40 ether);
    }

    function test_Redeem_ByApprovedSpender() public {
        _depositAs(alice, 100 ether);
        vm.prank(alice);
        vault.approve(bob, 40 ether);

        vm.prank(bob);
        vault.redeem(40 ether, bob, alice);

        assertEq(vault.balanceOf(alice), 60 ether);
        assertEq(asset.balanceOf(alice), 0);
        assertEq(asset.balanceOf(bob), 40 ether);
        assertEq(vault.allowance(alice, bob), 0);
    }

    function test_Redeem_AllShares_AfterDistribution_ReturnsPrincipalPlusReward() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        vm.prank(alice);
        uint256 assets = vault.redeem(100 ether, alice, alice);

        assertLe(assets, 110 ether);
        assertApproxEqRel(assets, 110 ether, REWARD_TOLERANCE);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Redeem_HalfShares_AfterDistribution_ReturnsHalfOfPrincipalPlusReward() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        vm.prank(alice);
        uint256 assets = vault.redeem(50 ether, alice, alice);

        assertLe(assets, 55 ether);
        assertApproxEqRel(assets, 55 ether, REWARD_TOLERANCE);
        assertEq(vault.balanceOf(alice), 50 ether);
    }

    function test_Redeem_PartialAfterDistribution_PreviewDoesNotExceedVaultAssets() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        vm.prank(alice);
        vault.redeem(50 ether, alice, alice);

        uint256 vaultAssets = asset.balanceOf(address(vault));
        uint256 preview = vault.previewRedeemFor(vault.balanceOf(alice), alice);

        assertLe(preview, vaultAssets);
        assertApproxEqRel(preview, vaultAssets, REWARD_TOLERANCE);
    }

    function test_Redeem_FinalAfterPartial_Succeeds() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        vm.prank(alice);
        uint256 firstAssets = vault.redeem(50 ether, alice, alice);
        assertLe(firstAssets, 55 ether);
        assertApproxEqRel(firstAssets, 55 ether, REWARD_TOLERANCE);

        vm.prank(alice);
        uint256 secondAssets = vault.redeem(50 ether, alice, alice);
        assertLe(secondAssets, 55 ether);
        assertApproxEqRel(secondAssets, 55 ether, REWARD_TOLERANCE);

        assertLe(asset.balanceOf(alice), 110 ether);
        assertApproxEqRel(asset.balanceOf(alice), 110 ether, REWARD_TOLERANCE);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(asset.balanceOf(address(vault)), 110 ether - asset.balanceOf(alice));
    }

    // ============ Redeem — reverts ============

    function test_Redeem_RevertWhen_ExceedsMax() public {
        _depositAs(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, 100 ether + 1, 100 ether)
        );
        vault.redeem(100 ether + 1, alice, alice);
    }

    // ============ Distribute — happy paths ============

    function test_Distribute_TransfersAssetsFromCaller() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);

        _fund(bob, 10 ether);
        vm.prank(bob);
        vault.distribute(10 ether);

        assertEq(asset.balanceOf(bob), 0);
        assertEq(asset.balanceOf(address(vault)), 110 ether);
    }

    function test_Distribute_EmitsEvent() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _fund(bob, 10 ether);

        vm.expectEmit(true, false, false, true, address(vault));
        emit Distribute(bob, 10 ether);

        vm.prank(bob);
        vault.distribute(10 ether);
    }

    function test_Distribute_DoesNotMintNewShares() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);

        assertEq(vault.totalSupply(), 100 ether);
        assertEq(vault.balanceOf(alice), 100 ether);
    }

    function test_Distribute_TwoUsersEqualStakeEqualTime_HalfEach() public {
        _depositAs(alice, 100 ether);
        _depositAs(bob, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(carol, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        uint256 aliceMax = vault.maxWithdraw(alice);
        uint256 bobMax = vault.maxWithdraw(bob);

        assertLe(aliceMax, 105 ether);
        assertApproxEqRel(aliceMax, 105 ether, REWARD_TOLERANCE);
        assertLe(bobMax, 105 ether);
        assertApproxEqRel(bobMax, 105 ether, REWARD_TOLERANCE);
    }

    function test_Distribute_TwoUsersDifferentStakeSameTime_ProportionalReward() public {
        _depositAs(alice, 100 ether);
        _depositAs(bob, 300 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(carol, 4 ether);
        vm.roll(GENESIS_BLOCK + 20);

        uint256 aliceMax = vault.maxWithdraw(alice);
        uint256 bobMax = vault.maxWithdraw(bob);

        assertLe(aliceMax, 101 ether);
        assertApproxEqRel(aliceMax, 101 ether, REWARD_TOLERANCE);
        assertLe(bobMax, 303 ether);
        assertApproxEqRel(bobMax, 303 ether, REWARD_TOLERANCE);
    }

    // ============ Distribute — reverts ============

    function test_Distribute_ZeroAmount_IsNoop() public {
        _depositAs(alice, 100 ether);
        vm.roll(block.number + 10);

        vm.prank(bob);
        vault.distribute(0);

        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.totalSupply(), 100 ether);
        assertEq(vault.totalAssets(), 100 ether);
    }

    function test_Distribute_RevertWhen_NoStake() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(FairRewardDistributor.DistributionNotAvailable.selector);
        vault.distribute(10 ether);
    }

    function test_Distribute_RevertWhen_ExceedsMax() public {
        uint256 max = vault.maxDistribute();
        uint256 amount = max + 1;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(FairRewardDistributorERC4626.ERC4626ExceededMaxDistribute.selector, amount, max)
        );
        vault.distribute(amount);
    }

    // ============ Preview ============

    function test_PreviewDeposit_OneToOne() public view {
        assertEq(vault.previewDeposit(123 ether), 123 ether);
    }

    function test_PreviewMint_OneToOne() public view {
        assertEq(vault.previewMint(123 ether), 123 ether);
    }

    function test_PreviewWithdraw_NoReward_OneToOne() public {
        _depositAs(alice, 100 ether);

        vm.prank(alice);
        uint256 shares = vault.previewWithdraw(40 ether);
        assertEq(shares, 40 ether);
    }

    function test_PreviewWithdrawFor_ArbitraryOwner() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        uint256 shares = vault.previewWithdrawFor(110 ether, alice);
        assertApproxEqRel(shares, 100 ether, REWARD_TOLERANCE);
    }

    function test_PreviewRedeem_NoReward_OneToOne() public {
        _depositAs(alice, 100 ether);

        vm.prank(alice);
        uint256 assets = vault.previewRedeem(40 ether);
        assertEq(assets, 40 ether);
    }

    function test_PreviewRedeemFor_ArbitraryOwner() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        uint256 assets = vault.previewRedeemFor(100 ether, alice);
        assertApproxEqRel(assets, 110 ether, REWARD_TOLERANCE);
    }

    function test_PreviewWithdrawFor_NonHolder_ReturnsZero() public view {
        assertEq(vault.previewWithdrawFor(1 ether, alice), 0);
    }

    function test_PreviewRedeemFor_NonHolder_ReturnsZero() public view {
        assertEq(vault.previewRedeemFor(1 ether, alice), 0);
    }

    function test_PreviewWithdraw_NonHolder_ReturnsZero() public {
        vm.prank(alice);
        assertEq(vault.previewWithdraw(1 ether), 0);
    }

    function test_PreviewRedeem_NonHolder_ReturnsZero() public {
        vm.prank(alice);
        assertEq(vault.previewRedeem(1 ether), 0);
    }

    // ============ Max ============

    function test_MaxDeposit_ReturnsUint128Max() public view {
        assertEq(vault.maxDeposit(alice), type(uint128).max);
    }

    function test_MaxMint_ReturnsUint128Max() public view {
        assertEq(vault.maxMint(alice), type(uint128).max);
    }

    function test_MaxRedeem_EqualsBalance() public {
        _depositAs(alice, 100 ether);
        assertEq(vault.maxRedeem(alice), 100 ether);
    }

    function test_MaxRedeem_NonHolder_IsZero() public view {
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_MaxWithdraw_NoReward_EqualsBalance() public {
        _depositAs(alice, 100 ether);
        assertEq(vault.maxWithdraw(alice), 100 ether);
    }

    function test_MaxWithdraw_WithReward_IncludesReward() public {
        _depositAs(alice, 100 ether);
        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 10 ether);
        vm.roll(GENESIS_BLOCK + 20);

        uint256 maxAssets = vault.maxWithdraw(alice);
        assertApproxEqRel(maxAssets, 110 ether, REWARD_TOLERANCE);
    }

    function test_MaxWithdraw_NonHolder_ReturnsZero() public view {
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_MaxWithdraw_AfterFullExit_ReturnsZero() public {
        _depositAs(alice, 100 ether);
        vm.prank(alice);
        vault.withdraw(100 ether, alice, alice);

        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_MaxDeposit_NearFull_ReflectsRemainingCap() public {
        uint128 filled = type(uint128).max - 100;
        _depositAs(alice, filled);

        assertEq(vault.maxDeposit(bob), 100);
    }

    function test_MaxMint_NearFull_ReflectsRemainingCap() public {
        uint128 filled = type(uint128).max - 100;
        _depositAs(alice, filled);

        assertEq(vault.maxMint(bob), 100);
    }

    // ============ Convert ============

    function test_ConvertToShares_OneToOne() public view {
        assertEq(vault.convertToShares(123 ether), 123 ether);
    }

    function test_ConvertToAssets_OneToOne() public view {
        assertEq(vault.convertToAssets(123 ether), 123 ether);
    }

    function test_TotalAssets_ReflectsVaultBalance() public {
        _depositAs(alice, 100 ether);
        assertEq(vault.totalAssets(), 100 ether);

        vm.roll(GENESIS_BLOCK + 10);
        _distributeAs(bob, 25 ether);
        assertEq(vault.totalAssets(), 125 ether);
    }

    // ============ Fuzz ============

    function testFuzz_Deposit_RoundTrip_NoDistribution(uint128 amount) public {
        amount = uint128(bound(uint256(amount), 1, type(uint128).max));

        uint256 shares = _depositAs(alice, amount);
        assertEq(shares, amount);
        assertEq(vault.balanceOf(alice), amount);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertEq(assets, amount);
        assertEq(asset.balanceOf(alice), amount);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testFuzz_Distribute_TwoUsersEqualStake_HalfEach(uint128 stakeAmount, uint128 rewardAmount) public {
        stakeAmount = uint128(bound(uint256(stakeAmount), 1e18, type(uint128).max / 2));
        rewardAmount = uint128(bound(uint256(rewardAmount), 1e18, type(uint128).max));

        _depositAs(alice, stakeAmount);
        _depositAs(bob, stakeAmount);
        vm.roll(GENESIS_BLOCK + 100);
        _distributeAs(carol, rewardAmount);
        vm.roll(GENESIS_BLOCK + 200);

        uint256 aliceMax = vault.maxWithdraw(alice);
        uint256 bobMax = vault.maxWithdraw(bob);

        uint256 expected = uint256(stakeAmount) + uint256(rewardAmount) / 2;
        assertApproxEqRel(aliceMax, expected, REWARD_TOLERANCE);
        assertApproxEqRel(bobMax, expected, REWARD_TOLERANCE);
    }

    function testFuzz_ConvertToShares_Identity(uint256 assets) public view {
        assertEq(vault.convertToShares(assets), assets);
    }

    function testFuzz_ConvertToAssets_Identity(uint256 shares) public view {
        assertEq(vault.convertToAssets(shares), shares);
    }
}

/**
 * @title FairRewardDistributorERC4626OverrideTest
 * @dev Verifies that a downstream vault can install a custom asset-to-share exchange rate by
 *      overriding `_convertToShares` and `_convertToAssets`. Uses `MockVault2x` which mints two
 *      shares per asset. Every ERC4626 entrypoint that routes through the conversion pair is
 *      exercised so the override is honored end-to-end.
 */
contract FairRewardDistributorERC4626OverrideTest is Test {
    // ============ Storage ============

    ///@dev Contract under test.
    MockVault2x internal vault;
    ///@dev Underlying asset.
    MockAsset internal asset;

    ///@dev Test user Alice.
    address internal alice = address(0xA11CE);
    ///@dev Test user Bob.
    address internal bob = address(0xB0B);

    ///@dev Genesis block used for deployment.
    uint256 internal constant GENESIS_BLOCK = 1_000_000;

    ///@dev Relative-error tolerance for reward assertions, in wad (1e18 = 100%). 1e2 = 0.00000000000001%.
    uint256 internal constant REWARD_TOLERANCE = 1e2;

    // ============ Events ============

    /**
     * @dev Mirror of the wrapper's Distribute event used in expectEmit calls.
     * @param sender Sender of the assets.
     * @param assets Amount of distributed assets.
     * @param shares Amount of distributed Vault shares.
     */
    event Distribute(address indexed sender, uint256 assets, uint256 shares);

    // ============ Setup ============

    /**
     * @dev Deploys the mock asset and the 2x-override vault at a fixed genesis block.
     */
    function setUp() public {
        vm.roll(GENESIS_BLOCK);
        asset = new MockAsset();
        vault = new MockVault2x("Mock Vault 2x", "vMCK2", IERC20(address(asset)));
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

    // ============ Convert ============

    function test_ConvertToShares_Reflects2x() public view {
        assertEq(vault.convertToShares(100 ether), 200 ether);
    }

    function test_ConvertToAssets_Reflects2x() public view {
        assertEq(vault.convertToAssets(200 ether), 100 ether);
    }

    function test_ConvertToAssets_OddSharesRoundsDown() public view {
        assertEq(vault.convertToAssets(3), 1);
    }

    // ============ Preview ============

    function test_PreviewDeposit_Reflects2x() public view {
        assertEq(vault.previewDeposit(100 ether), 200 ether);
    }

    function test_PreviewMint_Reflects2x() public view {
        assertEq(vault.previewMint(200 ether), 100 ether);
    }

    // ============ Deposit ============

    function test_Deposit_MintsDoubleShares() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);

        assertEq(shares, 200 ether);
        assertEq(vault.balanceOf(alice), 200 ether);
        assertEq(asset.balanceOf(address(vault)), 100 ether);
    }

    // ============ Mint ============

    function test_Mint_ChargesHalfAssets() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        uint256 assets = vault.mint(200 ether, alice);

        assertEq(assets, 100 ether);
        assertEq(vault.balanceOf(alice), 200 ether);
        assertEq(asset.balanceOf(alice), 0);
    }

    // ============ Withdraw ============

    function test_Withdraw_BurnsDoubleShares() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(alice);
        uint256 shares = vault.withdraw(40 ether, alice, alice);

        assertEq(shares, 80 ether);
        assertEq(vault.balanceOf(alice), 120 ether);
        assertEq(asset.balanceOf(alice), 40 ether);
    }

    // ============ Redeem ============

    function test_Redeem_ReturnsHalfAssets() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(80 ether, alice, alice);

        assertEq(assets, 40 ether);
        assertEq(vault.balanceOf(alice), 120 ether);
        assertEq(asset.balanceOf(alice), 40 ether);
    }

    // ============ Distribute ============

    function test_Redeem_AllShares_AfterDistribution_ReturnsPrincipalPlusReward() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        vm.roll(GENESIS_BLOCK + 10);
        _fund(bob, 50 ether);
        vm.prank(bob);
        vault.distribute(50 ether);
        vm.roll(GENESIS_BLOCK + 20);

        vm.prank(alice);
        uint256 assets = vault.redeem(200 ether, alice, alice);

        assertLe(assets, 150 ether);
        assertApproxEqRel(assets, 150 ether, REWARD_TOLERANCE);
        assertEq(vault.balanceOf(alice), 0);
    }
}
