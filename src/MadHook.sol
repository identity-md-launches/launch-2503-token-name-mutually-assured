// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MadBase} from "./MadBase.sol";
import {MadToken} from "./MadToken.sol";
import {MadRewards} from "./MadRewards.sol";
import {IFWAToken} from "./interfaces/IMad.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Canonical MAD/FWA pool fees. Only NFT revenue is converted to ETH.
contract MadHook is MadBase {
    using StateLibrary for IPoolManager;

    address public constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address public constant PLAYGROUND = 0x04454514ad6dc4C01d7064C308F8853183FDD39C;
    address public constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint256 private constant BPS = 10_000;
    uint256 public constant DECAY_SECONDS = 1800;
    IPoolManager public immutable poolManager;
    MadToken public immutable token;
    address public immutable factory;
    MadRewards public immutable rewards;
    PoolId public poolId;
    bool public initialized;
    bool public binding;
    mapping(address => bool) public approvedRouters;

    PoolKey public ethFwaPool;
    uint160 public conversionSqrtPriceLimitX96;
    uint256 public minEthPerFwaX18;
    uint256 public playgroundFwaClaims;
    uint256 public nftFwaClaims;
    uint256 public nftEthClaims;
    uint256 public totalBurned;

    struct PendingSwap {
        bytes32 context;
        bool buy;
        bool fwaSpecified;
        uint16 rate;
        uint256 base;
        uint256 fee;
        uint256 expectedRaw;
    }
    PendingSwap private _pending;
    uint8 private _unlockMode;

    error NotManager();
    error WrongPool();
    error AlreadyInitialized();
    error TradingClosed();
    error RouterNotApproved();
    error InvalidSwap();
    error PartialFill();
    error AmountTooLarge();
    error InvalidSettings();
    error Slippage();
    error NotConfigured();

    event Initialized(bytes32 indexed poolId);
    event RouterSet(address indexed router, bool approved);
    event EthFwaPoolSet(PoolKey key);
    event ConversionBoundsSet(uint160 sqrtPriceLimitX96, uint256 minEthPerFwaX18);
    event Fees(uint256 base, uint256 total, uint256 playground, uint256 nft, uint256 burned);
    event NFTConverted(uint256 fwaSpent, uint256 ethReceived);
    event ConversionDeferred(uint256 fwaClaims);
    event PlaygroundPaid(uint256 fwaAmount);
    event NFTBudgetRedeemed(uint256 ethAmount);

    constructor(IPoolManager manager_, MadToken token_, address factory_) {
        if (address(manager_) == address(0) || address(token_) == address(0) || factory_ == address(0)) {
            revert InvalidAddress();
        }
        poolManager = manager_;
        token = token_;
        factory = factory_;
        rewards = new MadRewards(token_, address(manager_));
        approvedRouters[UNIVERSAL_ROUTER] = true;
        ethFwaPool = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(FWA),
            0,
            60,
            IHooks(0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444)
        );
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert NotManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyManager
        nonReentrant
        returns (bytes4)
    {
        if (initialized) revert AlreadyInitialized();
        if (sender != factory || token.factory() != factory || token.owner() != owner) revert Unauthorized();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != address(this) || key.fee != 12500 || key.tickSpacing != 60 || c0 >= c1
                || !((c0 == address(token) && c1 == FWA) || (c1 == address(token) && c0 == FWA))
        ) revert WrongPool();
        initialized = true;
        poolId = key.toId();
        binding = true;
        token.bindHook(key, sender);
        binding = false;
        emit Initialized(PoolId.unwrap(poolId));
        return IHooks.beforeInitialize.selector;
    }

    function setRouters(address[] calldata routers, bool approved) external onlyOwner nonReentrant {
        for (uint256 i; i < routers.length; ++i) {
            address router = routers[i];
            if (
                router == address(this) || router == address(poolManager) || router == address(token)
                    || router == address(rewards) || router == address(0)
                    || (approved && router.code.length == 0)
            ) {
                revert InvalidAddress();
            }
            approvedRouters[router] = approved;
            emit RouterSet(router, approved);
        }
    }

    function setEthFwaPool(PoolKey calldata key) external onlyOwner nonReentrant {
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != FWA || key.fee >= 1_000_000
                || key.tickSpacing <= 0 || address(key.hooks) == address(this)
        ) revert InvalidSettings();
        ethFwaPool = key;
        emit EthFwaPoolSet(key);
    }

    /// @notice Absolute price protection, selected by the owner from the official market.
    /// @dev Until configured, NFT fees remain FWA claims; swaps and Playground payout still work.
    function setConversionBounds(uint160 sqrtPriceLimitX96, uint256 minimumEthPerFwaX18)
        external
        onlyOwner
        nonReentrant
    {
        if (
            sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE
                || minimumEthPerFwaX18 == 0
        ) revert InvalidSettings();
        conversionSqrtPriceLimitX96 = sqrtPriceLimitX96;
        minEthPerFwaX18 = minimumEthPerFwaX18;
        emit ConversionBoundsSet(sqrtPriceLimitX96, minimumEthPerFwaX18);
    }

    function feeBps() public view returns (uint16) {
        if (!token.trading()) return 9900;
        uint256 started = token.enabledAt();
        uint256 elapsed = block.timestamp > started ? block.timestamp - started : 0;
        if (elapsed >= DECAY_SECONDS) return 100;
        return uint16(9900 - (9800 * elapsed / DECAY_SECONDS));
    }

    /// @notice Gross-based floor fee; the two permanent shares differ by at most one wei.
    function quoteFee(uint256 gross, uint16 rate)
        public
        pure
        returns (uint256 fee, uint256 playground, uint256 nft, uint256 burned)
    {
        if (rate < 100 || rate > 9900) revert InvalidSettings();
        fee = FullMath.mulDiv(gross, rate, BPS);
        uint256 permanent = gross / 100;
        playground = permanent / 2;
        nft = permanent - playground;
        burned = fee - permanent;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (!token.trading()) revert TradingClosed();
        if (
            _pending.context != bytes32(0) || params.amountSpecified == 0
                || params.amountSpecified == type(int256).min
        ) revert InvalidSwap();
        bool buy = params.zeroForOne == (Currency.unwrap(key.currency0) == FWA);
        if (buy && !approvedRouters[sender]) revert RouterNotApproved();
        bool exactInput = params.amountSpecified < 0;
        bool specified = buy == exactInput;
        uint256 amount = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);
        _toInt128(amount);
        PendingSwap memory p;
        p.context = keccak256(abi.encode(sender, key, params));
        p.buy = buy;
        p.fwaSpecified = specified;
        p.rate = feeBps();
        if (specified) {
            if (buy) {
                p.base = amount; // Exact-input buy: amount is gross FWA, including fee.
                p.fee = FullMath.mulDiv(amount, p.rate, BPS);
                p.expectedRaw = amount - p.fee;
            } else {
                p.base = FullMath.mulDivRoundingUp(amount, BPS, BPS - p.rate);
                p.fee = p.base - amount; // Exact-output sell: gross up net FWA requested.
                p.expectedRaw = p.base;
            }
            _toInt128(p.expectedRaw);
        }
        _pending = p;
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(p.fee), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager nonReentrant returns (bytes4, int128) {
        _checkPool(key);
        PendingSwap memory p = _pending;
        if (p.context == bytes32(0) || p.context != keccak256(abi.encode(sender, key, params))) {
            revert InvalidSwap();
        }
        bool mad0 = Currency.unwrap(key.currency0) == address(token);
        int128 rawMad = mad0 ? delta.amount0() : delta.amount1();
        int128 rawFwa = mad0 ? delta.amount1() : delta.amount0();
        if (p.buy ? (rawFwa > 0 || rawMad < 0) : (rawFwa < 0 || rawMad > 0)) revert InvalidSwap();
        uint256 amount = uint256(rawFwa < 0 ? -int256(rawFwa) : int256(rawFwa));
        if (p.fwaSpecified) {
            // A specified-leg tax cannot be refunded through an unspecified-leg callback
            // without taxing MAD. Require a complete specified leg instead.
            if (amount != p.expectedRaw) revert PartialFill();
        } else if (p.buy) {
            p.base = FullMath.mulDivRoundingUp(amount, BPS, BPS - p.rate);
            p.fee = p.base - amount;
        } else {
            p.base = amount;
            p.fee = FullMath.mulDiv(amount, p.rate, BPS);
        }
        // Fees never touch this delta. Net buys and sells before any physical MAD settlement.
        token.accountTransferDelta(rawMad);
        _collect(p.base, p.fee);
        _tryConvertNFT();
        delete _pending;
        return (IHooks.afterSwap.selector, p.fwaSpecified ? int128(0) : _toInt128(p.fee));
    }

    function _collect(uint256 base, uint256 fee) private {
        uint256 permanent = base / 100;
        uint256 playground = permanent / 2;
        uint256 nft = permanent - playground;
        uint256 excess = fee - permanent;
        Currency fwa = Currency.wrap(FWA);
        playgroundFwaClaims += playground;
        nftFwaClaims += nft;
        if (permanent != 0) poolManager.mint(address(this), fwa.toId(), permanent);
        if (excess != 0) {
            totalBurned += excess;
            poolManager.take(fwa, address(this), excess);
            IFWAToken(FWA).burn(excess);
        }
        emit Fees(base, fee, playground, nft, excess);
    }

    function _tryConvertNFT() private {
        if (nftFwaClaims == 0 || conversionSqrtPriceLimitX96 == 0) return;
        // Isolate a bounded sale: any failure reverts its pool changes and leaves its claims.
        try this.executeNFTConversion() {}
        catch {
            emit ConversionDeferred(nftFwaClaims);
        }
    }

    /// @dev Self-call only, inside the swap's current unlock, for atomic catch-and-defer.
    function executeNFTConversion() external {
        if (msg.sender != address(this) || _pending.context == bytes32(0)) revert Unauthorized();
        PoolKey memory key = ethFwaPool;
        (uint160 current,,,) = poolManager.getSlot0(key.toId());
        uint160 limit = conversionSqrtPriceLimitX96;
        if (current == 0 || current >= limit) revert NotConfigured();
        uint256 amount = nftFwaClaims;
        if (amount > uint256(uint128(type(int128).max))) amount = uint256(uint128(type(int128).max));
        BalanceDelta d = poolManager.swap(key, SwapParams(false, -int256(amount), limit), "");
        if (d.amount0() <= 0 || d.amount1() >= 0) revert Slippage();
        uint256 used = uint256(-int256(d.amount1()));
        uint256 received = uint256(uint128(d.amount0()));
        if (used > amount || received < FullMath.mulDivRoundingUp(used, minEthPerFwaX18, 1 ether)) {
            revert Slippage();
        }
        nftFwaClaims -= used;
        poolManager.burn(address(this), Currency.wrap(FWA).toId(), used);
        if (address(poolManager).balance >= received) {
            poolManager.take(Currency.wrap(address(0)), address(rewards), received);
        } else {
            nftEthClaims += received;
            poolManager.mint(address(this), 0, received);
        }
        emit NFTConverted(used, received);
    }

    /// @notice Pays only Playground's FWA claims, directly from the manager to its fixed receiver.
    function payout() external nonReentrant returns (uint256 paid) {
        _unlockMode = 1;
        paid = abi.decode(poolManager.unlock(""), (uint256));
    }

    /// @notice Redeems only NFT-budget ETH claims to the rewards helper.
    function redeemNFTBudget() external nonReentrant returns (uint256 paid) {
        _unlockMode = 2;
        paid = abi.decode(poolManager.unlock(""), (uint256));
    }

    function unlockCallback(bytes calldata) external onlyManager returns (bytes memory) {
        uint8 mode = _unlockMode;
        if (mode == 0) revert Unauthorized();
        _unlockMode = 0;
        uint256 paid;
        if (mode == 1) {
            paid = playgroundFwaClaims;
            uint256 liquid = IFWAToken(FWA).balanceOf(address(poolManager));
            if (paid > liquid) paid = liquid;
            playgroundFwaClaims -= paid;
            if (paid != 0) {
                poolManager.burn(address(this), Currency.wrap(FWA).toId(), paid);
                poolManager.take(Currency.wrap(FWA), PLAYGROUND, paid);
            }
            emit PlaygroundPaid(paid);
        } else {
            paid = nftEthClaims;
            if (paid > address(poolManager).balance) paid = address(poolManager).balance;
            nftEthClaims -= paid;
            if (paid != 0) {
                poolManager.burn(address(this), 0, paid);
                poolManager.take(Currency.wrap(address(0)), address(rewards), paid);
            }
            emit NFTBudgetRedeemed(paid);
        }
        return abi.encode(paid);
    }

    function closeRound() external returns (uint256 round, uint64 first, uint64 last, address best) {
        if (msg.sender != address(rewards)) revert Unauthorized();
        return token.closeRound();
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    function _toInt128(uint256 amount) private pure returns (int128) {
        if (amount > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(uint128(amount));
    }
}
