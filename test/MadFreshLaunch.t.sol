// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {MadToken} from "../src/MadToken.sol";
import {MadHook} from "../src/MadHook.sol";
import {MockFWA} from "./mocks/MockERC20.sol";
import {SwapRouter} from "./mocks/SwapRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A launch factory that, like the IMD factory, deploys MAD and the hook, initializes the pool
/// and seeds it in ONE call, with MAD only: the manager holds no FWA when trading opens.
contract TokenOnlyFactory {
    address internal constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    IPoolManager internal immutable manager;
    MadToken public mad;
    MadHook public hook;
    bool public mad0;
    PoolKey internal key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    function launch(int256 liquidity) external {
        mad = new MadToken();
        bytes memory creation =
            abi.encodePacked(type(MadHook).creationCode, abi.encode(manager, mad, address(this)));
        bytes32 codeHash = keccak256(creation);
        for (uint256 i;; ++i) {
            address predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), codeHash)))
                )
            );
            if (uint160(predicted) & 0x3fff != 0x20cc) continue;
            bytes32 salt = bytes32(i);
            address deployed;
            assembly ("memory-safe") { deployed := create2(0, add(creation, 32), mload(creation), salt) }
            require(deployed != address(0), "hook deploy");
            hook = MadHook(deployed);
            break;
        }
        mad0 = address(mad) < FWA;
        key = PoolKey(
            Currency.wrap(mad0 ? address(mad) : FWA),
            Currency.wrap(mad0 ? FWA : address(mad)),
            12500,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, Q96);
        // Single-sided MAD: a range the price only enters as MAD is bought.
        (int24 lo, int24 hi) = mad0 ? (int24(60), int24(887220)) : (int24(-887220), int24(-60));
        manager.unlock(abi.encode(lo, hi, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (int24 lo, int24 hi, int256 liquidity) = abi.decode(data, (int24, int24, int256));
        (BalanceDelta d,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, liquidity, 0), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 delta) private {
        if (delta < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(c, address(this), uint256(uint128(delta)));
        }
    }

    function give(address to, uint256 amount) external {
        mad.transfer(to, amount);
    }
}

