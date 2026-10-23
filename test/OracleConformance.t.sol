// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MadToken} from "../src/MadToken.sol";
import {MadRewards} from "../src/MadRewards.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {OracleQuestion} from "../src/oracle/OracleQuestion.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

contract OracleConformanceTest is Test {
    address private constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 private constant VECTOR_DIGEST =
        0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes private constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address private constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function test_protocolDigestSignatureAndCallbackSelector() public {
        vm.chainId(11155111);
        vm.warp(1800000000);
        MadRewards instance = new MadRewards(new MadToken(), address(this));
        vm.etch(VECTOR_CONSUMER, address(instance).code);
        MadRewards consumer = MadRewards(payable(VECTOR_CONSUMER));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
        assertEq(consumer.attestationDigest(a), VECTOR_DIGEST);
        assertTrue(
            SignatureChecker.isValidSignatureNow(SIGNER, consumer.attestationDigest(a), VECTOR_SIGNATURE)
        );
        assertEq(
            consumer.onOracleResult.selector,
            bytes4(
                keccak256(
                    "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                )
            )
        );
    }

    function test_protocolQuestionHashVector() public pure {
        OracleQuestion.Definition[] memory definitions = new OracleQuestion.Definition[](1);
        definitions[0] = OracleQuestion.Definition(
            "denomination", "WETH, summed as the absolute swapped amount on the WETH side"
        );
        OracleQuestion.Question memory q = OracleQuestion.Question(
            "Which Uniswap v4 pool did the most WETH volume in the last day?",
            1,
            100,
            200,
            5,
            1,
            false,
            definitions
        );
        assertEq(OracleQuestion.hash(q), 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb);
    }
}
