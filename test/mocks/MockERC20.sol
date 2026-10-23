// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory n, string memory s, uint256 supply) {
        _name = n;
        _symbol = s;
        _mint(msg.sender, supply);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFWA is ERC20 {
    address public manager;
    uint256 public burned;

    function name() public pure override returns (string memory) {
        return "Fake World Assets";
    }

    function symbol() public pure override returns (string memory) {
        return "FWA";
    }

    function setManager(address m) external {
        manager = m;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        burned += amount;
        _burn(msg.sender, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        require(
            from == address(0) || to == address(0) || from == manager || to == manager, "FWA transfer gate"
        );
    }
}
