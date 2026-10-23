// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    MadFixture,
    MadToken,
    MadHook,
    MadBase,
    MockSwarm,
    WalletContract,
    PoolKey,
    IHooks,
    Currency,
    BalanceDelta
} from "./MadFixture.sol";
import {IMadHook} from "../src/interfaces/IMad.sol";

contract FakeHook {
    address public factory;
    address public owner;
    address public token;
    address public poolManager;
    address public rewards;
    bool public binding = true;

    constructor(address f, address o, address t, address m, address r) {
        factory = f;
        owner = o;
        token = t;
        poolManager = m;
        rewards = r;
    }

    function bind(PoolKey calldata key, address sender) external {
        MadToken(token).bindHook(key, sender);
    }
}

contract MadTokenTest is MadFixture {
    MadToken private unbound;

    function setUp() public override {
        super.setUp();
        unbound = new MadToken();
    }

    function test_supplyMetadataFixedOwnerAndBinding() public view {
        assertEq(mad.name(), "Mutually Assured Destruction");
        assertEq(mad.symbol(), "MAD");
        assertEq(mad.decimals(), 18);
        assertEq(mad.totalSupply(), 1_000_000_000 ether);
        assertEq(mad.owner(), OWNER);
        assertEq(hook.owner(), OWNER);
        assertEq(rewards.owner(), OWNER);
        assertEq(mad.factory(), address(this));
        assertEq(mad.hook(), address(hook));
        assertEq(mad.poolManager(), address(manager));
        assertEq(mad.helper(), address(rewards));
        assertEq(mad.swarm(), address(swarm));
        assertFalse(mad.bootstrapping());
        assertLe(address(mad).code.length, 24576);
        assertLe(address(hook).code.length, 24576);
        assertLe(address(rewards).code.length, 24576);
    }

    function test_runtimeContainsNoDelegateCallCallCodeOrSelfdestruct() public view {
        address[3] memory subjects = [address(mad), address(hook), address(rewards)];
        for (uint256 s; s < subjects.length; ++s) {
            bytes memory code = subjects[s].code;
            bool reachable = true;
            for (uint256 i; i < code.length; ++i) {
                uint8 op = uint8(code[i]);
                if (op == 0x5b) reachable = true;
                if (op >= 0x60 && op <= 0x7f) {
                    i += op - 0x5f;
                    continue;
                }
                if (reachable) assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
                if (op == 0 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                    reachable = false;
                }
            }
        }
    }

    function test_bootstrapCannotBeSpoofedByMatchingGettersLater() public {
        FakeHook fake =
            new FakeHook(address(this), OWNER, address(unbound), address(manager), address(rewards));
        PoolKey memory fakeKey = key;
        fakeKey.hooks = IHooks(address(fake));
        vm.expectRevert(MadToken.NotBootstrapping.selector);
        fake.bind(fakeKey, address(this));
        assertEq(unbound.hook(), address(0));
    }

    function test_rebindingAndWrongCallbacksRejected() public {
        vm.expectRevert(MadToken.AlreadyBound.selector);
        mad.bindHook(key, address(this));
        vm.expectRevert(MadHook.NotManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.prank(address(manager));
        vm.expectRevert(MadHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(MadBase.Unauthorized.selector);
        mad.accountTransferDelta(1);
    }

    function test_enableOnlyOwnerOnceAfterBinding() public {
        vm.expectRevert(MadBase.Unauthorized.selector);
        mad.enableTrading();
        vm.prank(OWNER);
        vm.expectRevert(MadToken.BadBinding.selector);
        unbound.enableTrading();
        _enable();
        assertTrue(mad.trading());
        assertEq(mad.currentRound(), 1);
        (uint64 first, uint64 last) = mad.roundBlocks(1);
        assertEq(first, vm.getBlockNumber());
        assertEq(last, 0);
        vm.prank(OWNER);
        vm.expectRevert(MadToken.AlreadyTrading.selector);
        mad.enableTrading();
    }

    function test_factoryFundingRemainderAndCollectBeforeEnable() public {
        uint256 held = mad.balanceOf(OWNER);
        mad.transfer(OWNER, 100 ether);
        assertEq(mad.balanceOf(OWNER), held + 100 ether);
        WalletContract c = new WalletContract();
        mad.transfer(address(c), 10 ether);
        c.send(mad, address(this), 10 ether);
        _modify(key, 0);
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.TradingClosed.selector);
        mad.transfer(bob, 1);
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.TradingClosed.selector);
        mad.freeze(bob);
    }

    function test_swarmClaimsRollbackUntilEnableAndOriginalCliffPreserved() public {
        uint256 cliff = swarm.cliff();
        vm.expectRevert(bytes("cliff"));
        swarm.claim(alice, 1_000_000 ether, new bytes32[](0));
        vm.warp(cliff);
        vm.expectRevert(MadToken.SwarmLocked.selector);
        swarm.claim(alice, 1_000_000 ether, new bytes32[](0));
        assertFalse(swarm.claimed(alice));
        assertEq(mad.balanceOf(address(swarm)), 100_000_000 ether);
        _enable();
        swarm.claim(alice, 1_000_000 ether, new bytes32[](0));
        assertTrue(swarm.claimed(alice));
        assertEq(swarm.cliff(), cliff);
        vm.expectRevert(bytes("claimed"));
        swarm.claim(alice, 1_000_000 ether, new bytes32[](0));
    }

    function test_enableDoesNotResetOrBypassSwarmCliff() public {
        _enable();
        vm.expectRevert(bytes("cliff"));
        swarm.claim(alice, 1_000_000 ether, new bytes32[](0));
        vm.warp(swarm.cliff());
        swarm.claim(alice, 1_000_000 ether, new bytes32[](0));
    }

    function test_swarmCannotSweepEvenToOwnerFactoryOrExemptBeforeEnable() public {
        vm.expectRevert(MadToken.SwarmLocked.selector);
        swarm.sweep(OWNER, 1);
        vm.expectRevert(MadToken.SwarmLocked.selector);
        swarm.sweep(address(this), 1);
        WalletContract d = new WalletContract();
        _distributor(address(d), true);
        vm.expectRevert(MadToken.SwarmLocked.selector);
        swarm.sweep(address(d), 1);
        _enable();
        swarm.sweep(OWNER, 1);
        swarm.sweep(address(d), 1);
    }

    function test_swarmIdentityNeverReplaced() public {
        MockSwarm another = new MockSwarm(mad, bytes32(0));
        mad.transfer(address(another), 10 ether);
        assertEq(mad.swarm(), address(swarm));
        _enable();
        vm.prank(OWNER);
        mad.setUseGlobalDistributors(false);
        assertTrue(mad.isDistributor(address(swarm)));
        assertFalse(mad.isDistributor(address(another)));
    }

    function test_swarmBadProofRollsBackAfterEnable() public {
        _enable();
        vm.warp(swarm.cliff());
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("wrong proof");
        vm.expectRevert(bytes("proof"));
        swarm.claim(alice, 1_000_000 ether, proof);
        assertFalse(swarm.claimed(alice));
        assertEq(mad.balanceOf(address(swarm)), 100_000_000 ether);
    }

    function test_noExternalMintBurnConfiscationOrOwnerReplacement() public {
        bytes4[5] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("burnFrom(address,uint256)")),
            bytes4(keccak256("seize(address,uint256)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("setHook(address)"))
        ];
        uint256 before = mad.balanceOf(bob);
        for (uint256 i; i < selectors.length; ++i) {
            vm.prank(OWNER);
            (bool ok,) = address(mad).call(abi.encodeWithSelector(selectors[i], bob, 1 ether));
            assertFalse(ok);
        }
        assertEq(mad.balanceOf(bob), before);
        assertEq(mad.totalSupply(), 1_000_000_000 ether);
        assertEq(mad.owner(), OWNER);
        assertEq(mad.hook(), address(hook));
    }

    function test_directWalletTransfersAndThirdPartyTransferFrom() public {
        _enable();
        vm.prank(alice, alice);
        mad.transfer(bob, 20 ether);
        vm.prank(alice);
        mad.approve(carol, 10 ether);
        vm.prank(carol, carol);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transferFrom(alice, bob, 1 ether);
        vm.prank(alice);
        mad.approve(alice, 10 ether);
        vm.prank(alice, alice);
        mad.transferFrom(alice, bob, 1 ether);
    }

    function test_safeContractsAnd7702AreRejectedWithoutExemption() public {
        _enable();
        WalletContract safe = new WalletContract();
        mad.transfer(address(safe), 10 ether);
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transfer(address(safe), 1);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        safe.send(mad, bob, 1);
        vm.expectRevert(MadToken.WalletOnly.selector);
        safe.freeze(mad, bob);
        vm.etch(carol, abi.encodePacked(hex"ef0100", address(safe)));
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transfer(carol, 1);
        vm.prank(carol, carol);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        mad.transfer(bob, 1);
        vm.prank(carol, carol);
        vm.expectRevert(MadToken.WalletOnly.selector);
        mad.freeze(bob);
    }

    function test_ownerLocalGlobalAndSwarmCustodyExemptions() public {
        _enable();
        WalletContract d = new WalletContract();
        _distributor(address(d), true);
        vm.prank(alice, alice);
        mad.transfer(address(d), 20 ether);
        d.send(mad, bob, 10 ether);
        vm.prank(alice);
        mad.approve(address(d), 10 ether);
        d.pull(mad, alice, address(d), 10 ether);
        _distributor(address(d), false);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        d.send(mad, bob, 1);
        registry.set(address(d), true);
        d.send(mad, bob, 1);
        vm.prank(OWNER);
        mad.setUseGlobalDistributors(false);
        vm.expectRevert(MadToken.InvalidTransfer.selector);
        d.send(mad, bob, 1);
        vm.prank(alice, alice);
        mad.transfer(OWNER, 1);
    }

    function test_coreAddressesNeverBecomeDistributors() public {
        address[4] memory core = [address(manager), address(hook), address(mad), address(rewards)];
        for (uint256 i; i < core.length; ++i) {
            registry.set(core[i], true);
            assertFalse(mad.isDistributor(core[i]));
            address[] memory a = new address[](1);
            a[0] = core[i];
            vm.prank(OWNER);
            vm.expectRevert(MadBase.InvalidAddress.selector);
            mad.setDistributors(a, true);
        }
        address[] memory wallets = new address[](1);
        wallets[0] = alice;
        vm.prank(OWNER);
        vm.expectRevert(MadBase.InvalidAddress.selector);
        mad.setDistributors(wallets, true);
    }

    function test_freezeBurnCreditResetAndIncomingTransfers() public {
        _enable();
        uint256 cost = mad.freezeCost(bob);
        uint256 supply = mad.totalSupply();
        uint256 targetBefore = mad.balanceOf(bob);
        vm.prank(alice, alice);
        mad.freeze(bob);
        assertEq(mad.totalSupply(), supply - cost / 2);
        assertEq(mad.balanceOf(bob), targetBefore + cost - cost / 2);
        assertEq(mad.spent(1, alice), cost);
        assertEq(mad.leader(1), alice);
        uint64 firstUntil = mad.frozenUntil(bob);
        vm.prank(carol, carol);
        mad.transfer(bob, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        vm.prank(alice, alice);
        mad.freeze(bob);
        assertEq(mad.frozenUntil(bob), vm.getBlockTimestamp() + 24 hours);
        assertEq(mad.frozenUntil(bob), firstUntil + 3 hours);
    }

    function test_frozenSenderCannotUseAnyExemptionButCanPayForFreeze() public {
        _enable();
        vm.prank(alice, alice);
        mad.freeze(bob);
        address[4] memory recipients = [alice, OWNER, address(this), address(swarm)];
        for (uint256 i; i < recipients.length; ++i) {
            vm.prank(bob, bob);
            vm.expectRevert(MadToken.SenderFrozen.selector);
            mad.transfer(recipients[i], 1);
        }
        registry.set(bob, true);
        vm.prank(bob, bob);
        vm.expectRevert(MadToken.SenderFrozen.selector);
        mad.transfer(alice, 1);
        uint256 cost = mad.freezeCost(carol);
        vm.prank(bob, bob);
        mad.freeze(carol);
        assertEq(mad.spent(1, bob), cost);
        vm.prank(bob, bob);
        vm.expectRevert(MadToken.SenderFrozen.selector);
        mad.transfer(alice, 1);
        vm.warp(mad.frozenUntil(bob));
        vm.prank(bob, bob);
        mad.transfer(alice, 1);
    }

    function test_freezeTargetsCostAndCallerRestrictions() public {
        _enable();
        address[8] memory targets = [
            address(0),
            alice,
            address(manager),
            address(hook),
            address(mad),
            address(rewards),
            address(this),
            address(swarm)
        ];
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(alice, alice);
            vm.expectRevert(MadToken.InvalidTarget.selector);
            mad.freeze(targets[i]);
        }
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.InvalidTarget.selector);
        mad.freeze(OWNER);
        vm.prank(alice, alice);
        vm.expectRevert(MadToken.ZeroCost.selector);
        mad.freeze(address(0xABCD));
        vm.prank(address(0xABCD), address(0xABCD));
        vm.expectRevert(bytes4(keccak256("InsufficientBalance()")));
        mad.freeze(alice);
        vm.prank(alice, bob);
        vm.expectRevert(MadToken.WalletOnly.selector);
        mad.freeze(bob);
    }

    function test_tiesStayWithFirstToTotal() public {
        _enable();
        vm.prank(alice, alice);
        mad.freeze(bob);
        vm.prank(bob, bob);
        mad.freeze(carol);
        assertEq(mad.spent(1, alice), mad.spent(1, bob));
        assertEq(mad.leader(1), alice);
        vm.prank(bob, bob);
        mad.freeze(carol);
        assertEq(mad.leader(1), bob);
    }

    function testFuzz_freezeRoundingConservesBalances(uint128 targetAmount) public {
        uint256 target = bound(uint256(targetAmount), 100, 100_000_000 ether);
        address victim = address(0xBEEF);
        mad.transfer(victim, target);
        _enable();
        uint256 callerBefore = mad.balanceOf(alice);
        uint256 supply = mad.totalSupply();
        uint256 cost = target / 100;
        vm.prank(alice, alice);
        mad.freeze(victim);
        assertEq(mad.balanceOf(alice), callerBefore - cost);
        assertEq(mad.balanceOf(victim), target + cost - cost / 2);
        assertEq(mad.totalSupply(), supply - cost / 2);
        assertEq(mad.spent(1, alice), cost);
    }

    function _distributor(address d, bool allowed) private {
        address[] memory a = new address[](1);
        a[0] = d;
        vm.prank(OWNER);
        mad.setDistributors(a, allowed);
    }
}
