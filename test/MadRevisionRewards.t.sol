// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MadFixture, MadRewards, MockERC20} from "./MadFixture.sol";
import {MockFwaV2, MockIntake} from "./mocks/MockServices.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @dev A winner that hands the prize straight back inside its receive hook.
contract ReturningReceiver {
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        IERC721(msg.sender).transferFrom(address(this), from, tokenId);
        return this.onERC721Received.selector;
    }
}

/// @dev Edges of this revision's rewards changes: late adoption, unsuperseded late answers, and
/// registration that is released on delivery.
contract MadRevisionRewardsTest is MadFixture {
    MockFwaV2 private source;
    MockIntake private oracle;
    MockERC20 private imd;
    uint256 private constant SIGNER_KEY = 0xA11CE;

    function setUp() public override {
        super.setUp();
        source = new MockFwaV2();
        oracle = new MockIntake();
        imd = new MockERC20("IMD", "IMD", 0);
        vm.startPrank(OWNER);
        rewards.setFwaV2(address(source));
        rewards.setOracleSettings(
            address(oracle), address(imd), bytes32("oracle.request@oracle-1"), vm.addr(SIGNER_KEY)
        );
        vm.stopPrank();
        imd.mint(address(rewards), 100 ether);
        _mature();
    }

    function test_lateDeliveryFromReplacedPoolIsStillAdoptedFromItsRecordedSource() public {
        uint256 id = _buy();
        source.fulfill(id);
        MockFwaV2 other = new MockFwaV2();
        vm.prank(OWNER);
        rewards.setFwaV2(address(other));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        source.finalizeUnsettled(id);
        rewards.claim(id);
        assertEq(rewards.prizeCount(), 1);
        assertTrue(rewards.registeredNFT(keccak256(abi.encode(address(source.nft()), id))));
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(id);
    }

    function test_unfulfilledDrawCannotBeAdoptedLate() public {
        uint256 id = _buy();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(id);
    }

    function test_unsupersededRequestOlderThanSixHoursAnsweredJustBeforeDeadline() public {
        bytes32 id = _ask();
        vm.warp(uint256(_round(1).closedAt) + 72 hours - 1);
        OracleAttestation.Attestation memory a = _answer(id, bob);
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertTrue(ok, "live request still answerable until the round deadline");
        assertEq(_round(1).winner, bob);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(rewards.award(1));
        assertEq(source.nft().ownerOf(_round(1).tokenId), bob);
    }

    function test_unsupersededRequestAnsweredAtDeadlineRejectedAndLeaderFixed() public {
        bytes32 id = _ask();
        vm.warp(uint256(_round(1).closedAt) + 72 hours);
        OracleAttestation.Attestation memory a = _answer(id, bob);
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertFalse(ok);
        assertEq(_round(1).winner, address(0));
        assertEq(rewards.beneficiaryOf(1), alice, "saved leader");
    }

    function test_supersedeOnlyAtSixHoursThenOldAnswerDead() public {
        bytes32 first = _ask();
        vm.warp(vm.getBlockTimestamp() + 6 hours - 1);
        vm.expectRevert();
        rewards.askWinner(1);
        vm.warp(vm.getBlockTimestamp() + 1);
        bytes32 second = rewards.askWinner(1);
        assertTrue(second != first);
        OracleAttestation.Attestation memory a = _answer(first, bob);
        (bool ok,) = oracle.deliver(first, a, _sign(a));
        assertFalse(ok, "superseded");
        a = _answer(second, carol);
        (ok,) = oracle.deliver(second, a, _sign(a));
        assertTrue(ok);
        assertEq(_round(1).winner, carol);
        a = _answer(second, bob);
        a.requestId = keccak256("another");
        (ok,) = oracle.deliver(second, a, _sign(a));
        assertFalse(ok, "first valid answer is final");
    }

    function test_prizeReturnedByWinnerIsNotAPrizeAgainNorReassignable() public {
        bytes32 id = _ask();
        ReturningReceiver receiver = new ReturningReceiver();
        OracleAttestation.Attestation memory a = _answer(id, address(receiver));
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertTrue(ok);
        uint256 tokenId = _round(1).tokenId;
        assertTrue(rewards.award(1));
        assertEq(source.nft().ownerOf(tokenId), address(rewards), "winner handed it back");
        assertFalse(rewards.registeredNFT(keccak256(abi.encode(address(source.nft()), tokenId))));
        vm.expectRevert(MadRewards.AlreadyAwarded.selector);
        rewards.award(1);
        // Its own purchase is spent, so it cannot be queued twice from the same draw.
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(tokenId);
        assertEq(rewards.prizeCount(), 1);
        vm.prank(alice, alice);
        mad.freeze(bob);
        vm.roll(vm.getBlockNumber() + 7200);
        vm.expectRevert();
        rewards.closeRound();
    }

    function _buy() private returns (uint256) {
        vm.deal(address(rewards), 10 ether);
        return rewards.buy();
    }

    function _ask() private returns (bytes32) {
        uint256 id = _buy();
        source.fulfill(id);
        rewards.claim(id);
        vm.prank(alice, alice);
        mad.freeze(bob);
        vm.roll(vm.getBlockNumber() + 7200);
        rewards.closeRound();
        vm.roll(vm.getBlockNumber() + 8);
        return rewards.askWinner(1);
    }

    function _round(uint256 id) private view returns (MadRewards.Round memory r) {
        (
            r.first,
            r.last,
            r.closedAt,
            r.savedLeader,
            r.collection,
            r.tokenId,
            r.winner,
            r.beneficiary,
            r.awarded,
            r.requestId
        ) = rewards.rounds(id);
    }

    function _answer(bytes32 id, address winner)
        private
        view
        returns (OracleAttestation.Attestation memory a)
    {
        (uint256 round, bytes32 hash,,,,) = rewards.requests(id);
        MadRewards.Round memory r = _round(round);
        address[] memory list = new address[](1);
        list[0] = winner;
        a = OracleAttestation.Attestation(
            keccak256(abi.encode("oracle uuid", id, winner)),
            1,
            hash,
            4,
            abi.encode(list),
            mad.spent(round, winner),
            r.first,
            r.last,
            bytes32(uint256(7)),
            keccak256("panel"),
            30,
            20,
            25,
            uint64(vm.getBlockTimestamp()),
            uint64(vm.getBlockTimestamp() + 3600)
        );
    }

    function _sign(OracleAttestation.Attestation memory a) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, rewards.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }
}
