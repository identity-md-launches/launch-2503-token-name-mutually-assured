// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Models the official market's exact-input-only sell and 1% ETH output fee.
contract MockMarketHook {
    IPoolManager public immutable manager;
    address public constant FEE_RECEIVER = address(0xFEE);

    constructor(IPoolManager m) {
        manager = m;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata p, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(manager) && !p.zeroForOne && p.amountSpecified < 0);
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta d, bytes calldata)
        external
        returns (bytes4, int128)
    {
        require(msg.sender == address(manager));
        int128 fee = d.amount0() / 100;
        // The deployed market requires its own fee as physical ETH in the current unlock.
        // Taking directly to its receiver models the same debit as take-to-hook then forwarding.
        if (fee != 0) manager.take(Currency.wrap(address(0)), FEE_RECEIVER, uint256(uint128(fee)));
        return (IHooks.afterSwap.selector, fee);
    }
}
