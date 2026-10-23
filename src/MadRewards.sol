// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MadBase} from "./MadBase.sol";
import {MadToken} from "./MadToken.sol";
import {IMadHook} from "./interfaces/IMad.sol";
import {IFWAV2} from "./interfaces/IFWAV2.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./oracle/OracleAttestation.sol";
import {OracleQuestion} from "./oracle/OracleQuestion.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice NFT budget, acquisition settlement, and asynchronous round awards.
/// @dev Deployed only by the hook constructor. Fee claims stay with the hook.
contract MadRewards is MadBase, OracleAttestationConsumer, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint64 public constant WINNER_DEADLINE = 72 hours;
    uint64 public constant REQUEST_TIMEOUT = 6 hours;
    uint16 public constant PANEL_SIZE = 30;
    uint16 public constant QUORUM = 20;
    uint64 public constant VALID_FOR = 3600;
    address public immutable hook;
    address public immutable poolManager;
    MadToken public immutable token;
    IFWAV2 public fwaV2 = IFWAV2(0x958C41181182e76F221331b2755b77D9e1426A98);
    IIntake public intake = IIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
    IERC20 public imd = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    bytes32 public action = bytes32("oracle.request@oracle-1");
    uint256 public acquisitionFeeMargin = 0.001 ether;
    uint256 public acquisitionSlippageBps = 500;
    mapping(address => bool) public knownFwaPool;

    struct Purchase {
        address source;
        bool claimed;
    }
    mapping(uint256 => Purchase) public purchases;

    struct Prize {
        address collection;
        uint256 tokenId;
    }
    Prize[] public keptNFTs;
    uint256 public nextPrize;
    mapping(bytes32 => bool) public registeredNFT;

    struct Round {
        uint64 first;
        uint64 last;
        uint64 closedAt;
        address savedLeader;
        address collection;
        uint256 tokenId;
        address winner;
        address beneficiary;
        bool awarded;
        bytes32 requestId;
    }
    mapping(uint256 => Round) public rounds;

    struct Request {
        uint256 round;
        bytes32 questionHash;
        address intake;
        address signer;
        uint64 askedAt;
        bool active;
    }
    mapping(bytes32 => Request) public requests;

    error NotReady();
    error InsufficientBudget();
    error Blackout();
    error InvalidPurchase();
    error WindowClosed();
    error InvalidSettings();
    error UnknownRequest();
    error InvalidAttestation();
    error LiveRequest();
    error AlreadyAwarded();
    error WrongETHSource();

    event FwaV2Set(address indexed pool);
    event AcquisitionBoundsSet(uint256 margin, uint256 slippageBps);
    event OracleSettingsSet(address intake, address imd, bytes32 action, address signer);
    event Bought(uint256 indexed requestId, address indexed source, uint256 paid);
    event Kept(uint256 indexed requestId, address indexed collection, uint256 tokenId);
    event RefundRecovered(address indexed source, uint256 amount);
    event Closed(
        uint256 indexed round, uint64 first, uint64 last, address leader, address collection, uint256 tokenId
    );
    event Asked(uint256 indexed round, bytes32 indexed requestId, bytes32 questionHash);
    event AskInvalidated(bytes32 indexed requestId);
    event OracleFailed(bytes32 indexed requestId, uint8 status, bytes32 reason);
    event WinnerAccepted(uint256 indexed round, address indexed winner);
    event BeneficiaryFixed(uint256 indexed round, address indexed beneficiary);
    event Awarded(uint256 indexed round, address indexed beneficiary);
    event AwardDeferred(uint256 indexed round, address indexed beneficiary);

    constructor(MadToken token_, address manager_)
        OracleAttestationConsumer(0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982)
    {
        token = token_;
        hook = msg.sender;
        poolManager = manager_;
        knownFwaPool[address(fwaV2)] = true;
    }

    function setFwaV2(address pool) external onlyOwner nonReentrant {
        if (pool.code.length == 0) revert InvalidAddress();
        fwaV2 = IFWAV2(pool);
        knownFwaPool[pool] = true;
        emit FwaV2Set(pool);
    }

    function setAcquisitionBounds(uint256 margin, uint256 slippageBps) external onlyOwner nonReentrant {
        if (slippageBps > 10_000) revert InvalidSettings();
        acquisitionFeeMargin = margin;
        acquisitionSlippageBps = slippageBps;
        emit AcquisitionBoundsSet(margin, slippageBps);
    }

    /// @dev Applies to future requests. Every outstanding request retains its original authority.
    function setOracleSettings(address intake_, address imd_, bytes32 action_, address signer_)
        external
        onlyOwner
        nonReentrant
    {
        if (
            intake_.code.length == 0 || imd_.code.length == 0 || signer_ == address(0)
                || action_ == bytes32(0)
        ) {
            revert InvalidSettings();
        }
        intake = IIntake(intake_);
        imd = IERC20(imd_);
        action = action_;
        _setOracleSigner(signer_);
        emit OracleSettingsSet(intake_, imd_, action_, signer_);
    }

    function budget() external view returns (uint256) {
        return address(this).balance;
    }

    function prizeCount() external view returns (uint256) {
        return keptNFTs.length;
    }

    function buy() external nonReentrant returns (uint256 requestId) {
        if (!token.trading()) revert NotReady();
        IFWAV2 source = fwaV2;
        if (source.isPurchaseBlackout()) revert Blackout();
        IMadHook(hook).redeemNFTBudget();
        (uint256 fee,, uint256 total) = source.quoteAcquisitionPrice();
        if (total > address(this).balance) revert InsufficientBudget();
        uint256[] memory ids = source.acquire{value: total}(
            address(this), 1, fee + acquisitionFeeMargin, 0, acquisitionSlippageBps
        );
        if (ids.length != 1 || purchases[ids[0]].source != address(0)) revert InvalidPurchase();
        requestId = ids[0];
        purchases[requestId] = Purchase(address(source), false);
        emit Bought(requestId, address(source), total);
    }

    /// @notice Anyone may settle a fulfilled draw, including before trading is enabled.
    function claim(uint256 requestId) external nonReentrant {
        Purchase storage p = purchases[requestId];
        if (p.claimed) revert InvalidPurchase();
        // A third party can also buy a draw for this helper. Adopt such a draw only from
        // the configured pool and only when its authenticated purchaser is this helper.
        // This permits settlement before enablement without exposing a purchase bypass.
        IFWAV2 source = p.source == address(0) ? fwaV2 : IFWAV2(p.source);
        IFWAV2.Acquisition memory a = source.acquisitions(requestId);
        if (a.purchaser != address(this) || a.status != 2 || a.listingId == 0) revert InvalidPurchase();
        IFWAV2.Listing memory listing = source.listings(a.listingId);
        if (listing.purchaser != address(this) || listing.status != 2 || listing.collection.code.length == 0)
        {
            revert InvalidPurchase();
        }
        if (block.timestamp >= uint256(listing.allocatedAt) + source.settlementWindow()) {
            revert WindowClosed();
        }
        bytes32 nft = keccak256(abi.encode(listing.collection, listing.tokenId));
        if (registeredNFT[nft]) revert InvalidPurchase();
        p.source = address(source);
        p.claimed = true;
        registeredNFT[nft] = true;
        source.keepNFT(a.listingId);
        if (IERC721(listing.collection).ownerOf(listing.tokenId) != address(this)) revert InvalidPurchase();
        keptNFTs.push(Prize(listing.collection, listing.tokenId));
        emit Kept(requestId, listing.collection, listing.tokenId);
    }

    function recoverRefund(address source) external nonReentrant returns (uint256 amount) {
        if (!knownFwaPool[source]) revert InvalidAddress();
        amount = IFWAV2(source).withdrawAcquisitionRefund();
        emit RefundRecovered(source, amount);
    }

    function closeRound() external nonReentrant returns (uint256 round) {
        if (nextPrize >= keptNFTs.length) revert NotReady();
        Prize memory prize = keptNFTs[nextPrize++];
        uint64 first;
        uint64 last;
        address best;
        (round, first, last, best) = IMadHook(hook).closeRound();
        Round storage r = rounds[round];
        if (r.savedLeader != address(0)) revert NotReady();
        r.first = first;
        r.last = last;
        r.closedAt = uint64(block.timestamp);
        r.savedLeader = best;
        r.collection = prize.collection;
        r.tokenId = prize.tokenId;
        emit Closed(round, first, last, best, prize.collection, prize.tokenId);
    }

    function question(uint256 round) public view returns (OracleQuestion.Question memory q) {
        Round storage r = rounds[round];
        if (r.savedLeader == address(0)) revert NotReady();
        q.question = string.concat(
            "Rank MAD freeze spending in round ",
            Strings.toString(round),
            ", token ",
            Strings.toHexString(address(token)),
            ", Ethereum blocks ",
            Strings.toString(r.first),
            "-",
            Strings.toString(r.last),
            " inclusive. Sum its Frozen.cost in base units grouped by Frozen.by, highest first. Ties: first to total in block/transaction/log order."
        );
        q.chainId = 1;
        q.fromBlock = r.first;
        q.toBlock = r.last;
        q.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        q.head = 1;
        q.definitions = new OracleQuestion.Definition[](0);
    }

    function questionBody(uint256 round) external view returns (bytes memory body, bytes32 questionHash) {
        OracleQuestion.Question memory q = question(round);
        return (OracleQuestion.body(q, PANEL_SIZE, QUORUM, VALID_FOR), OracleQuestion.hash(q));
    }

    function askWinner(uint256 round) external nonReentrant returns (bytes32 id) {
        Round storage r = rounds[round];
        if (block.chainid != 1 || r.savedLeader == address(0) || block.number < uint256(r.last) + 8) {
            revert NotReady();
        }
        if (block.timestamp >= uint256(r.closedAt) + WINNER_DEADLINE) revert WindowClosed();
        if (r.winner != address(0) || r.beneficiary != address(0) || r.awarded) revert AlreadyAwarded();
        Request storage old = requests[r.requestId];
        if (old.active) {
            if (block.timestamp < uint256(old.askedAt) + REQUEST_TIMEOUT) revert LiveRequest();
            old.active = false;
            emit AskInvalidated(r.requestId);
        }
        OracleQuestion.Question memory q = question(round);
        bytes32 hash = OracleQuestion.hash(q);
        IIntake target = intake;
        IERC20 asset = imd;
        uint256 price = target.priceOf(action, address(asset));
        if (asset.balanceOf(address(this)) < price) revert InsufficientBudget();
        asset.forceApprove(address(target), price);
        id = target.requestWithFailure(
            action,
            OracleQuestion.body(q, PANEL_SIZE, QUORUM, VALID_FOR),
            IIntake.Callback(address(this), this.onOracleResult.selector),
            this.onOracleFailure.selector,
            address(asset),
            price
        );
        asset.forceApprove(address(target), 0);
        if (id == bytes32(0) || requests[id].round != 0) revert InvalidPurchase();
        requests[id] = Request(round, hash, address(target), oracleSigner, uint64(block.timestamp), true);
        r.requestId = id;
        emit Asked(round, id, hash);
    }

    function onOracleResult(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        Request storage p = requests[id];
        Round storage r = rounds[p.round];
        if (!p.active || msg.sender != p.intake || r.requestId != id) revert UnknownRequest();
        if (
            block.timestamp >= uint256(r.closedAt) + WINNER_DEADLINE
                || block.timestamp >= uint256(p.askedAt) + REQUEST_TIMEOUT
        ) revert WindowClosed();
        if (r.winner != address(0) || r.beneficiary != address(0) || r.awarded) revert AlreadyAwarded();
        if (
            a.questionHash != p.questionHash || a.chainId != 1 || block.chainid != 1 || a.fromBlock != r.first
                || a.toBlock != r.last || a.requestId == bytes32(0) || a.panelSize < PANEL_SIZE
                || a.quorum < QUORUM || a.quorum > a.panelSize || a.agreed < a.quorum
                || a.agreed > a.panelSize || a.issuedAt < p.askedAt || a.expiresAt <= a.issuedAt
                || a.expiresAt > uint256(a.issuedAt) + VALID_FOR
        ) {
            revert InvalidAttestation();
        }
        if (block.timestamp > a.expiresAt) revert AttestationExpired(a.expiresAt);
        if (a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE) revert AttestationNotYetValid(a.issuedAt);
        if (!SignatureChecker.isValidSignatureNow(p.signer, attestationDigest(a), signature)) {
            revert BadSignature();
        }
        address[] memory answers = decodeAddressList(a);
        if (answers.length != 1 || answers[0] == address(0)) revert InvalidAttestation();
        _consume(a.requestId);
        p.active = false;
        r.winner = answers[0];
        emit WinnerAccepted(p.round, answers[0]);
    }

    function onOracleFailure(bytes32 id, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
        nonReentrant
    {
        Request storage p = requests[id];
        Round storage r = rounds[p.round];
        if (!p.active || msg.sender != p.intake || r.requestId != id) revert UnknownRequest();
        if (status != 1 && status != 2) revert InvalidAttestation();
        p.active = false;
        emit OracleFailed(id, status, reason);
    }

    function beneficiaryOf(uint256 round) public view returns (address) {
        Round storage r = rounds[round];
        if (r.beneficiary != address(0)) return r.beneficiary;
        if (r.winner != address(0)) return r.winner;
        if (block.timestamp >= uint256(r.closedAt) + WINNER_DEADLINE) return r.savedLeader;
        return address(0);
    }

    /// @notice Delivery failure never reopens winner selection or loses the chosen beneficiary.
    function award(uint256 round) external nonReentrant returns (bool delivered) {
        Round storage r = rounds[round];
        if (r.awarded) revert AlreadyAwarded();
        address to = beneficiaryOf(round);
        if (to == address(0)) revert NotReady();
        if (r.beneficiary == address(0)) {
            r.beneficiary = to;
            requests[r.requestId].active = false;
            emit BeneficiaryFixed(round, to);
        }
        r.awarded = true;
        try IERC721(r.collection).safeTransferFrom(address(this), to, r.tokenId) {
            delivered = true;
            emit Awarded(round, to);
        } catch {
            r.awarded = false;
            emit AwardDeferred(round, to);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        if (msg.sender != poolManager && msg.sender != hook && !knownFwaPool[msg.sender]) {
            revert WrongETHSource();
        }
    }
}