abstract contract FreshLaunchBase is Test {
    address internal constant OWNER = 0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774;
    address internal constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant PLAYGROUND = 0x04454514ad6dc4C01d7064C308F8853183FDD39C;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    IPoolManager internal manager;
    MockFWA internal fwa;
    TokenOnlyFactory internal factory;
    MadToken internal mad;
    MadHook internal hook;
    SwapRouter internal router;
    PoolKey internal key;
    bool internal mad0;
    uint256 internal fwaId = uint256(uint160(FWA));

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(25_000_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.etch(FWA, address(new MockFWA()).code);
        fwa = MockFWA(FWA);
        fwa.setManager(address(manager));
        factory = new TokenOnlyFactory(manager);
        factory.launch(500_000_000 ether);
        mad = factory.mad();
        hook = factory.hook();
        key = factory.poolKey();
        mad0 = factory.mad0();
        router = new SwapRouter(manager);
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        vm.prank(OWNER);
        hook.setRouters(routers, true);
        address[2] memory people = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            fwa.mint(people[i], 50_000_000 ether);
            factory.give(people[i], 10_000_000 ether);
            vm.startPrank(people[i], people[i]);
            fwa.approve(address(router), type(uint256).max);
            mad.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _params(bool buy, int256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = buy ? !mad0 : mad0;
        return SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _enable() internal {
        vm.prank(OWNER);
        mad.enableTrading();
    }
}

/// @dev The IMD launch seeds its pool with MAD only, so during the 99% decay the first buys owe far
/// more excess fee than the manager holds when afterSwap runs. These pin the deferred-burn fix.
contract MadFreshLaunchTest is FreshLaunchBase {
    event BurnDeferred(uint256 fwaAmount);
    event ExcessBurned(uint256 fwaAmount);

    function test_poolHoldsNoFwaAtLaunch() public view {
        assertEq(fwa.balanceOf(address(manager)), 0, "token-only seed");
        assertGt(mad.balanceOf(address(manager)), 0, "MAD seeded");
        assertEq(
            mad.balanceOf(address(manager)) + mad.balanceOf(address(factory)) + 20_000_000 ether,
            mad.totalSupply()
        );
    }

    function test_firstExactInBuyAtNinetyNinePercentDefersAllExcessThenBurnExcessFlushes() public {
        _enable();
        assertEq(hook.feeBps(), 9900);
        vm.expectEmit(address(hook));
        emit BurnDeferred(980 ether);
        vm.prank(alice, alice);
        router.swap(key, _params(true, -1000 ether), alice);
        assertEq(hook.totalBurned(), 980 ether, "excess committed");
        assertEq(hook.pendingBurnClaims(), 980 ether, "nothing physical to burn inside the swap");
        assertEq(fwa.burned(), 0);
        assertEq(hook.playgroundFwaClaims(), 5 ether);
        assertEq(hook.nftFwaClaims(), 5 ether);
        assertEq(manager.balanceOf(address(hook), fwaId), 990 ether, "deferred excess is a claim");
        assertEq(fwa.balanceOf(address(manager)), 1000 ether, "buyer settled after afterSwap");

        // Anyone flushes it once settled, and only the pending part burns.
        vm.expectEmit(address(hook));
        emit ExcessBurned(980 ether);
        vm.prank(bob);
        assertEq(hook.burnExcess(), 980 ether);
        assertEq(hook.pendingBurnClaims(), 0);
        assertEq(fwa.burned(), 980 ether);
        assertEq(hook.totalBurned(), fwa.burned());
        assertEq(manager.balanceOf(address(hook), fwaId), 10 ether);
        assertEq(hook.burnExcess(), 0, "second flush is a no-op");
        assertEq(hook.payout(), 5 ether, "revenue untouched by the flush");
        assertEq(fwa.balanceOf(PLAYGROUND), 5 ether);
    }

    function test_firstExactOutBuyDefersAndNextSwapFlushesBacklog() public {
        _enable();
        uint256 fwaBefore = fwa.balanceOf(alice);
        vm.prank(alice, alice);
        router.swap(key, _params(true, 10 ether), alice);
        uint256 paid = fwaBefore - fwa.balanceOf(alice);
        assertGt(paid, 0);
        uint256 excess = hook.totalBurned();
        assertEq(hook.pendingBurnClaims(), excess, "all of it deferred");
        assertEq(paid / 100, hook.playgroundFwaClaims() + hook.nftFwaClaims(), "1% of gross base");
        // A later swap burns its own excess plus as much backlog as the settled float covers
        // (its own input is not settled yet), and burnExcess clears the rest.
        uint256 float = fwa.balanceOf(address(manager));
        vm.prank(bob, bob);
        router.swap(key, _params(true, -1000 ether), bob);
        assertEq(fwa.burned(), float, "the whole float burned inside the swap");
        assertEq(hook.pendingBurnClaims(), hook.totalBurned() - float);
        assertLt(hook.pendingBurnClaims(), excess, "backlog shrank");
        assertEq(hook.burnExcess(), hook.totalBurned() - float);
        assertEq(hook.pendingBurnClaims(), 0);
        assertEq(fwa.burned(), hook.totalBurned());
        assertEq(manager.balanceOf(address(hook), fwaId), hook.playgroundFwaClaims() + hook.nftFwaClaims());
    }

    function test_severalBuysInOneUnlockAccumulateDeferral() public {
        _enable();
        SwapParams[] memory ps = new SwapParams[](3);
        ps[0] = _params(true, -1000 ether);
        ps[1] = _params(true, -2000 ether);
        ps[2] = _params(true, 5 ether);
        vm.prank(alice, alice);
        router.multi(key, ps, alice);
        assertEq(fwa.burned(), 0, "the manager had no float during the whole unlock");
        assertEq(hook.pendingBurnClaims(), hook.totalBurned());
        assertEq(
            manager.balanceOf(address(hook), fwaId),
            hook.playgroundFwaClaims() + hook.nftFwaClaims() + hook.pendingBurnClaims()
        );
        assertGe(fwa.balanceOf(address(manager)), manager.balanceOf(address(hook), fwaId), "claims backed");
        uint256 pending = hook.pendingBurnClaims();
        assertEq(hook.burnExcess(), pending);
        assertEq(fwa.burned(), hook.totalBurned());
    }

    function test_sellAfterDeferredBuyBurnsBacklogFromFloat() public {
        _enable();
        vm.prank(alice, alice);
        router.swap(key, _params(true, -100_000 ether), alice);
        assertGt(hook.pendingBurnClaims(), 0);
        vm.prank(alice, alice);
        router.swap(key, _params(false, -1000 ether), alice);
        assertEq(hook.pendingBurnClaims(), 0, "sell's collection flushes backlog");
        assertEq(fwa.burned(), hook.totalBurned());
    }

    function test_afterDecayNoExcessSoOnlyBurnExcessFlushes() public {
        _enable();
        vm.prank(alice, alice);
        router.swap(key, _params(true, -1000 ether), alice);
        uint256 pending = hook.pendingBurnClaims();
        vm.warp(vm.getBlockTimestamp() + 1800);
        assertEq(hook.feeBps(), 100);
        vm.prank(bob, bob);
        router.swap(key, _params(true, -1000 ether), bob);
        assertEq(hook.pendingBurnClaims(), pending, "a 1% swap has no excess to collect with");
        assertEq(hook.burnExcess(), pending);
        assertEq(fwa.burned(), hook.totalBurned());
    }

    function test_burnExcessBeforeTradingIsHarmlessNoOp() public {
        assertEq(hook.burnExcess(), 0);
        assertEq(fwa.burned(), 0);
    }

    function test_unlockCallbackCannotBeDrivenDirectly() public {
        vm.expectRevert();
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(); // no pending mode
        hook.unlockCallback("");
    }
}

/// @dev Random buys, sells, flushes, payouts and time on a token-only-seeded launch.
contract FreshLaunchHandler is Test {
    bytes32 private constant FEES_SIG = keccak256("Fees(uint256,uint256,uint256,uint256,uint256)");
    address private constant PLAYGROUND = 0x04454514ad6dc4C01d7064C308F8853183FDD39C;
    MadHook internal hook;
    MockFWA internal fwa;
    SwapRouter internal router;
    IPoolManager internal manager;
    PoolKey internal key;
    bool internal mad0;
    address[2] internal actors;

    uint256 public ghostExcess;
    uint256 public ghostPlayground;
    uint256 public ghostPaid;
    uint256 public swaps;
    uint256 public deferrals;
    uint256 public flushes;

    constructor(
        MadHook hook_,
        MockFWA fwa_,
        SwapRouter router_,
        IPoolManager manager_,
        PoolKey memory key_,
        bool mad0_,
        address[2] memory actors_
    ) {
        hook = hook_;
        fwa = fwa_;
        router = router_;
        manager = manager_;
        key = key_;
        mad0 = mad0_;
        actors = actors_;
    }

    function swap(uint256 actorSeed, uint256 amountSeed, bool buy, bool exactInput) external {
        address who = actors[actorSeed % 2];
        uint256 amount = bound(amountSeed, 1 ether, 2_000_000 ether);
        bool zeroForOne = buy ? !mad0 : mad0;
        SwapParams memory p = SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 pendingBefore = hook.pendingBurnClaims();
        vm.recordLogs();
        vm.prank(who, who);
        try router.swap(key, p, who) {}
        catch {
            vm.getRecordedLogs();
            return;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEES_SIG) {
                (,, uint256 playground,, uint256 excess) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                ghostExcess += excess;
                ghostPlayground += playground;
            }
        }
        if (hook.pendingBurnClaims() > pendingBefore) ++deferrals;
        ++swaps;
    }

    function burnExcess() external {
        uint256 pending = hook.pendingBurnClaims();
        uint256 burnedBefore = fwa.burned();
        uint256 owed = hook.playgroundFwaClaims() + hook.nftFwaClaims();
        assertEq(hook.burnExcess(), pending, "outside a swap the float always covers the backlog");
        assertEq(fwa.burned() - burnedBefore, pending);
        assertEq(hook.pendingBurnClaims(), 0);
        assertEq(hook.playgroundFwaClaims() + hook.nftFwaClaims(), owed, "flush never touches revenue");
        if (pending != 0) ++flushes;
    }

    function payout() external {
        uint256 pending = hook.pendingBurnClaims();
        uint256 before = fwa.balanceOf(PLAYGROUND);
        uint256 paid = hook.payout();
        assertEq(fwa.balanceOf(PLAYGROUND) - before, paid);
        assertEq(hook.pendingBurnClaims(), pending, "payout never spends burn claims");
        ghostPaid += paid;
    }

    function wait(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 900));
        vm.roll(vm.getBlockNumber() + 1);
    }
}

