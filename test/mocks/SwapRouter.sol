// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test router. Settlement pulls the entry caller, as Permit2 does in the real router.
contract SwapRouter {
    using TransientStateLibrary for IPoolManager;
    IPoolManager public immutable manager;
    address private payer;
    address private recipient;
    bool private claims;
    bool private active;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory p, address to) external returns (BalanceDelta d) {
        SwapParams[] memory ps = new SwapParams[](1);
        ps[0] = p;
        return _run(key, ps, to, false);
    }

    function swapClaims(PoolKey memory key, SwapParams memory p) external returns (BalanceDelta d) {
        SwapParams[] memory ps = new SwapParams[](1);
        ps[0] = p;
        return _run(key, ps, msg.sender, true);
    }

    function multi(PoolKey memory key, SwapParams[] memory ps, address to) external returns (BalanceDelta) {
        return _run(key, ps, to, false);
    }

    function _run(PoolKey memory key, SwapParams[] memory ps, address to, bool useClaims)
        private
        returns (BalanceDelta)
    {
        require(!active);
        active = true;
        payer = msg.sender;
        recipient = to;
        claims = useClaims;
        bytes memory result = manager.unlock(abi.encode(key, ps));
        active = false;
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && active);
        (PoolKey memory key, SwapParams[] memory ps) = abi.decode(data, (PoolKey, SwapParams[]));
        BalanceDelta total;
        for (uint256 i; i < ps.length; ++i) {
            total = total + manager.swap(key, ps[i], "");
        }
        _settle(key.currency0);
        _settle(key.currency1);
        return abi.encode(total);
    }

    function _settle(Currency c) private {
        int256 d = manager.currencyDelta(address(this), c);
        if (d < 0) {
            manager.sync(c);
            require(IERC20(Currency.unwrap(c)).transferFrom(payer, address(manager), uint256(-d)));
            manager.settle();
        } else if (d > 0) {
            if (claims) manager.mint(recipient, c.toId(), uint256(d));
            else manager.take(c, recipient, uint256(d));
        }
    }
}
