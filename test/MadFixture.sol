// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MadToken} from "../src/MadToken.sol";
import {MadHook} from "../src/MadHook.sol";
import {MadRewards} from "../src/MadRewards.sol";
import {MadBase} from "../src/MadBase.sol";
import {MockERC20, MockFWA} from "./mocks/MockERC20.sol";
import {MockSwarm, WalletContract, MockRegistry} from "./mocks/MockSwarm.sol";
import {SwapRouter} from "./mocks/SwapRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract MadFixture is Test {
    using StateLibrary for IPoolManager;
    address internal constant OWNER = 0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774;
    address internal constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA901);
    uint160 internal constant Q96 = 79228162514264337593543950336;
    MadToken internal mad;
    MadHook internal hook;
    MadRewards internal rewards;
    MockSwarm internal swarm;
    MockFWA internal fwa;
    IPoolManager internal manager;
    PoolKey internal key;
    SwapRouter internal router;
    MockRegistry internal registry;
    bool internal mad0;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(25_000_000);
        manager = _newManager();
        vm.etch(FWA, address(new MockFWA()).code);
        fwa = MockFWA(FWA);
        fwa.setManager(address(manager));
        this.deployLaunch();
        registry = new MockRegistry();
        vm.etch(mad.registry(), address(registry).code);
        registry = MockRegistry(mad.registry());
        fwa.mint(address(this), 100_000_000 ether);
        _modify(key, 10_000_000 ether);
        router = new SwapRouter(manager);
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        vm.prank(OWNER);
        hook.setRouters(routers, true);
        mad.transfer(alice, 10_000_000 ether);
        mad.transfer(bob, 1_000_000 ether);
        mad.transfer(carol, 1_000_000 ether);
        fwa.mint(alice, 1_000_000 ether);
        fwa.mint(bob, 1_000_000 ether);
        vm.startPrank(alice, alice);
        mad.approve(address(router), type(uint256).max);
        fwa.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob, bob);
        mad.approve(address(router), type(uint256).max);
        fwa.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _newManager() internal virtual returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(this))));
    }

    function _newMadToken() internal virtual returns (MadToken result) {
        do {
            result = new MadToken();
        } while (address(result) > FWA);
    }

    function deployLaunch() external {
        require(msg.sender == address(this));
        mad = _newMadToken();
        swarm = new MockSwarm(mad, keccak256(abi.encode(alice, 1_000_000 ether)));
        mad.transfer(address(swarm), 100_000_000 ether);
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
        rewards = hook.rewards();
        mad0 = address(mad) < FWA;
        key = PoolKey(
            Currency.wrap(mad0 ? address(mad) : FWA),
            Currency.wrap(mad0 ? FWA : address(mad)),
            12500,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, Q96);
    }

    function _enable() internal {
        vm.prank(OWNER);
        mad.enableTrading();
    }

    function _mature() internal {
        _enable();
        vm.warp(vm.getBlockTimestamp() + 1800);
    }

    function _params(bool buy, int256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = buy ? !mad0 : mad0;
        return SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _swap(bool buy, int256 amount) internal returns (BalanceDelta d) {
        vm.prank(alice, alice);
        return router.swap(key, _params(buy, amount), alice);
    }

    function _modify(PoolKey memory k, int256 liquidity) internal returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(k, liquidity)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory k, int256 liquidity) = abi.decode(data, (PoolKey, int256));
        (BalanceDelta d,) =
            manager.modifyLiquidity(k, ModifyLiquidityParams(-887220, 887220, liquidity, bytes32(0)), "");
        _settle(k.currency0, d.amount0());
        _settle(k.currency1, d.amount1());
        return abi.encode(d);
    }

    function _settle(Currency c, int128 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(c);
            if (c.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                IERC20(Currency.unwrap(c)).transfer(address(manager), amount);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(c, address(this), uint256(uint128(delta)));
        }
    }
    receive() external payable {}
}