contract MadFreshLaunchInvariantTest is FreshLaunchBase {
    FreshLaunchHandler internal handler;
    uint256 internal fwaSupplyStart;

    function setUp() public override {
        super.setUp();
        _enable();
        handler = new FreshLaunchHandler(hook, fwa, router, manager, key, mad0, [alice, bob]);
        fwaSupplyStart = fwa.totalSupply();
        targetContract(address(handler));
    }

    function test_handlerPathsAreLive() public {
        handler.swap(0, 1000 ether, true, true);
        assertEq(handler.deferrals(), 1);
        handler.swap(0, 100_000 ether, true, true);
        handler.swap(1, 10 ether, true, false);
        handler.swap(0, 500 ether, false, true);
        handler.swap(1, 1 ether, false, false);
        assertEq(handler.swaps(), 5);
        handler.payout();
        handler.burnExcess();
        handler.wait(900);
        _checkAll();
    }

    function _checkAll() internal view {
        invariant_hookClaimsAreRevenuePlusBacklog();
        invariant_burnsMatchCommittedExcess();
        invariant_claimsAreBackedByPhysicalFwa();
        invariant_playgroundAccrualConserved();
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 30
    function invariant_hookClaimsAreRevenuePlusBacklog() public view {
        assertEq(
            manager.balanceOf(address(hook), fwaId),
            hook.playgroundFwaClaims() + hook.nftFwaClaims() + hook.pendingBurnClaims()
        );
        assertEq(fwa.balanceOf(address(hook)), 0, "hook never keeps physical FWA");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 30
    function invariant_burnsMatchCommittedExcess() public view {
        assertEq(hook.totalBurned(), handler.ghostExcess(), "totalBurned == sum of excess fees");
        assertEq(fwa.burned() + hook.pendingBurnClaims(), hook.totalBurned(), "burned + backlog");
        assertEq(fwaSupplyStart - fwa.totalSupply(), fwa.burned());
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 30
    function invariant_claimsAreBackedByPhysicalFwa() public view {
        assertGe(fwa.balanceOf(address(manager)), manager.balanceOf(address(hook), fwaId));
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 30
    function invariant_playgroundAccrualConserved() public view {
        assertEq(fwa.balanceOf(PLAYGROUND), handler.ghostPaid());
        assertEq(handler.ghostPaid() + hook.playgroundFwaClaims(), handler.ghostPlayground());
    }
}
