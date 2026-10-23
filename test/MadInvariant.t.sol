// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MadFixture, MadToken, MadHook, MadRewards} from "./MadFixture.sol";
import {MockFWA} from "./mocks/MockERC20.sol";
import {SwapRouter} from "./mocks/SwapRouter.sol";
import {MockSwarm} from "./mocks/MockSwarm.sol";
import {MockFwaV2} from "./mocks/MockServices.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Drives swaps in all four exact modes, freezes, wallet transfers, payouts and time through the
/// real PoolManager, and keeps independent ghost accounting of what each call must have moved.
contract SwapFreezeHandler is Test {
    bytes32 private constant FEES_SIG = keccak256("Fees(uint256,uint256,uint256,uint256,uint256)");
    address private constant PLAYGROUND = 0x04454514ad6dc4C01d7064C308F8853183FDD39C;

    MadToken internal mad;
    MadHook internal hook;
    MockFWA internal fwa;
    SwapRouter internal router;
    PoolKey internal key;
    bool internal mad0;
    address[3] internal actors;

    uint256 public ghostMadBurned;
    uint256 public ghostPlayground;
    uint256 public ghostNft;
    uint256 public ghostFwaBurned;
    uint256 public ghostPlaygroundPaid;
    uint256 public swaps;
    uint256 public freezes;
    uint256 public payouts;
    // Independent first-to-total leader tracking for the current round.
    mapping(uint256 => mapping(address => uint256)) public ghostSpent;
    mapping(uint256 => address) public ghostLeader;

    constructor(
        MadToken mad_,
        MadHook hook_,
        MockFWA fwa_,
        SwapRouter router_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        mad = mad_;
        hook = hook_;
        fwa = fwa_;
        router = router_;
        key = key_;
        mad0 = Currency.unwrap(key_.currency0) == address(mad_);
        actors = actors_;
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % 3];
    }

    function swap(uint256 actorSeed, uint256 amountSeed, bool buy, bool exactInput) external {
        address who = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1, 20_000 ether);
        uint16 rate = hook.feeBps();
        bool zeroForOne = buy ? !mad0 : mad0;
        SwapParams memory p = SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 fwaBefore = fwa.balanceOf(who);
        uint256 madBefore = mad.balanceOf(who);
        uint256 fwaSupply = fwa.totalSupply();
        vm.recordLogs();
        vm.prank(who, who);
        try router.swap(key, p, who) {}
        catch {
            vm.getRecordedLogs();
            return;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 base, uint256 total, uint256 playground, uint256 nft, uint256 burned) = _fees(logs);
        uint256 fwaAfter = fwa.balanceOf(who);
        uint256 madAfter = mad.balanceOf(who);
        // Split rules, independent of the hook's own arithmetic.
        assertEq(playground + nft, base / 100, "permanent is 1% of base");
        assertEq(playground, base / 200, "playground half floors");
        assertEq(playground + nft + burned, total, "fee fully allocated");
        assertEq(fwaSupply - fwa.totalSupply(), burned, "excess physically burned");
        uint256 D = 10_000;
        if (buy) {
            assertEq(madAfter >= madBefore, true, "buy never costs MAD");
            uint256 paid = fwaBefore - fwaAfter;
            if (exactInput) {
                assertEq(paid, amount, "exact-in buy pays exactly specified");
                assertEq(base, amount, "exact-in buy base is gross input");
                assertEq(total, amount * rate / D, "exact-in buy fee floors");
            } else {
                assertEq(madAfter - madBefore, amount, "exact-out buy receives exact MAD");
                assertEq(paid, base, "exact-out buy pays gross base");
                uint256 net = base - total;
                assertEq(base, (net * D + (D - rate) - 1) / (D - rate), "exact-out gross rounds up");
            }
        } else {
            assertEq(madAfter <= madBefore, true, "sell never pays MAD out");
            uint256 got = fwaAfter - fwaBefore;
            if (exactInput) {
                assertEq(madBefore - madAfter, amount, "exact-in sell spends specified MAD");
                assertEq(total, base * rate / D, "exact-in sell fee floors");
                assertEq(got, base - total, "seller receives net");
            } else {
                assertEq(got, amount, "exact-out sell receives exact FWA");
                assertEq(base, (amount * D + (D - rate) - 1) / (D - rate), "exact-out sell gross rounds up");
                assertEq(total, base - amount, "exact-out sell fee is gross-up");
            }
        }
        ghostPlayground += playground;
        ghostNft += nft;
        ghostFwaBurned += burned;
        ++swaps;
    }

    function _fees(Vm.Log[] memory logs)
        private
        view
        returns (uint256 base, uint256 total, uint256 playground, uint256 nft, uint256 burned)
    {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEES_SIG) {
                (base, total, playground, nft, burned) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                ++found;
            }
        }
        assertEq(found, 1, "exactly one fee event per swap");
    }

    function freeze(uint256 callerSeed, uint256 targetSeed) external {
        address by = _actor(callerSeed);
        address target = _actor(targetSeed);
        uint256 cost = mad.balanceOf(target) / 100;
        uint256 round = mad.currentRound();
        uint256 supply = mad.totalSupply();
        uint256 byBefore = mad.balanceOf(by);
        uint256 targetBefore = mad.balanceOf(target);
        (uint64 first,) = mad.roundBlocks(round);
        bool expectOk = by != target && cost != 0 && byBefore >= cost && vm.getBlockNumber() >= first;
        vm.prank(by, by);
        try mad.freeze(target) {
            assertTrue(expectOk, "freeze succeeded where it must fail");
        } catch {
            assertFalse(expectOk, "freeze failed where it must succeed");
            return;
        }
        assertEq(supply - mad.totalSupply(), cost / 2, "burns floor half");
        assertEq(byBefore - mad.balanceOf(by), cost, "caller pays full cost");
        assertEq(mad.balanceOf(target) - targetBefore, cost - cost / 2, "target credited remainder");
        assertEq(mad.frozenUntil(target), vm.getBlockTimestamp() + 24 hours, "freeze resets to now+24h");
        ghostMadBurned += cost / 2;
        uint256 t = ghostSpent[round][by] + cost;
        ghostSpent[round][by] = t;
        if (t > ghostSpent[round][ghostLeader[round]]) ghostLeader[round] = by;
        ++freezes;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, mad.balanceOf(from));
        bool frozen = mad.frozenUntil(from) > vm.getBlockTimestamp();
        vm.prank(from, from);
        try mad.transfer(to, amount) {
            assertFalse(frozen, "frozen sender moved MAD");
        } catch {
            assertTrue(frozen, "unfrozen wallet transfer failed");
        }
    }

    function payout() external {
        uint256 before = fwa.balanceOf(PLAYGROUND);
        uint256 paid = hook.payout();
        assertEq(fwa.balanceOf(PLAYGROUND) - before, paid, "payout moves exactly what it reports");
        ghostPlaygroundPaid += paid;
        ++payouts;
    }

    function wait(uint256 secondsSeed, uint256 blocksSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 30 hours));
        vm.roll(vm.getBlockNumber() + bound(blocksSeed, 1, 50));
    }
}

