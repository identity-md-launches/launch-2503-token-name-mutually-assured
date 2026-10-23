// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    MadFixture,
    MadToken,
    MadHook,
    MadBase,
    SwapRouter,
    WalletContract,
    PoolKey,
    PoolId,
    IHooks,
    Currency,
    BalanceDelta,
    SwapParams,
    StateLibrary,
    IPoolManager
} from "./MadFixture.sol";
import {MockMarketHook} from "./mocks/MockMarketHook.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract MadHookTest is MadFixture {
    using StateLibrary for IPoolManager;

    function test_swapsClosedBeforeEnableAndCallbacksAuthenticated() public {
        vm.expectRevert();
        _swap(true, -100 ether);
        vm.expectRevert();
        _swap(false, -100 ether);
        vm.expectRevert(MadHook.NotManager.selector);
        hook.beforeSwap(address(router), key, _params(true, -100 ether), "");
        vm.expectRevert(MadHook.NotManager.selector);
        hook.afterSwap(address(router), key, _params(true, -100 ether), toBalanceDelta(-1, 1), "");
        vm.expectRevert(MadHook.NotManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(MadBase.Unauthorized.selector);
        hook.executeNFTConversion();
    }

    function test_feeDecayAtZero15And30MinutesAndClamp() public {
        assertEq(hook.feeBps(), 9900);
        _enable();
        uint256 start = vm.getBlockTimestamp();
        assertEq(hook.feeBps(), 9900);
        vm.warp(start + 900);
        assertEq(hook.feeBps(), 5000);
        vm.warp(start + 1800);
        assertEq(hook.feeBps(), 100);
        vm.warp(start + 100 days);
        assertEq(hook.feeBps(), 100);
        vm.warp(start - 1);
        assertEq(hook.feeBps(), 9900);
    }

    function test_fourExactModesAtAllDecayStagesConserveFees() public {
        _enable();
        uint256 start = vm.getBlockTimestamp();
        for (uint256 time; time < 3; ++time) {
            vm.warp(start + time * 900);
            _checkTrade(true, -100 ether);
            _checkTrade(true, 100 ether);
            _checkTrade(false, -100 ether);
            _checkTrade(false, 100 ether);
        }
    }

    function _checkTrade(bool buy, int256 specified) internal {
        uint256 pgBefore = hook.playgroundFwaClaims();
        uint256 nftBefore = hook.nftFwaClaims();
        uint256 burnedBefore = fwa.burned();
        uint256 fwaUserBefore = fwa.balanceOf(alice);
        uint256 madUserBefore = mad.balanceOf(alice);
        (uint256 balance0Before, uint256 balance1Before) =
            (mad.balanceOf(address(manager)), fwa.balanceOf(address(manager)));
        BalanceDelta d = _swap(buy, specified);
        int128 madDelta = mad0 ? d.amount0() : d.amount1();
        int128 fwaDelta = mad0 ? d.amount1() : d.amount0();
        uint256 pg = hook.playgroundFwaClaims() - pgBefore;
        uint256 nft = hook.nftFwaClaims() - nftBefore;
        uint256 burned = fwa.burned() - burnedBefore;
        uint256 fee = pg + nft + burned;
        uint256 gross = buy ? uint256(-int256(fwaDelta)) : uint256(uint128(fwaDelta)) + fee;
        assertEq(pg + nft, gross / 100);
        assertLe(nft - pg, 1);
        uint256 floorFee = gross * hook.feeBps() / 10_000;
        // Grossing up exact output uses ceiling; floor-based legs use floor.
        assertGe(fee, floorFee);
        assertLe(fee - floorFee, 1);
        assertEq(mad.balanceOf(alice), uint256(int256(madUserBefore) + int256(madDelta)));
        assertEq(fwa.balanceOf(alice), uint256(int256(fwaUserBefore) + int256(fwaDelta)));
        assertEq(mad.balanceOf(address(manager)), uint256(int256(balance0Before) - int256(madDelta)));
        assertEq(fwa.balanceOf(address(manager)), uint256(int256(balance1Before) - int256(fwaDelta)) - burned);
        assertEq(mad.getNetTransferAllowance(), 0);
        assertEq(fwa.balanceOf(address(hook)), 0);
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(FWA))),
            hook.playgroundFwaClaims() + hook.nftFwaClaims()
        );
        if (specified > 0) {
            assertEq(buy ? uint256(uint128(madDelta)) : uint256(uint128(fwaDelta)), uint256(specified));
        }
    }

    function test_playgroundPayoutIsDirectFwaAndNeverConvertsOrPaysTwice() public {
        _enable();
        _swap(true, -1000 ether);
        assertEq(hook.playgroundFwaClaims(), 5 ether);
        assertEq(hook.nftFwaClaims(), 5 ether);
        assertEq(fwa.burned(), 980 ether);
        uint256 received = fwa.balanceOf(hook.PLAYGROUND());
        assertEq(hook.payout(), 5 ether);
        assertEq(fwa.balanceOf(hook.PLAYGROUND()), received + 5 ether);
        assertEq(hook.payout(), 0);
        assertEq(hook.nftFwaClaims(), 5 ether);
        assertEq(address(rewards).balance, 0);
        assertEq(address(hook).balance, 0);
    }

    function test_realManagerExactInputConversionsAndSeparateBudgets() public {
        _market(1000 ether, Q96 * 2, 0.1 ether);
        _mature();
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 0);
        assertEq(hook.playgroundFwaClaims(), 5 ether);
        assertGt(address(rewards).balance, 4 ether);
        assertLt(address(rewards).balance, 5 ether);
        assertEq(fwa.burned(), 0);
        uint256 budget = address(rewards).balance;
        hook.payout();
        assertEq(address(rewards).balance, budget);
        assertEq(hook.nftEthClaims(), 0);
    }

    function test_partialConversionRetainsOnlyUnsoldNftClaimsAndRetriesNextSwap() public {
        _market(1000 ether, Q96 + Q96 / 1_000_000, 0.1 ether);
        _mature();
        _swap(true, -1000 ether);
        uint256 remaining = hook.nftFwaClaims();
        assertGt(remaining, 0);
        assertLt(remaining, 5 ether);
        assertEq(hook.playgroundFwaClaims(), 5 ether);
        uint256 budgetBefore = address(rewards).balance;
        vm.prank(OWNER);
        hook.setConversionBounds(Q96 * 2, 0.1 ether);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 0);
        assertEq(hook.playgroundFwaClaims(), 10 ether);
        assertGt(address(rewards).balance, budgetBefore + 5 ether);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(FWA))), 10 ether);
    }

    function test_conversionFailureAndUnsetBoundsDoNotBlockSwapOrPayout() public {
        _mature();
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 5 ether);
        _market(1000 ether, Q96 * 2, 2 ether); // impossible minimum output, atomic rollback
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 10 ether);
        assertEq(address(rewards).balance, 0);
        hook.payout();
        assertEq(hook.playgroundFwaClaims(), 0);
    }

    function test_nativeClaimsRedeemPartiallyAndOnlyFundNftBudget() public {
        _market(1000 ether, Q96 * 2, 0.1 ether);
        // Enough for the market's ~0.05 ETH fee, but not for the NFT proceeds.
        vm.deal(address(manager), 0.1 ether);
        _mature();
        _swap(true, -1000 ether);
        uint256 claims = hook.nftEthClaims();
        assertGt(claims, 4 ether);
        assertGt(address(0xFEE).balance, 0);
        assertEq(address(rewards).balance, 0);
        vm.deal(address(manager), 0);
        assertEq(hook.redeemNFTBudget(), 0);
        vm.deal(address(manager), claims / 2);
        assertEq(hook.redeemNFTBudget(), claims / 2);
        assertEq(hook.nftEthClaims(), claims - claims / 2);
        vm.deal(address(manager), claims);
        hook.redeemNFTBudget();
        assertEq(address(rewards).balance, claims);
        assertEq(hook.nftEthClaims(), 0);
        assertEq(hook.redeemNFTBudget(), 0);
        assertEq(hook.playgroundFwaClaims(), 5 ether);
    }

    function test_marketWithNoPhysicalEthDefersConversionWithoutBlockingFwaPayout() public {
        _market(1000 ether, Q96 * 2, 0.1 ether);
        vm.deal(address(manager), 0);
        _mature();
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 5 ether);
        assertEq(hook.nftEthClaims(), 0);
        assertEq(address(rewards).balance, 0);
        assertEq(hook.payout(), 5 ether);
        assertEq(fwa.balanceOf(hook.PLAYGROUND()), 5 ether);
        vm.deal(address(manager), 100 ether);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 0);
        assertGt(address(rewards).balance, 9 ether);
        assertEq(hook.playgroundFwaClaims(), 5 ether);
    }

    function test_signedNetCancelsOppositeSwapsInSameUnlockAndResetsAfterSettlement() public {
        _mature();
        SwapParams[] memory ps = new SwapParams[](2);
        ps[0] = _params(true, 100 ether); // buy exactly 100 MAD
        ps[1] = _params(false, -100 ether); // sell exactly 100 MAD; no MAD token transfer
        uint256 balance = mad.balanceOf(alice);
        vm.prank(alice, alice);
        router.multi(key, ps, alice);
        assertEq(mad.balanceOf(alice), balance);
        assertEq(mad.getNetTransferAllowance(), 0);
        _swap(true, 100 ether);
        assertEq(mad.getNetTransferAllowance(), 0);
        _swap(false, -100 ether);
        assertEq(mad.getNetTransferAllowance(), 0);
    }

    function test_signedNetOnlyConsumesTowardZeroAndExemptionsCannotBypass() public {
        _enable();
        this.nettingInOneCall();
    }

    function nettingInOneCall() external {
        require(msg.sender == address(this));
        vm.prank(address(hook));
        mad.accountTransferDelta(20);
        vm.prank(address(hook));
        mad.accountTransferDelta(-15);
        assertEq(mad.getNetTransferAllowance(), 5);
        vm.prank(address(manager));
        mad.transfer(alice, 3);
        assertEq(mad.getNetTransferAllowance(), 2);
        vm.prank(address(manager));
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transfer(OWNER, 3);
        vm.prank(address(manager));
        mad.transfer(OWNER, 2);
        vm.prank(address(manager));
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transfer(OWNER, 1);
        vm.prank(address(hook));
        mad.accountTransferDelta(-10);
        vm.prank(alice, alice);
        mad.transfer(address(manager), 10);
        assertEq(mad.getNetTransferAllowance(), 0);
        registry.set(alice, true);
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transfer(address(manager), 1);
    }

    function test_frozenSellerRejectedBeforePermit2LikeSettlement() public {
        _mature();
        vm.prank(bob, bob);
        mad.freeze(alice);
        uint256 oldBurn = fwa.burned();
        uint256 oldClaims = hook.playgroundFwaClaims();
        vm.expectRevert();
        _swap(false, -100 ether);
        assertEq(hook.playgroundFwaClaims(), oldClaims);
        assertEq(fwa.burned(), oldBurn);
        _swap(true, -100 ether); // receiving is allowed
    }

    function test_unapprovedBuyIncludingMad6909PayoutRejectedButSellClaimsAllowed() public {
        _mature();
        SwapRouter bad = new SwapRouter(manager);
        vm.startPrank(alice, alice);
        mad.approve(address(bad), type(uint256).max);
        fwa.approve(address(bad), type(uint256).max);
        vm.expectRevert();
        bad.swapClaims(key, _params(true, -100 ether));
        bad.swapClaims(key, _params(false, -100 ether));
        assertGt(manager.balanceOf(alice, uint256(uint160(FWA))), 0);
        assertEq(manager.balanceOf(alice, uint256(uint160(address(mad)))), 0);
        vm.stopPrank();
    }

    function test_poolManagerCannotPayNonexemptContractAndBadPoolHasNoAllowance() public {
        _mature();
        WalletContract sink = new WalletContract();
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap(key, _params(true, -100 ether), address(sink));
        address[] memory a = new address[](1);
        a[0] = address(sink);
        vm.prank(OWNER);
        mad.setDistributors(a, true);
        vm.prank(alice, alice);
        router.swap(key, _params(true, -100 ether), address(sink));
        assertGt(mad.balanceOf(address(sink)), 0);
        PoolKey memory other = key;
        other.hooks = IHooks(address(0));
        manager.initialize(other, Q96);
        _modify(other, 1_000_000 ether);
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap(other, _params(true, -100 ether), OWNER);
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap(other, _params(false, -100 ether), alice);
        vm.prank(address(manager));
        vm.expectRevert(MadHook.WrongPool.selector);
        hook.beforeSwap(address(router), other, _params(true, -100 ether), "");
    }

    function test_factoryCanCollectWithFeesLiveAndBeforeEnable() public {
        _modify(key, 0);
        _mature();
        _swap(true, -1000 ether);
        _swap(false, -1000 ether);
        BalanceDelta d = _modify(key, 0);
        assertGe(d.amount0(), 0);
        assertGe(d.amount1(), 0);
        assertTrue(d.amount0() > 0 || d.amount1() > 0);
    }

    function testFuzz_feeSplitConservation(uint128 gross_, uint16 rate_) public view {
        uint256 gross = uint256(gross_);
        uint16 rate = uint16(bound(rate_, 100, 9900));
        (uint256 fee, uint256 pg, uint256 nft, uint256 burn) = hook.quoteFee(gross, rate);
        assertEq(fee, gross * rate / 10_000);
        assertEq(pg + nft, gross / 100);
        assertEq(pg + nft + burn, fee);
        assertLe(nft - pg, 1);
    }

    function testFuzz_realPoolModesAndDecay(uint96 amount_, uint16 elapsed_, bool buy, bool exactInput)
        public
    {
        uint256 amount = bound(uint256(amount_), 100, 1000 ether);
        _enable();
        vm.warp(vm.getBlockTimestamp() + bound(elapsed_, 0, 2000));
        _checkTrade(buy, exactInput ? -int256(amount) : int256(amount));
    }

    function test_partialSpecifiedFwaFillRevertsWithoutAnyFee() public {
        _mature();
        (uint160 price,,,) = manager.getSlot0(key.toId());
        SwapParams memory p = _params(true, -100_000 ether);
        p.sqrtPriceLimitX96 = p.zeroForOne ? price - 1 : price + 1;
        uint256 before = fwa.balanceOf(alice);
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap(key, p, alice);
        assertEq(fwa.balanceOf(alice), before);
        assertEq(hook.playgroundFwaClaims(), 0);
        assertEq(hook.nftFwaClaims(), 0);
    }

    function _market(uint256 liquidity, uint160 limit, uint256 minRate) internal {
        address market = address(0x100c4);
        vm.etch(market, address(new MockMarketHook(manager)).code);
        PoolKey memory k = PoolKey(Currency.wrap(address(0)), Currency.wrap(FWA), 0, 60, IHooks(market));
        manager.initialize(k, Q96);
        vm.deal(address(this), liquidity * 2);
        _modify(k, int256(liquidity));
        vm.startPrank(OWNER);
        hook.setEthFwaPool(k);
        hook.setConversionBounds(limit, minRate);
        vm.stopPrank();
    }
}

/// @dev Repeat the integration suite with MAD as currency1 to cover every sign/orientation combination.
contract MadHookCurrency1Test is MadHookTest {
    function _newMadToken() internal override returns (MadToken result) {
        do {
            result = new MadToken();
        } while (address(result) < FWA);
    }
}
