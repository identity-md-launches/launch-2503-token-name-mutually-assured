// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MadToken} from "../../src/MadToken.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract MockSwarm {
    MadToken public immutable token;
    address public immutable opener;
    uint256 public immutable cliff;
    bytes32 public immutable root;
    mapping(address => bool) public claimed;

    constructor(MadToken t, bytes32 root_) {
        token = t;
        opener = msg.sender;
        cliff = block.timestamp + 1 hours;
        root = root_;
    }

    function claim(address recipient, uint256 amount, bytes32[] calldata proof) external {
        require(block.timestamp >= cliff, "cliff");
        require(!claimed[recipient], "claimed");
        require(MerkleProof.verify(proof, root, keccak256(abi.encode(recipient, amount))), "proof");
        claimed[recipient] = true;
        require(token.transfer(recipient, amount));
    }

    function sweep(address to, uint256 amount) external {
        require(msg.sender == opener);
        token.transfer(to, amount);
    }
}

contract WalletContract {
    function send(MadToken t, address to, uint256 amount) external {
        t.transfer(to, amount);
    }

    function pull(MadToken t, address from, address to, uint256 amount) external {
        t.transferFrom(from, to, amount);
    }

    function freeze(MadToken t, address target) external {
        t.freeze(target);
    }
}

contract MockRegistry {
    mapping(address => bool) public isGlobalDistributor;

    function set(address a, bool yes) external {
        isGlobalDistributor[a] = yes;
    }
}
