// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFWAV2} from "../../src/interfaces/IFWAV2.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/oracle/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("Prize", "PRIZE") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract MockFwaV2 is IFWAV2 {
    MockNFT public nft = new MockNFT();
    uint256 public fee = 1 ether;
    uint256 public vrf = 0.01 ether;
    uint256 public settlementWindow = 3600;
    bool public isPurchaseBlackout;
    uint256 public sequence;
    uint256 public lastMaxFee;
    uint256 public lastSlippage;
    bool public attackBuy;
    bool public reentered;
    mapping(uint256 => Acquisition) private _acquisitions;
    mapping(uint256 => Listing) private _listings;
    mapping(address => uint256) public refunds;

    function setBlackout(bool yes) external {
        isPurchaseBlackout = yes;
    }

    function setFee(uint256 f) external {
        fee = f;
    }

    function setVrfFee(uint256 f) external {
        vrf = f;
    }

    function setAttack(bool yes) external {
        attackBuy = yes;
    }

    function quoteAcquisitionPrice() external view returns (uint256, uint256, uint256) {
        return (fee, vrf, fee + vrf);
    }

    function acquire(address purchaser, uint256 count, uint256 maxFee, uint256 minValue, uint256 slippage)
        external
        payable
        returns (uint256[] memory ids)
    {
        require(!isPurchaseBlackout && count == 1 && fee <= maxFee && minValue == 0);
        require(msg.value >= fee + vrf);
        lastMaxFee = maxFee;
        lastSlippage = slippage;
        uint256 id = ++sequence;
        _acquisitions[id] = Acquisition(purchaser, block.number, fee, 0, 1);
        ids = new uint256[](1);
        ids[0] = id;
        if (attackBuy) (reentered,) = msg.sender.call(abi.encodeWithSignature("buy()"));
        if (msg.value > fee + vrf) {
            (bool ok,) = msg.sender.call{value: msg.value - fee - vrf}("");
            require(ok);
        }
    }

    function acquisitions(uint256 id) external view returns (Acquisition memory) {
        return _acquisitions[id];
    }

    function listings(uint256 id) external view returns (Listing memory) {
        return _listings[id];
    }

    function fulfill(uint256 id) external {
        Acquisition storage a = _acquisitions[id];
        require(a.status == 1);
        a.status = 2;
        a.listingId = id;
        _listings[id] = Listing(
            address(nft), address(this), a.purchaser, id, 1, 1 ether, 0, 0, 0, uint64(block.timestamp), 2
        );
        nft.mint(address(this), id);
    }

    function refund(uint256 id) external {
        Acquisition storage a = _acquisitions[id];
        require(a.status == 1);
        a.status = 4;
        refunds[a.purchaser] += a.priceEscrowed;
    }

    function keepNFT(uint256 id) external {
        Listing storage l = _listings[id];
        require(
            l.purchaser == msg.sender && l.status == 2
                && block.timestamp < uint256(l.allocatedAt) + settlementWindow
        );
        l.status = 4;
        nft.safeTransferFrom(address(this), msg.sender, l.tokenId);
    }

    function withdrawAcquisitionRefund() external returns (uint256 amount) {
        amount = refunds[msg.sender];
        refunds[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

contract MockIntake is IIntake {
    uint256 public price = 0.5 ether;
    uint256 public sequence;
    bytes public lastBody;
    bytes32 public lastAction;
    uint256 public lastPaid;

    struct Call {
        address target;
        bytes4 selector;
        bytes4 failure;
    }
    mapping(bytes32 => Call) public calls;

    function setPrice(uint256 p) external {
        price = p;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 failure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(amount == price && msg.value == 0);
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        id = keccak256(abi.encode(address(this), ++sequence));
        calls[id] = Call(callback.target, callback.selector, failure);
        lastBody = body;
        lastAction = action;
        lastPaid = amount;
    }

    function deliver(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata sig)
        external
        returns (bool ok, bytes memory reason)
    {
        Call memory c = calls[id];
        (ok, reason) = c.target.call{gas: 200_000}(abi.encodeWithSelector(c.selector, id, a, sig));
    }

    function fail(bytes32 id, uint8 status) external returns (bool ok) {
        Call memory c = calls[id];
        (ok,) = c.target.call{gas: 200_000}(
            abi.encodeWithSelector(
                c.failure, id, status, bytes32("disagreed"), uint16(10), uint16(30), bytes("")
            )
        );
    }
}

contract NFTReceiver is IERC721Receiver {
    bool public rejects = true;
    address public rewards;
    uint256 public round;
    bool public reentered;

    function setReject(bool value) external {
        rejects = value;
    }

    function setReenter(address target, uint256 id) external {
        rewards = target;
        round = id;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!rejects, "reject NFT");
        if (rewards != address(0)) {
            (reentered,) = rewards.call(abi.encodeWithSignature("award(uint256)", round));
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
