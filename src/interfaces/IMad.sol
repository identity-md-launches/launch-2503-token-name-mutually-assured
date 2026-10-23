// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IMadHook {
    function factory() external view returns (address);
    function owner() external view returns (address);
    function token() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function rewards() external view returns (address);
    function binding() external view returns (bool);
    function closeRound() external returns (uint256 round, uint64 first, uint64 last, address best);
    function redeemNFTBudget() external returns (uint256);
}

interface ISwarm {
    function token() external view returns (address);
    function opener() external view returns (address);
}

interface IDistributorRegistry {
    function isGlobalDistributor(address account) external view returns (bool);
}

interface IFWAToken {
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}