contract MadSwapFreezeInvariantTest is MadFixture {
    address private constant PLAYGROUND = 0x04454514ad6dc4C01d7064C308F8853183FDD39C;
    SwapFreezeHandler private handler;
    uint256 private fwaSupplyStart;

    function setUp() public override {
        super.setUp();
        fwa.mint(carol, 1_000_000 ether);
        vm.startPrank(carol, carol);
        mad.approve(address(router), type(uint256).max);
        fwa.approve(address(router), type(uint256).max);
        vm.stopPrank();
        _enable();
        handler = new SwapFreezeHandler(mad, hook, fwa, router, key, [alice, bob, carol]);
        fwaSupplyStart = fwa.totalSupply();
        targetContract(address(handler));
    }

    /// @dev Non-vacuity: every handler path can succeed and the invariants hold after it.
    function test_handlerPathsAreLive() public {
        handler.swap(0, 1000 ether, true, true);
        handler.swap(1, 10 ether, true, false);
        handler.swap(0, 500 ether, false, true);
        handler.swap(1, 5 ether, false, false);
        assertEq(handler.swaps(), 4);
        handler.freeze(0, 1);
        handler.freeze(2, 1);
        assertEq(handler.freezes(), 2);
        handler.transfer(1, 0, 1 ether); // frozen bob: must revert inside the handler
        handler.transfer(0, 2, 1 ether);
        handler.payout();
        assertGt(handler.ghostPlaygroundPaid(), 0);
        handler.wait(2000, 10);
        handler.swap(2, 100 ether, true, true);
        invariant_madSupplyOnlyFallsByFreezeBurns();
        invariant_madLivesOnlyInKnownAccounts();
        invariant_hookClaimsEqualOwedRevenue();
        invariant_fwaBurnMatchesExcessFees();
        invariant_leaderIsFirstToHighestTotal();
        // Carol paid more: bob's balance grew by alice's credited half before carol froze him.
        assertGt(mad.spent(1, carol), mad.spent(1, alice));
        assertEq(mad.leader(1), carol);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_madSupplyOnlyFallsByFreezeBurns() public view {
        assertEq(mad.totalSupply() + handler.ghostMadBurned(), mad.INITIAL_SUPPLY());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_madLivesOnlyInKnownAccounts() public view {
        uint256 sum = mad.balanceOf(alice) + mad.balanceOf(bob) + mad.balanceOf(carol)
            + mad.balanceOf(address(this)) + mad.balanceOf(address(swarm)) + mad.balanceOf(address(manager));
        assertEq(sum, mad.totalSupply());
        assertEq(mad.balanceOf(address(hook)), 0);
        assertEq(mad.balanceOf(address(rewards)), 0);
        assertEq(mad.balanceOf(address(router)), 0);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_hookClaimsEqualOwedRevenue() public view {
        uint256 fwaId = uint256(uint160(FWA));
        assertEq(manager.balanceOf(address(hook), fwaId), hook.playgroundFwaClaims() + hook.nftFwaClaims());
        assertEq(manager.balanceOf(address(hook), 0), hook.nftEthClaims());
        assertEq(hook.nftFwaClaims(), handler.ghostNft(), "no conversion configured: NFT claims wait");
        assertEq(
            fwa.balanceOf(PLAYGROUND) + hook.playgroundFwaClaims(),
            handler.ghostPlayground(),
            "playground paid + owed == accrued"
        );
        assertEq(fwa.balanceOf(PLAYGROUND), handler.ghostPlaygroundPaid());
        assertEq(fwa.balanceOf(address(hook)), 0, "hook keeps no physical FWA");
        assertEq(address(rewards).balance, 0, "no ETH without conversion");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_fwaBurnMatchesExcessFees() public view {
        assertEq(hook.totalBurned(), handler.ghostFwaBurned());
        assertEq(fwaSupplyStart - fwa.totalSupply(), handler.ghostFwaBurned());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_leaderIsFirstToHighestTotal() public view {
        uint256 round = mad.currentRound();
        assertEq(mad.leader(round), handler.ghostLeader(round));
        for (uint256 i; i < 3; ++i) {
            address a = handler.actor(i);
            assertEq(mad.spent(round, a), handler.ghostSpent(round, a));
            assertLe(mad.spent(round, a), mad.spent(round, mad.leader(round)));
            assertLe(mad.frozenUntil(a), vm.getBlockTimestamp() + 24 hours);
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_tradingIrreversibleAndRoundsOnlyCloseViaRewards() public view {
        assertTrue(mad.trading());
        assertEq(mad.currentRound(), 1, "no path but rewards closes a round");
    }
}

/// @dev Drives the NFT budget and prize lifecycle with random ordering: funding, purchases,
/// fulfilment, claims (in and out of window), refunds, freezes, round closing and awards.
contract RewardsHandler is Test {
    MadToken internal mad;
    MadRewards internal rewards;
    MockFwaV2 internal source;
    IPoolManager internal manager;
    address[3] internal actors;

    uint256 public ghostIn;
    uint256 public ghostSpent;
    uint256 public ghostRefunded;
    uint256[] internal requestIds;
    uint256 public closedRounds;
    mapping(uint256 => address) public fixedBeneficiary;
    mapping(uint256 => bool) public everAwarded;
    uint256 public awards;
    uint256 public claims;

    constructor(
        MadToken mad_,
        MadRewards rewards_,
        MockFwaV2 source_,
        IPoolManager manager_,
        address[3] memory a
    ) {
        mad = mad_;
        rewards = rewards_;
        source = source_;
        manager = manager_;
        actors = a;
    }

    function fund(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 5 ether);
        vm.deal(address(manager), address(manager).balance + amount);
        vm.prank(address(manager));
        (bool ok,) = address(rewards).call{value: amount}("");
        assertTrue(ok);
        ghostIn += amount;
    }

    function buy(uint256 feeSeed) external {
        source.setFee(bound(feeSeed, 0, 2 ether));
        uint256 before = address(rewards).balance;
        try rewards.buy() returns (uint256 id) {
            requestIds.push(id);
            ghostSpent += before - address(rewards).balance;
            assertEq(before - address(rewards).balance, source.fee() + source.vrf(), "pays quote exactly");
        } catch {
            assertEq(address(rewards).balance, before);
        }
    }

    function fulfill(uint256 seed) external {
        if (requestIds.length == 0) return;
        try source.fulfill(requestIds[seed % requestIds.length]) {} catch {}
    }

    function refund(uint256 seed) external {
        if (requestIds.length == 0) return;
        try source.refund(requestIds[seed % requestIds.length]) {} catch {}
    }

    function recover() external {
        uint256 before = address(rewards).balance;
        rewards.recoverRefund(address(source));
        ghostRefunded += address(rewards).balance - before;
    }

    function claim(uint256 seed) external {
        if (requestIds.length == 0) return;
        uint256 before = rewards.prizeCount();
        try rewards.claim(requestIds[seed % requestIds.length]) {
            assertEq(rewards.prizeCount(), before + 1);
            ++claims;
        } catch {
            assertEq(rewards.prizeCount(), before);
        }
    }

    function freeze(uint256 callerSeed, uint256 targetSeed) external {
        address by = actors[callerSeed % 3];
        address target = actors[targetSeed % 3];
        vm.prank(by, by);
        try mad.freeze(target) {} catch {}
    }

    function wait(uint256 secondsSeed, uint256 blocksSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 40 hours));
        vm.roll(vm.getBlockNumber() + bound(blocksSeed, 1, 4000));
    }

    function close() external {
        try rewards.closeRound() returns (uint256 round) {
            ++closedRounds;
            assertEq(round, closedRounds);
        } catch {}
    }

    function award(uint256 seed) external {
        if (closedRounds == 0) return;
        uint256 round = seed % closedRounds + 1;
        try rewards.award(round) returns (bool delivered) {
            (,,,,,,, address beneficiary,,) = rewards.rounds(round);
            if (fixedBeneficiary[round] != address(0)) {
                assertEq(beneficiary, fixedBeneficiary[round], "beneficiary changed");
            }
            fixedBeneficiary[round] = beneficiary;
            if (delivered) {
                assertFalse(everAwarded[round], "double award");
                everAwarded[round] = true;
                ++awards;
            }
        } catch {}
    }
}

contract MadRewardsInvariantTest is MadFixture {
    RewardsHandler private handler;
    MockFwaV2 private source;

    function setUp() public override {
        super.setUp();
        source = new MockFwaV2();
        vm.prank(OWNER);
        rewards.setFwaV2(address(source));
        _mature();
        handler = new RewardsHandler(mad, rewards, source, manager, [alice, bob, carol]);
        targetContract(address(handler));
    }

    /// @dev Non-vacuity: a full buy, claim, close and fallback award runs through the handler.
    function test_handlerPathsAreLive() public {
        handler.fund(3 ether);
        handler.buy(1 ether);
        handler.buy(1 ether);
        handler.fulfill(0);
        handler.claim(0);
        handler.claim(0); // duplicate claim must fail inside the handler
        handler.refund(1);
        handler.recover();
        assertEq(handler.ghostRefunded(), 1 ether);
        handler.freeze(0, 1);
        handler.wait(1, 4000);
        handler.wait(1, 4000);
        handler.close();
        assertEq(handler.closedRounds(), 1);
        handler.award(0); // before the 72h fallback: nothing to award
        assertEq(handler.awards(), 0);
        handler.wait(40 hours, 1);
        handler.wait(40 hours, 1);
        handler.award(0);
        handler.award(0);
        assertEq(handler.awards(), 1);
        invariant_budgetIsExactlyInflowsLessPurchasesPlusRefunds();
        invariant_prizesHeldUntilAwardedAndNeverReassigned();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_budgetIsExactlyInflowsLessPurchasesPlusRefunds() public view {
        assertEq(address(rewards).balance, handler.ghostIn() - handler.ghostSpent() + handler.ghostRefunded());
        assertLe(handler.ghostRefunded(), handler.ghostSpent());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_prizesHeldUntilAwardedAndNeverReassigned() public view {
        uint256 next = rewards.nextPrize();
        uint256 count = rewards.prizeCount();
        assertLe(next, count);
        assertEq(next, handler.closedRounds(), "one prize per closed round");
        for (uint256 i; i < count; ++i) {
            (address collection, uint256 tokenId) = rewards.keptNFTs(i);
            assertEq(collection, address(source.nft()));
            if (i >= next) assertEq(source.nft().ownerOf(tokenId), address(rewards), "queued prize held");
        }
        for (uint256 round = 1; round <= handler.closedRounds(); ++round) {
            (,,, address leader, address collection, uint256 tokenId,, address beneficiary, bool awarded,) =
                rewards.rounds(round);
            (address queued, uint256 queuedId) = rewards.keptNFTs(round - 1);
            assertEq(collection, queued, "round prize is FIFO");
            assertEq(tokenId, queuedId, "round prize is FIFO");
            assertTrue(leader != address(0));
            address owner = source.nft().ownerOf(tokenId);
            if (awarded) {
                assertEq(owner, beneficiary, "awarded prize reached beneficiary");
                assertTrue(handler.everAwarded(round));
            } else {
                assertEq(owner, address(rewards), "unawarded prize held");
            }
        }
        assertEq(mad.currentRound(), handler.closedRounds() + 1);
    }
}
