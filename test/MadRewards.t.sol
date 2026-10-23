// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MadFixture, MadToken, MadBase, MadRewards, MockERC20} from "./MadFixture.sol";
import {MockFwaV2, MockIntake, MockNFT, NFTReceiver} from "./mocks/MockServices.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {OracleQuestion} from "../src/oracle/OracleQuestion.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract MadRewardsTest is MadFixture {
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

    function test_buyChecksBlackoutBudgetAndQuotedBounds() public {
        vm.expectRevert(MadRewards.InsufficientBudget.selector);
        rewards.buy();
        vm.deal(address(rewards), 10 ether);
        source.setBlackout(true);
        vm.expectRevert(MadRewards.Blackout.selector);
        rewards.buy();
        source.setBlackout(false);
        source.setFee(2 ether);
        uint256 request = rewards.buy();
        (address at, bool claimed) = rewards.purchases(request);
        assertEq(at, address(source));
        assertFalse(claimed);
        assertEq(source.acquisitions(request).purchaser, address(rewards));
        assertEq(source.lastMaxFee(), 2.001 ether);
        assertEq(source.lastSlippage(), 500);
        assertEq(address(rewards).balance, 7.99 ether);
    }

    function test_claimInsideWindowNoDuplicatesAndNoOwnershipTransfer() public {
        uint256 id = _buy();
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(id);
        source.fulfill(id);
        rewards.claim(id);
        assertEq(source.nft().ownerOf(id), address(rewards));
        assertEq(rewards.prizeCount(), 1);
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(id);
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(id + 100);
    }

    function test_zeroQuoteUsesNoEthAndStillRecordsPurchase() public {
        source.setFee(0);
        source.setVrfFee(0);
        assertEq(address(rewards).balance, 0);
        uint256 id = rewards.buy();
        assertEq(source.acquisitions(id).purchaser, address(rewards));
        assertEq(address(rewards).balance, 0);
        source.fulfill(id);
        rewards.claim(id);
        assertEq(source.nft().ownerOf(id), address(rewards));
    }

    function test_lateClaimRejectedAndOldSourceSnapshotSurvivesSettings() public {
        uint256 id = _buy();
        source.fulfill(id);
        MockFwaV2 other = new MockFwaV2();
        vm.prank(OWNER);
        rewards.setFwaV2(address(other));
        rewards.claim(id);
        assertEq(source.nft().ownerOf(id), address(rewards));
        vm.prank(OWNER);
        rewards.setFwaV2(address(source));
        uint256 late = rewards.buy();
        source.fulfill(late);
        vm.warp(vm.getBlockTimestamp() + 3600);
        vm.expectRevert(MadRewards.WindowClosed.selector);
        rewards.claim(late);
        (, bool claimed) = rewards.purchases(late);
        assertFalse(claimed);
    }

    function test_refundsReturnOnlyToNftBudgetIncludingHistoricalSource() public {
        uint256 id = _buy();
        uint256 before = address(rewards).balance;
        source.refund(id);
        MockFwaV2 replacement = new MockFwaV2();
        vm.prank(OWNER);
        rewards.setFwaV2(address(replacement));
        rewards.recoverRefund(address(source));
        assertEq(address(rewards).balance, before + 1 ether);
        assertEq(rewards.recoverRefund(address(source)), 0);
        vm.expectRevert(MadBase.InvalidAddress.selector);
        rewards.recoverRefund(alice);
    }

    function test_buyReentrancyRejectedAndArbitraryEthRejected() public {
        source.setAttack(true);
        _buy();
        assertFalse(source.reentered());
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(rewards).call{value: 1}("");
        assertFalse(ok);
    }

    function test_closeRequiresPrizeAgeAndMinimumAndCannotBypassHook() public {
        vm.expectRevert(MadRewards.NotReady.selector);
        rewards.closeRound();
        _prize();
        vm.expectRevert(MadToken.RoundNotReady.selector);
        rewards.closeRound();
        vm.roll(vm.getBlockNumber() + 7200);
        vm.expectRevert(MadToken.RoundNotReady.selector);
        rewards.closeRound();
        address target = address(0x1111);
        mad.transfer(target, 50_000 ether);
        vm.prank(alice, alice);
        mad.freeze(target);
        vm.expectRevert(MadToken.RoundNotReady.selector);
        rewards.closeRound();
        vm.expectRevert(MadBase.Unauthorized.selector);
        mad.closeRound();
        vm.expectRevert(MadBase.Unauthorized.selector);
        hook.closeRound();
        vm.prank(alice, alice);
        mad.freeze(bob);
        uint256 round = rewards.closeRound();
        assertEq(round, 1);
        assertEq(rewards.nextPrize(), 1);
        vm.expectRevert(MadRewards.NotReady.selector);
        rewards.closeRound();
    }

    function test_roundWindowEndsThisBlockAndNextRoundStartsNextBlock() public {
        uint256 first = vm.getBlockNumber();
        uint256 round = _close();
        MadRewards.Round memory r = _round(round);
        assertEq(r.first, first);
        assertEq(r.last, vm.getBlockNumber());
        assertEq(r.closedAt, vm.getBlockTimestamp());
        assertEq(r.savedLeader, alice);
        assertEq(mad.currentRound(), 2);
        vm.prank(carol, carol);
        vm.expectRevert(MadToken.RoundNotReady.selector);
        mad.freeze(bob);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(carol, carol);
        mad.freeze(bob);
        assertGt(mad.spent(2, carol), 0);
        assertEq(mad.leader(2), carol);
        assertEq(mad.leader(1), alice);
    }

    function test_fifoPrizesAndNoDoubleAssignment() public {
        uint256 first = _prize();
        uint256 second = _prize();
        vm.prank(alice, alice);
        mad.freeze(bob);
        vm.roll(vm.getBlockNumber() + 7200);
        rewards.closeRound();
        assertEq(_round(1).tokenId, first);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(carol, carol);
        mad.freeze(bob);
        vm.roll(vm.getBlockNumber() + 7200);
        rewards.closeRound();
        assertEq(_round(2).tokenId, second);
        assertEq(rewards.nextPrize(), 2);
    }

    function test_questionExactTextHashAndLivePrice() public {
        _close();
        vm.expectRevert(MadRewards.NotReady.selector);
        rewards.askWinner(1);
        vm.roll(vm.getBlockNumber() + 8);
        OracleQuestion.Question memory q = rewards.question(1);
        MadRewards.Round memory r = _round(1);
        string memory expected = string.concat(
            "Rank MAD freeze spending in round 1, token ",
            Strings.toHexString(address(mad)),
            ", Ethereum blocks ",
            Strings.toString(r.first),
            "-",
            Strings.toString(r.last),
            " inclusive. Sum its Frozen.cost in base units grouped by Frozen.by, highest first. Ties: first to total in block/transaction/log order."
        );
        assertEq(q.question, expected);
        assertEq(q.chainId, 1);
        assertEq(q.answerType, 4);
        assertEq(q.head, 1);
        assertFalse(q.panelEvidence);
        oracle.setPrice(2 ether);
        bytes32 id = rewards.askWinner(1);
        (, bytes32 hash,,,,) = rewards.requests(id);
        assertEq(hash, OracleQuestion.hash(q));
        assertEq(oracle.lastBody(), OracleQuestion.body(q, 30, 20, 3600));
        assertEq(oracle.lastPaid(), 2 ether);
        assertEq(imd.allowance(address(rewards), address(oracle)), 0);
        vm.expectRevert(MadRewards.LiveRequest.selector);
        rewards.askWinner(1);
    }

    function test_validOracleCallbackStoresOnlyAndThenAwards() public {
        bytes32 id = _ask();
        OracleAttestation.Attestation memory a = _answer(id, bob);
        (bool ok, bytes memory reason) = oracle.deliver(id, a, _sign(a));
        assertTrue(ok, string(reason));
        assertEq(_round(1).winner, bob);
        assertEq(_round(1).beneficiary, address(0));
        assertEq(source.nft().ownerOf(_round(1).tokenId), address(rewards));
        assertTrue(rewards.award(1));
        assertEq(_round(1).beneficiary, bob);
        assertEq(source.nft().ownerOf(_round(1).tokenId), bob);
        vm.expectRevert(MadRewards.AlreadyAwarded.selector);
        rewards.award(1);
        (ok,) = oracle.deliver(id, a, _sign(a));
        assertFalse(ok);
    }

    function test_tamperedWrongSenderHashChainWindowTypePanelAndSignatureRejected() public {
        bytes32 id = _ask();
        OracleAttestation.Attestation memory good = _answer(id, bob);
        bytes memory signature = _sign(good);
        vm.expectRevert(MadRewards.UnknownRequest.selector);
        rewards.onOracleResult(id, good, signature);
        for (uint256 variant; variant < 10; ++variant) {
            OracleAttestation.Attestation memory a = _answer(id, bob);
            if (variant == 0) a.questionHash = bytes32(uint256(9));
            if (variant == 1) a.chainId = 8453;
            if (variant == 2) a.fromBlock++;
            if (variant == 3) a.toBlock++;
            if (variant == 4) a.answerType = 1;
            if (variant == 5) a.panelSize = 29;
            if (variant == 6) a.quorum = 19;
            if (variant == 7) a.agreed = 19;
            if (variant == 8) a.expiresAt = a.issuedAt + 3601;
            if (variant == 9) a.requestId = bytes32(0);
            (bool ok,) = oracle.deliver(id, a, _sign(a));
            assertFalse(ok);
        }
        (bool badSig,) = oracle.deliver(id, good, hex"1234");
        assertFalse(badSig);
        assertEq(_round(1).winner, address(0));
    }

    function test_expiredFutureAndZeroWinnerRejected() public {
        bytes32 id = _ask();
        OracleAttestation.Attestation memory a = _answer(id, address(0));
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertFalse(ok);
        a = _answer(id, bob);
        bytes memory sig = _sign(a);
        vm.warp(vm.getBlockTimestamp() + 3601);
        (ok,) = oracle.deliver(id, a, sig);
        assertFalse(ok);
        a = _answer(id, bob);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 301);
        a.expiresAt = a.issuedAt + 3600;
        (ok,) = oracle.deliver(id, a, _sign(a));
        assertFalse(ok);
    }

    function test_failureAndSixHourTimeoutAllowRetryAndInvalidateOldAnswers() public {
        bytes32 first = _ask();
        OracleAttestation.Attestation memory a = _answer(first, bob);
        assertTrue(oracle.fail(first, 2));
        bytes32 second = rewards.askWinner(1);
        assertTrue(second != first);
        (bool ok,) = oracle.deliver(first, a, _sign(a));
        assertFalse(ok);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        bytes32 third = rewards.askWinner(1);
        assertTrue(third != second);
        a = _answer(second, bob);
        (ok,) = oracle.deliver(second, a, _sign(a));
        assertFalse(ok);
        a = _answer(third, bob);
        (ok,) = oracle.deliver(third, a, _sign(a));
        assertTrue(ok);
    }

    function test_requestTimeIntakeAndSignerSettingsRemainAuthoritative() public {
        bytes32 id = _ask();
        OracleAttestation.Attestation memory a = _answer(id, bob);
        MockIntake other = new MockIntake();
        vm.prank(OWNER);
        rewards.setOracleSettings(address(other), address(imd), bytes32("oracle.request@oracle-2"), carol);
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertTrue(ok);
        assertEq(_round(1).winner, bob);
    }

    function test_oracleUuidReplayAcrossRoundsAndWrongConsumerAreRejected() public {
        bytes32 first = _ask();
        OracleAttestation.Attestation memory a = _answer(first, bob);
        (bool ok,) = oracle.deliver(first, a, _sign(a));
        assertTrue(ok);
        bytes32 uuid = a.requestId;
        _prize();
        vm.prank(carol, carol);
        mad.freeze(bob);
        vm.roll(vm.getBlockNumber() + 7200);
        assertEq(rewards.closeRound(), 2);
        vm.roll(vm.getBlockNumber() + 8);
        bytes32 second = rewards.askWinner(2);
        a = _answer(second, carol);
        a.requestId = uuid;
        (ok,) = oracle.deliver(second, a, _sign(a));
        assertFalse(ok);

        a = _answer(second, carol);
        MadRewards otherConsumer = new MadRewards(mad, address(manager));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, otherConsumer.attestationDigest(a));
        (ok,) = oracle.deliver(second, a, abi.encodePacked(r, s, v));
        assertFalse(ok);
        (ok,) = oracle.deliver(second, a, _sign(a));
        assertTrue(ok);
    }

    function test_imdShortfallAndUnknownFailureCannotChangeRound() public {
        _close();
        vm.roll(vm.getBlockNumber() + 8);
        oracle.setPrice(101 ether);
        vm.expectRevert(MadRewards.InsufficientBudget.selector);
        rewards.askWinner(1);
        vm.prank(address(oracle));
        vm.expectRevert(MadRewards.UnknownRequest.selector);
        rewards.onOracleFailure(bytes32(uint256(9)), 2, bytes32("disagreed"), 0, 0, "");
        assertEq(_round(1).winner, address(0));
        assertEq(_round(1).requestId, bytes32(0));
    }

    function test_deadlineFallbackIrrevocableRejectsLateAnswersAndNewAsks() public {
        bytes32 id = _ask();
        MadRewards.Round memory r = _round(1);
        vm.warp(uint256(r.closedAt) + 72 hours);
        assertEq(rewards.beneficiaryOf(1), alice);
        OracleAttestation.Attestation memory a = _answer(id, bob);
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertFalse(ok);
        vm.expectRevert(MadRewards.WindowClosed.selector);
        rewards.askWinner(1);
        assertTrue(rewards.award(1));
        assertEq(_round(1).beneficiary, alice);
        assertEq(source.nft().ownerOf(r.tokenId), alice);
    }

    function test_answerJustBeforeDeadlineSurvivesDeadline() public {
        _close();
        vm.roll(vm.getBlockNumber() + 8);
        vm.warp(uint256(_round(1).closedAt) + 72 hours - 1);
        bytes32 id = rewards.askWinner(1);
        OracleAttestation.Attestation memory a = _answer(id, bob);
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertTrue(ok);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(rewards.beneficiaryOf(1), bob);
        rewards.award(1);
        assertEq(_round(1).beneficiary, bob);
    }

    function test_deliveryFailureKeepsNftAndBeneficiaryForRetryAndReentrancyFails() public {
        bytes32 id = _ask();
        NFTReceiver receiver = new NFTReceiver();
        OracleAttestation.Attestation memory a = _answer(id, address(receiver));
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertTrue(ok);
        assertFalse(rewards.award(1));
        assertEq(_round(1).beneficiary, address(receiver));
        assertEq(source.nft().ownerOf(_round(1).tokenId), address(rewards));
        vm.warp(vm.getBlockTimestamp() + 73 hours);
        receiver.setReject(false);
        receiver.setReenter(address(rewards), 1);
        assertTrue(rewards.award(1));
        assertFalse(receiver.reentered());
        assertEq(source.nft().ownerOf(_round(1).tokenId), address(receiver));
        vm.expectRevert(MadRewards.AlreadyAwarded.selector);
        rewards.award(1);
    }

    function test_lateDeliveredNftIsAdoptedAsPrizeOnlyOnceHeld() public {
        uint256 id = _buy();
        source.fulfill(id);
        vm.warp(vm.getBlockTimestamp() + 3600);
        // Still at the pool after the window: nothing to adopt, keepNFT is closed.
        vm.expectRevert(MadRewards.WindowClosed.selector);
        rewards.claim(id);
        source.finalizeUnsettled(id);
        assertEq(source.nft().ownerOf(id), address(rewards));
        assertEq(source.listings(id).status, 4);
        rewards.claim(id);
        assertEq(rewards.prizeCount(), 1);
        (, bool claimed) = rewards.purchases(id);
        assertTrue(claimed);
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(id);
        // The adopted NFT is a normal prize: it can be assigned and awarded.
        vm.prank(alice, alice);
        mad.freeze(bob);
        vm.roll(vm.getBlockNumber() + 7200);
        rewards.closeRound();
        assertEq(_round(1).tokenId, id);
    }

    function test_adoptRequiresOwnAllocationNotMereOwnership() public {
        // An NFT handed to the helper outside its own allocation is never adopted through a
        // listing allocated to someone else, and a never-fulfilled draw cannot adopt anything.
        uint256 id = _buy();
        source.nft().mint(address(rewards), 777);
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(id);
        assertEq(rewards.prizeCount(), 0);
    }

    function test_relistedFormerPrizeCanBeKeptAgainButNotWhileHeld() public {
        uint256 first = _buy();
        source.fulfill(first);
        rewards.claim(first);
        uint256 tokenId = first;
        // While the helper holds the prize, a second allocation of the same NFT cannot be kept.
        uint256 dup = _buy();
        source.fulfillWith(dup, tokenId);
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(dup);
        assertEq(rewards.prizeCount(), 1);
        vm.prank(alice, alice);
        mad.freeze(bob);
        vm.roll(vm.getBlockNumber() + 7200);
        rewards.closeRound();
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        assertTrue(rewards.award(1));
        assertEq(source.nft().ownerOf(tokenId), alice);
        assertFalse(rewards.registeredNFT(keccak256(abi.encode(address(source.nft()), tokenId))));
        // The winner relists the prize and the helper draws it again.
        MockNFT prizeNft = source.nft();
        vm.prank(alice);
        prizeNft.transferFrom(alice, address(source), tokenId);
        uint256 second = _buy();
        source.fulfillWith(second, tokenId);
        rewards.claim(second);
        assertEq(source.nft().ownerOf(tokenId), address(rewards));
        assertEq(rewards.prizeCount(), 2);
        assertTrue(rewards.registeredNFT(keccak256(abi.encode(address(source.nft()), tokenId))));
    }

    function test_deferredAwardKeepsRegistrationSoPrizeCannotBeReKept() public {
        bytes32 id = _ask();
        NFTReceiver receiver = new NFTReceiver();
        OracleAttestation.Attestation memory a = _answer(id, address(receiver));
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertTrue(ok);
        assertFalse(rewards.award(1));
        uint256 tokenId = _round(1).tokenId;
        assertTrue(rewards.registeredNFT(keccak256(abi.encode(address(source.nft()), tokenId))));
        uint256 again = _buy();
        source.fulfillWith(again, tokenId);
        vm.expectRevert(MadRewards.InvalidPurchase.selector);
        rewards.claim(again);
        assertEq(rewards.prizeCount(), 1);
    }

    function test_unsupersededAnswerAfterSixHoursStillAccepted() public {
        bytes32 id = _ask();
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        OracleAttestation.Attestation memory a = _answer(id, bob);
        a.issuedAt = uint64(vm.getBlockTimestamp() - 60);
        a.expiresAt = a.issuedAt + 3600;
        (bool ok,) = oracle.deliver(id, a, _sign(a));
        assertTrue(ok);
        assertEq(_round(1).winner, bob);
        (,,,,, bool active) = rewards.requests(id);
        assertFalse(active);
        vm.expectRevert(MadRewards.AlreadyAwarded.selector);
        rewards.askWinner(1);
    }

    function test_adminSettersRejectNonOwnerAndNoWithdrawOrResultSetter() public {
        vm.expectRevert(MadBase.Unauthorized.selector);
        rewards.setFwaV2(address(source));
        vm.expectRevert(MadBase.Unauthorized.selector);
        rewards.setAcquisitionBounds(0, 0);
        vm.prank(OWNER);
        (bool ok,) = address(rewards).call(abi.encodeWithSignature("withdraw(address,uint256)", OWNER, 1));
        assertFalse(ok);
        vm.prank(OWNER);
        (ok,) = address(rewards).call(abi.encodeWithSignature("setWinner(uint256,address)", 1, OWNER));
        assertFalse(ok);
    }

    function _buy() private returns (uint256) {
        vm.deal(address(rewards), 10 ether);
        return rewards.buy();
    }

    function _prize() private returns (uint256 id) {
        id = _buy();
        source.fulfill(id);
        rewards.claim(id);
    }

    function _close() private returns (uint256) {
        _prize();
        vm.prank(alice, alice);
        mad.freeze(bob);
        vm.roll(vm.getBlockNumber() + 7200);
        return rewards.closeRound();
    }

    function _ask() private returns (bytes32) {
        _close();
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
            keccak256(abi.encode("oracle uuid", id)),
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

contract SettlementBeforeEnableTest is MadFixture {
    function test_keepGiftedDrawBeforeTradingIsEnabled() public {
        MockFwaV2 source = new MockFwaV2();
        vm.prank(OWNER);
        rewards.setFwaV2(address(source));
        vm.deal(address(this), 2 ether);
        uint256[] memory ids = source.acquire{value: 1.01 ether}(address(rewards), 1, 1.001 ether, 0, 500);
        source.fulfill(ids[0]);
        assertFalse(mad.trading());
        rewards.claim(ids[0]);
        assertEq(source.nft().ownerOf(ids[0]), address(rewards));
        assertEq(rewards.prizeCount(), 1);
        vm.expectRevert(MadRewards.NotReady.selector);
        rewards.buy();
    }
}
