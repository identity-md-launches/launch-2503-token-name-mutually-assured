// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A fixed administrator, with no transfer, renunciation, upgrade or withdrawal power.
abstract contract MadBase {
    address public constant owner = 0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774;
    error Unauthorized();
    error Reentrancy();
    error InvalidAddress();
    uint256 private _entered;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }
}
