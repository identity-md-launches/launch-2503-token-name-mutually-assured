// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {MadFixture, IPoolManager, PoolKey, Currency} from "./MadFixture.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Exercises the actual deployed router and Permit2 bytecode, offline and unmodified.
contract UniversalRouterTest is MadFixture {
    address private constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    struct ExactInputSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct ExactOutputSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    function _newManager() internal override returns (IPoolManager) {
        // Run its constructor at the real address, preserving NoDelegateCall's immutable.
        vm.etch(MAINNET_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool ok, bytes memory runtime) = MAINNET_MANAGER.call("");
        require(ok);
        vm.etch(MAINNET_MANAGER, runtime);
        return IPoolManager(MAINNET_MANAGER);
    }

    function setUp() public override {
        super.setUp();
        vm.etch(ROUTER, vm.getDeployedCode("test/fixtures/UniversalRouter.json"));
        vm.etch(PERMIT2, vm.getDeployedCode("test/fixtures/Permit2.json"));
        assertEq(ROUTER.codehash, 0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f);
        assertEq(PERMIT2.codehash, 0xc67d1657868aa5146eaf24fb879fb1fdec3d2d493b3683a61c9c2f4fb2851131);
        vm.startPrank(alice, alice);
        mad.approve(PERMIT2, type(uint256).max);
        fwa.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(mad), ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(FWA, ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
        _mature();
    }

    function test_deployedRouterBuysAndSellsBothExactModesThroughRealPermit2() public {
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode % 2 == 0;
            bool exactInput = mode < 2;
            uint256 before = mad.balanceOf(alice);
            _execute(buy, exactInput, 100 ether, false);
            if (buy) assertGt(mad.balanceOf(alice), before);
            else assertLt(mad.balanceOf(alice), before);
            assertEq(mad.getNetTransferAllowance(), 0);
            assertEq(manager.balanceOf(alice, uint256(uint160(address(mad)))), 0);
        }
    }

    function test_deployedRouterRejectsMadERC6909Payout() public {
        uint256 before = mad.balanceOf(alice);
        vm.expectRevert();
        _execute(true, true, 100 ether, true);
        assertEq(mad.balanceOf(alice), before);
        assertEq(manager.balanceOf(alice, uint256(uint160(address(mad)))), 0);
        assertEq(hook.playgroundFwaClaims(), 0);
    }

    function test_deployedRouterFrozenSellRollsBackAndBuyStillReceives() public {
        vm.prank(bob, bob);
        mad.freeze(alice);
        vm.expectRevert();
        _execute(false, true, 100 ether, false);
        _execute(true, true, 100 ether, false);
    }

    function _execute(bool buy, bool exactInput, uint128 amount, bool claims) private {
        Currency input = Currency.wrap(buy ? FWA : address(mad));
        Currency output = Currency.wrap(buy ? address(mad) : FWA);
        bool zeroForOne = buy ? !mad0 : mad0;
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = exactInput
            ? abi.encode(ExactInputSingle(key, zeroForOne, amount, 0, ""))
            : abi.encode(ExactOutputSingle(key, zeroForOne, amount, type(uint128).max, ""));
        actionParams[1] = abi.encode(input, type(uint256).max);
        actionParams[2] = claims ? abi.encode(output, alice, uint256(0)) : abi.encode(output, uint256(0));
        bytes memory actions = abi.encodePacked(
            exactInput ? bytes1(0x06) : bytes1(0x08), bytes1(0x0c), claims ? bytes1(0x17) : bytes1(0x0f)
        );
        bytes[] memory commands = new bytes[](1);
        commands[0] = abi.encode(actions, actionParams);
        vm.prank(alice, alice);
        IUniversalRouter(ROUTER).execute(hex"10", commands, vm.getBlockTimestamp());
    }
}
