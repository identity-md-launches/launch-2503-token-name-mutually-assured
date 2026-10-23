// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MadFixture, MadToken, MadHook, MadRewards, MadBase} from "./MadFixture.sol";
import {WalletContract} from "./mocks/MockSwarm.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Boundaries and failure paths: freeze edges, expiry, gate edges, callback authentication,
/// admin input validation, fee-rate boundaries and contract size.
contract MadEdgeCasesTest is MadFixture {
    bytes4 private constant INSUFFICIENT_BALANCE = bytes4(keccak256("InsufficientBalance()"));
    address private dave = address(0xDA7E);

    function test_freezeBeforeTradingIsClosed() public {
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.TradingClosed.selector);
        mad.freeze(bob);
    }

    function test_freezeCallerMustBeOriginWithoutCode() public {
        _enable();
        vm.prank(alice, bob);
        vm.expectRevert(MadToken.WalletOnly.selector);
        mad.freeze(carol);
        vm.etch(alice, abi.encodePacked(hex"ef0100", address(new WalletContract())));
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.WalletOnly.selector);
        mad.freeze(carol);
    }

    function test_freezeCostBoundariesZeroOneWeiAndExactBalance() public {
        _enable();
        mad.transfer(dave, 99);
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.ZeroCost.selector);
        mad.freeze(dave);
        mad.transfer(dave, 1); // 100 wei: cost 1, burns 0, credits 1
        uint256 supply = mad.totalSupply();
        vm.prank(alice, alice);
        mad.freeze(dave);
        assertEq(mad.totalSupply(), supply);
        assertEq(mad.balanceOf(dave), 101);
        assertEq(mad.spent(1, alice), 1);
        // A caller holding exactly the cost can pay it; one wei less cannot.
        address poor = address(0x9009);
        uint256 cost = mad.freezeCost(carol);
        mad.transfer(poor, cost - 1);
        vm.prank(poor, poor);
        vm.expectRevert(INSUFFICIENT_BALANCE);
        mad.freeze(carol);
        mad.transfer(poor, 1);
        vm.prank(poor, poor);
        mad.freeze(carol);
        assertEq(mad.balanceOf(poor), 0);
        // Odd cost: floor half burned, larger half credited.
        address odd = address(0x0dd);
        mad.transfer(odd, 300);
        supply = mad.totalSupply();
        vm.prank(alice, alice);
        mad.freeze(odd);
        assertEq(supply - mad.totalSupply(), 1);
        assertEq(mad.balanceOf(odd), 302);
    }

    function test_freezeTargetsEveryProtectedAddressRejected() public {
        _enable();
        WalletContract local = new WalletContract();
        WalletContract global = new WalletContract();
        address[] memory a = new address[](1);
        a[0] = address(local);
        vm.prank(OWNER);
        mad.setDistributors(a, true);
        registry.set(address(global), true);
        address[10] memory bad = [
            address(0),
            alice,
            address(manager),
            address(hook),
            address(rewards),
            address(mad),
            address(this), // factory
            OWNER,
            address(swarm),
            address(local)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice, alice);
            vm.expectRevert(MadToken.InvalidTarget.selector);
            mad.freeze(bad[i]);
        }
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.InvalidTarget.selector);
        mad.freeze(address(global));
        // An EOA marked global distributor is custody too, until the owner turns the registry off.
        registry.set(dave, true);
        mad.transfer(dave, 1000 ether);
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.InvalidTarget.selector);
        mad.freeze(dave);
        vm.prank(OWNER);
        mad.setUseGlobalDistributors(false);
        vm.prank(alice, alice);
        mad.freeze(dave);
        assertGt(mad.frozenUntil(dave), vm.getBlockTimestamp());
    }

    function test_freezeExpiresExactlyAtUntilAndRefreezeResetsNotExtends() public {
        _enable();
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(alice, alice);
        mad.freeze(bob);
        assertEq(mad.frozenUntil(bob), t0 + 24 hours);
        vm.warp(t0 + 10 hours);
        vm.prank(carol, carol);
        mad.freeze(bob);
        assertEq(mad.frozenUntil(bob), t0 + 34 hours, "reset to now+24h, not +48h");
        vm.warp(t0 + 34 hours - 1);
        vm.prank(bob, bob);
        vm.expectRevert(MadToken.SenderFrozen.selector);
        mad.transfer(alice, 1);
        vm.prank(bob, bob);
        vm.expectRevert(MadToken.SenderFrozen.selector);
        router.swap(key, _params(false, -1 ether), bob);
        vm.warp(t0 + 34 hours);
        vm.prank(bob, bob);
        mad.transfer(alice, 1);
        vm.prank(bob, bob);
        router.swap(key, _params(false, -1 ether), bob);
    }

    function test_frozenHolderStillReceivesBuysTransfersAndFreezesOthers() public {
        _mature();
        vm.prank(carol, carol);
        mad.freeze(alice);
        uint256 before = mad.balanceOf(alice);
        vm.prank(bob, bob);
        mad.transfer(alice, 5 ether);
        _swap(true, -100 ether);
        assertGt(mad.balanceOf(alice), before + 5 ether);
        vm.prank(alice, alice);
        mad.freeze(bob);
        assertGt(mad.spent(1, alice), 0);
        assertEq(mad.leader(1), carol, "carol's larger payment still leads");
        // A frozen sender cannot hand out allowance-based payments either.
        vm.prank(alice);
        mad.approve(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.SenderFrozen.selector);
        mad.transferFrom(alice, bob, 1);
    }

    function test_walletGateEdges() public {
        _enable();
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transfer(address(0), 1);
        vm.prank(alice, alice);
        mad.transfer(bob, 0);
        vm.prank(alice, alice);
        mad.transfer(alice, 1 ether);
        // A wallet that is not tx.origin (relayed call) cannot use the ordinary path.
        vm.prank(alice, bob);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transfer(carol, 1);
        // Direct sends into core contracts are rejected; they are never distributors.
        address[3] memory core = [address(hook), address(rewards), address(mad)];
        for (uint256 i; i < core.length; ++i) {
            vm.prank(alice, alice);
            vm.expectRevert(MadToken.InvalidTransfer.selector);
            mad.transfer(core[i], 1);
        }
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transfer(address(manager), 1);
    }

    function test_walletTransfersClosedBeforeTradingButFactoryAndOwnerWork() public {
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.TradingClosed.selector);
        mad.transfer(bob, 1);
        mad.transfer(dave, 1 ether);
        vm.prank(alice, alice);
        mad.transfer(OWNER, 1);
        vm.prank(OWNER, OWNER);
        mad.transfer(dave, 1);
    }

    function test_privilegedEntryPointsRejectStrangers() public {
        vm.expectRevert(MadBase.Unauthorized.selector);
        mad.accountTransferDelta(1);
        vm.expectRevert(MadBase.Unauthorized.selector);
        mad.closeRound();
        vm.expectRevert(MadBase.Unauthorized.selector);
        hook.closeRound();
        vm.expectRevert(MadBase.Unauthorized.selector);
        hook.executeNFTConversion();
        vm.expectRevert(MadHook.NotManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(MadHook.NotManager.selector);
        hook.beforeSwap(address(router), key, _params(true, -1), "");
        vm.expectRevert(MadHook.NotManager.selector);
        hook.afterSwap(address(router), key, _params(true, -1), BalanceDelta.wrap(0), "");
        vm.expectRevert(MadHook.NotManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        // The manager itself cannot replay initialization, and the token cannot be rebound.
        vm.prank(address(manager));
        vm.expectRevert(MadHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.prank(address(hook));
        vm.expectRevert(MadToken.AlreadyBound.selector);
        mad.bindHook(key, address(this));
        // Even the manager calling an unlock callback without a pending mode is refused.
        vm.prank(address(manager));
        vm.expectRevert(MadBase.Unauthorized.selector);
        hook.unlockCallback("");
    }

    function test_adminInputValidation() public {
        PoolKey memory k = PoolKey(Currency.wrap(address(0)), Currency.wrap(FWA), 0, 60, IHooks(address(0)));
        vm.expectRevert(MadBase.Unauthorized.selector);
        hook.setEthFwaPool(k);
        vm.startPrank(OWNER);
        k.currency0 = Currency.wrap(address(mad));
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.setEthFwaPool(k);
        k.currency0 = Currency.wrap(address(0));
        k.currency1 = Currency.wrap(address(mad));
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.setEthFwaPool(k);
        k.currency1 = Currency.wrap(FWA);
        k.fee = 1_000_000;
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.setEthFwaPool(k);
        k.fee = 0;
        k.tickSpacing = 0;
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.setEthFwaPool(k);
        k.tickSpacing = 60;
        k.hooks = IHooks(address(hook));
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.setEthFwaPool(k);
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.setConversionBounds(TickMath.MIN_SQRT_PRICE, 1);
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.setConversionBounds(TickMath.MAX_SQRT_PRICE, 1);
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.setConversionBounds(Q96, 0);
        address[] memory r = new address[](1);
        address[5] memory badRouters =
            [address(0), address(hook), address(manager), address(mad), address(rewards)];
        for (uint256 i; i < badRouters.length; ++i) {
            r[0] = badRouters[i];
            vm.expectRevert(MadBase.InvalidAddress.selector);
            hook.setRouters(r, true);
        }
        r[0] = dave; // no code
        vm.expectRevert(MadBase.InvalidAddress.selector);
        hook.setRouters(r, true);
        vm.expectRevert(MadRewards.InvalidSettings.selector);
        rewards.setAcquisitionBounds(0, 10_001);
        vm.expectRevert(MadBase.InvalidAddress.selector);
        rewards.setFwaV2(dave);
        vm.expectRevert(MadRewards.InvalidSettings.selector);
        rewards.setOracleSettings(address(mad), address(mad), bytes32(0), dave);
        vm.expectRevert(MadRewards.InvalidSettings.selector);
        rewards.setOracleSettings(address(mad), address(mad), bytes32("a"), address(0));
        vm.expectRevert(MadRewards.InvalidSettings.selector);
        rewards.setOracleSettings(dave, address(mad), bytes32("a"), dave);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(MadBase.Unauthorized.selector);
        mad.setUseGlobalDistributors(false);
        vm.prank(alice);
        vm.expectRevert(MadBase.Unauthorized.selector);
        mad.setDistributors(new address[](0), true);
    }

    function test_feeRateBoundariesAndQuoteRange() public {
        assertEq(hook.feeBps(), 9900);
        _enable();
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(hook.feeBps(), 9900);
        vm.warp(t0 + 1);
        assertEq(hook.feeBps(), 9900 - uint256(9800) / 1800); // floor(9800/1800) = 5
        vm.warp(t0 + 900);
        assertEq(hook.feeBps(), 5000);
        vm.warp(t0 + 1799);
        assertEq(hook.feeBps(), 106);
        vm.warp(t0 + 1800);
        assertEq(hook.feeBps(), 100);
        vm.warp(t0 + 365 days);
        assertEq(hook.feeBps(), 100);
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.quoteFee(1 ether, 99);
        vm.expectRevert(MadHook.InvalidSettings.selector);
        hook.quoteFee(1 ether, 9901);
        (uint256 fee, uint256 playground, uint256 nft, uint256 burned) = hook.quoteFee(199, 100);
        assertEq(fee, 1);
        assertEq(playground, 0);
        assertEq(nft, 1);
        assertEq(burned, 0);
    }

    function test_dustSwapsAtOnePercentCarryNoFeeButStillSettle() public {
        _mature();
        uint256 claims = hook.playgroundFwaClaims() + hook.nftFwaClaims();
        _swap(true, -99);
        _swap(false, -50);
        assertEq(hook.playgroundFwaClaims() + hook.nftFwaClaims(), claims);
        assertEq(mad.getNetTransferAllowance(), 0);
    }

    function test_oversizedSpecifiedAmountRejected() public {
        _mature();
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap(key, _params(true, -int256(uint256(uint128(type(int128).max)) + 1)), alice);
    }

    function test_payoutWithNothingOwedIsNoOpAndRepeatable() public {
        assertEq(hook.payout(), 0);
        assertEq(hook.redeemNFTBudget(), 0);
        _mature();
        _swap(true, -1000 ether);
        uint256 owed = hook.playgroundFwaClaims();
        assertEq(owed, 5 ether);
        assertEq(hook.payout(), owed);
        assertEq(hook.payout(), 0);
        assertEq(hook.playgroundFwaClaims(), 0);
    }

    function test_runtimeSizesWithinEip170() public view {
        assertLe(address(mad).code.length, 24_576);
        assertLe(address(hook).code.length, 24_576);
        assertLe(address(rewards).code.length, 24_576);
    }
}
