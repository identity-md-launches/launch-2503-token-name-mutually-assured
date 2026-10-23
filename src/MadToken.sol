// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {MadBase} from "./MadBase.sol";
import {IMadHook, ISwarm, IDistributorRegistry} from "./interfaces/IMad.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice MAD's paid freezes and canonical-pool transfer gate.
/// @dev Gate and signed settlement accounting adapted from token-works/ERC20T (MIT).
contract MadToken is ERC20, MadBase {
    address public constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address public constant registry = 0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D;
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant MIN_ROUND_BLOCKS = 7200;
    uint256 public constant MIN_LEADER_SPENT = 1000 ether;
    bytes32 private constant BOOTSTRAP_SLOT = keccak256("MAD.constructor.bootstrap");
    bytes32 private constant NET_SLOT = keccak256("MAD.signed.swap.net");

    address public immutable factory;
    address public hook;
    address public poolManager;
    address public helper;
    address public swarm;
    PoolId public poolId;
    bool public trading;
    bool public useGlobalDistributors = true;
    uint64 public enabledAt;
    uint256 public currentRound;

    struct Blocks {
        uint64 first;
        uint64 last;
    }
    mapping(uint256 => Blocks) public roundBlocks;
    mapping(uint256 => mapping(address => uint256)) public spent;
    mapping(uint256 => address) public leader;
    mapping(address => uint64) public frozenUntil;
    mapping(address => bool) public localDistributors;

    // A one-use exact internal payment, consumed before touching balances. No external call
    // occurs between arming it and consumption. This is never an externally callable burn.
    bytes32 private _freezePayment;

    error NotBootstrapping();
    error AlreadyBound();
    error BadBinding();
    error TradingClosed();
    error AlreadyTrading();
    error SwarmLocked();
    error SenderFrozen();
    error InvalidTransfer();
    error InvalidTarget();
    error WalletOnly();
    error ZeroCost();
    error RoundNotReady();

    event Bound(address indexed hook, address indexed manager, address helper, bytes32 poolId);
    event SwarmCaptured(address indexed swarm);
    event TradingEnabled(uint64 timestamp, uint64 firstBlock);
    event DistributorSet(address indexed account, bool allowed);
    event GlobalDistributorsSet(bool enabled);
    event Frozen(address indexed by, address indexed target, uint256 cost, uint64 until);
    event RoundClosed(uint256 indexed round, uint64 first, uint64 last, address leader);
    event TransferDeltaAccounted(int128 delta, int256 net);

    constructor() {
        factory = msg.sender;
        bytes32 slot = BOOTSTRAP_SLOT;
        assembly ("memory-safe") { tstore(slot, 1) }
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    function name() public pure override returns (string memory) {
        return "Mutually Assured Destruction";
    }

    function symbol() public pure override returns (string memory) {
        return "MAD";
    }

    function bootstrapping() public view returns (bool yes) {
        bytes32 slot = BOOTSTRAP_SLOT;
        assembly ("memory-safe") { yes := tload(slot) }
    }

    /// @dev The factory must deploy and initialize atomically. The transient constructor
    /// capability is essential: matching metadata alone can never bind an existing token.
    function bindHook(PoolKey calldata key, address initializer) external {
        if (hook != address(0)) revert AlreadyBound();
        if (!bootstrapping()) revert NotBootstrapping();
        IMadHook h = IMadHook(msg.sender);
        address manager = address(h.poolManager());
        address reward = h.rewards();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            initializer != factory || h.factory() != factory || h.owner() != owner
                || h.token() != address(this) || !h.binding() || msg.sender != address(key.hooks)
                || msg.sender.code.length == 0 || manager == address(0) || reward == address(0)
                || reward == manager || reward == msg.sender || key.fee != 12500 || key.tickSpacing != 60
                || c0 >= c1 || !((c0 == address(this) && c1 == FWA) || (c1 == address(this) && c0 == FWA))
        ) revert BadBinding();
        hook = msg.sender;
        poolManager = manager;
        helper = reward;
        poolId = key.toId();
        bytes32 slot = BOOTSTRAP_SLOT;
        assembly ("memory-safe") { tstore(slot, 0) }
        emit Bound(hook, manager, reward, PoolId.unwrap(poolId));
    }

    function enableTrading() external onlyOwner {
        if (trading) revert AlreadyTrading();
        if (hook == address(0)) revert BadBinding();
        trading = true;
        enabledAt = uint64(block.timestamp);
        currentRound = 1;
        roundBlocks[1].first = uint64(block.number);
        emit TradingEnabled(enabledAt, uint64(block.number));
    }

    function setDistributors(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            if (_core(a) || (allowed && a.code.length == 0)) revert InvalidAddress();
            localDistributors[a] = allowed;
            emit DistributorSet(a, allowed);
        }
    }

    function setUseGlobalDistributors(bool enabled) external onlyOwner {
        useGlobalDistributors = enabled;
        emit GlobalDistributorsSet(enabled);
    }

    function isDistributor(address a) public view returns (bool) {
        if (_core(a)) return false;
        if (a == factory || a == owner || a == swarm || localDistributors[a]) return true;
        if (useGlobalDistributors) {
            // The registry may not yet know a launch. Its absence cannot prevent seeding.
            (bool ok, bytes memory data) =
                registry.staticcall(abi.encodeCall(IDistributorRegistry.isGlobalDistributor, (a)));
            if (ok && data.length == 32) return abi.decode(data, (bool));
        }
        return false;
    }

    function freezeCost(address target) public view returns (uint256) {
        return balanceOf(target) / 100;
    }

    function freeze(address target) external nonReentrant {
        if (!trading) revert TradingClosed();
        if (msg.sender != tx.origin || msg.sender.code.length != 0) revert WalletOnly();
        if (_core(target) || target == msg.sender || isDistributor(target)) revert InvalidTarget();
        uint256 round = currentRound;
        if (block.number < roundBlocks[round].first) revert RoundNotReady();
        uint256 cost = freezeCost(target);
        if (cost == 0) revert ZeroCost();
        if (balanceOf(msg.sender) < cost) revert InsufficientBalance();
        uint64 until = uint64(block.timestamp + 24 hours);
        frozenUntil[target] = until;
        uint256 total = spent[round][msg.sender] + cost;
        spent[round][msg.sender] = total;
        if (total > spent[round][leader[round]]) leader[round] = msg.sender;
        uint256 burned = cost / 2;
        _freezePayment = keccak256(abi.encode(msg.sender, address(0), burned));
        _burn(msg.sender, burned);
        _freezePayment = keccak256(abi.encode(msg.sender, target, cost - burned));
        _transfer(msg.sender, target, cost - burned);
        emit Frozen(msg.sender, target, cost, until);
    }

    function closeRound() external returns (uint256 round, uint64 first, uint64 last, address best) {
        if (msg.sender != hook) revert Unauthorized();
        if (!trading) revert TradingClosed();
        round = currentRound;
        first = roundBlocks[round].first;
        best = leader[round];
        if (block.number < uint256(first) + MIN_ROUND_BLOCKS || spent[round][best] < MIN_LEADER_SPENT) {
            revert RoundNotReady();
        }
        last = uint64(block.number);
        roundBlocks[round].last = last;
        currentRound = round + 1;
        roundBlocks[round + 1].first = last + 1;
        emit RoundClosed(round, first, last, best);
    }

    /// @notice Only the canonical hook can record a raw pool MAD delta.
    function accountTransferDelta(int128 delta) external {
        if (msg.sender != hook || hook == address(0)) revert Unauthorized();
        int256 net = getNetTransferAllowance() + int256(delta);
        bytes32 slot = NET_SLOT;
        assembly ("memory-safe") { tstore(slot, net) }
        emit TransferDeltaAccounted(delta, net);
    }

    function getNetTransferAllowance() public view returns (int256 net) {
        bytes32 slot = NET_SLOT;
        assembly ("memory-safe") { net := tload(slot) }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from == address(0)) return; // The constructor is the only mint path.
        if (_freezePayment != bytes32(0) && _freezePayment == keccak256(abi.encode(from, to, amount))) {
            if (from != msg.sender) revert InvalidTransfer();
            delete _freezePayment;
            return;
        }
        if (from == swarm && !trading) revert SwarmLocked();
        if (frozenUntil[from] > block.timestamp) revert SenderFrozen();

        address manager = poolManager;
        if (manager != address(0) && (from == manager || to == manager)) {
            // Factory liquidity, remainder, and fee collection remain available permanently.
            if (from == factory || to == factory) return;
            if (!trading) revert TradingClosed();
            bool outgoing = from == manager;
            if (outgoing && to.code.length != 0 && !isDistributor(to)) revert InvalidTransfer();
            int256 net = getNetTransferAllowance();
            if (outgoing) {
                if (net < 0 || amount > uint256(net)) revert InvalidTransfer();
                net -= int256(amount);
            } else {
                if (net > 0 || amount > uint256(-net)) revert InvalidTransfer();
                net += int256(amount);
            }
            bytes32 slot = NET_SLOT;
            assembly ("memory-safe") { tstore(slot, net) }
            return;
        }
        if (
            from == factory && hook == address(0) && swarm == address(0) && to.code.length != 0 && amount != 0
        ) {
            _captureSwarm(to);
        }
        if (isDistributor(from) || isDistributor(to)) return;
        if (!trading) revert TradingClosed();
        if (
            msg.sender != from || msg.sender != tx.origin || from.code.length != 0 || to.code.length != 0
                || to == address(0)
        ) {
            revert InvalidTransfer();
        }
    }

    function _captureSwarm(address candidate) private {
        try ISwarm(candidate).token() returns (address t) {
            if (t != address(this)) return;
            try ISwarm(candidate).opener() returns (address f) {
                if (f == factory) {
                    swarm = candidate;
                    emit SwarmCaptured(candidate);
                }
            } catch {}
        } catch {}
    }

    function _core(address a) private view returns (bool) {
        return a == address(0) || a == address(this) || a == poolManager || a == hook || a == helper;
    }

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}
