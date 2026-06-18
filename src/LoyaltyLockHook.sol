// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @title LoyaltyLockHook
/// @notice A Uniswap v4 hook that discourages "mercenary" liquidity by charging a
///         time-decaying exit fee when an LP withdraws. The fee starts at `maxFeeBps`
///         for a brand-new position and decays linearly to zero once the position has
///         been held for `vestDuration`. Quick churn is taxed; sticky LPs leave free.
///
/// @dev    On withdrawal the hook captures the exit fee as a positive hook `BalanceDelta`
///         (which reduces what the exiting LP receives) and immediately `donate()`s it to
///         the LPs still in range, so mercenary churn becomes yield for the LPs who stay.
///         The hook's own delta nets to zero: `donate` gives it a `-fee` delta and the
///         returned `+fee` hook delta cancels it. If the exiting LP is the *only* in-range
///         liquidity, there is nobody to reward, so no fee is charged (and the lone LP can
///         always exit).
contract LoyaltyLockHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    /// @notice Basis-points denominator (100% = 10_000 bps).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum exit fee (in bps) charged on a freshly added position.
    uint256 public immutable maxFeeBps;

    /// @notice Time (in seconds) over which the exit fee decays from `maxFeeBps` to 0.
    uint256 public immutable vestDuration;

    /// @notice Per-position deposit accounting.
    /// @param liquidity Currently tracked liquidity for the position.
    /// @param weightedTimestamp Liquidity-weighted average deposit time.
    struct Deposit {
        uint128 liquidity;
        uint64 weightedTimestamp;
    }

    /// @notice positionKey => deposit accounting.
    mapping(bytes32 positionKey => Deposit) public deposits;

    /// @notice Emitted on every withdrawal with the exit fee captured and donated to stayers.
    /// @param fee0 Amount of currency0 taken from the exiting LP and donated to in-range LPs.
    /// @param fee1 Amount of currency1 taken from the exiting LP and donated to in-range LPs.
    event LoyaltyFeeAssessed(
        PoolId indexed poolId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityRemoved,
        uint256 feeBps,
        uint256 fee0,
        uint256 fee1
    );

    error InvalidFeeConfig();

    /// @param _poolManager The canonical v4 PoolManager.
    /// @param _maxFeeBps Maximum exit fee in bps (must be <= 100%).
    /// @param _vestDuration Vesting period in seconds (must be > 0).
    constructor(IPoolManager _poolManager, uint256 _maxFeeBps, uint256 _vestDuration) BaseHook(_poolManager) {
        if (_maxFeeBps > BPS_DENOMINATOR || _vestDuration == 0) revert InvalidFeeConfig();
        maxFeeBps = _maxFeeBps;
        vestDuration = _vestDuration;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /// @notice Records (and liquidity-weights) the deposit time for a position on add.
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // `afterAddLiquidity` is only routed here for positive liquidity deltas.
        uint128 added = uint128(uint256(params.liquidityDelta));
        bytes32 positionKey = _positionKey(key.toId(), sender, params.tickLower, params.tickUpper, params.salt);

        Deposit storage d = deposits[positionKey];
        if (d.liquidity == 0) {
            d.weightedTimestamp = uint64(block.timestamp);
        } else {
            // Blend old and new deposit times, weighted by liquidity.
            uint256 newLiquidity = uint256(d.liquidity) + added;
            uint256 blended =
                (uint256(d.weightedTimestamp) * d.liquidity + block.timestamp * added) / newLiquidity;
            d.weightedTimestamp = uint64(blended);
        }
        d.liquidity += added;

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Captures the time-decaying exit fee on withdrawal and donates it to stayers.
    /// @param delta The tokens owed to the exiting LP (positive amounts on a removal).
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // `liquidityDelta` is negative for a removal.
        uint128 removed = uint128(uint256(-params.liquidityDelta));
        PoolId poolId = key.toId();
        bytes32 positionKey = _positionKey(poolId, sender, params.tickLower, params.tickUpper, params.salt);

        Deposit storage d = deposits[positionKey];
        uint256 age = block.timestamp - d.weightedTimestamp;
        uint256 feeBps = _feeBps(age);

        // Decrement tracked liquidity (clamp at zero for safety).
        d.liquidity = removed >= d.liquidity ? 0 : d.liquidity - removed;

        // Fee is taken from the (positive) token amounts owed to the exiting LP.
        uint256 fee0 = _feeOn(delta.amount0(), feeBps);
        uint256 fee1 = _feeOn(delta.amount1(), feeBps);

        // Only charge if there is remaining in-range liquidity to receive the donation.
        // (The exiting LP's liquidity is already removed from the active range at this point.)
        BalanceDelta hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        if ((fee0 > 0 || fee1 > 0) && poolManager.getLiquidity(poolId) > 0) {
            // Give the fee to the LPs still in range (creates a -fee delta for this hook)...
            poolManager.donate(key, fee0, fee1, "");
            // ...then claim the same amount back as our hook delta, netting the hook to zero
            // while reducing what the exiting LP receives by exactly `fee0`/`fee1`.
            hookDelta = toBalanceDelta(int128(uint128(fee0)), int128(uint128(fee1)));
        } else {
            fee0 = 0;
            fee1 = 0;
        }

        emit LoyaltyFeeAssessed(poolId, sender, params.tickLower, params.tickUpper, removed, feeBps, fee0, fee1);

        return (this.afterRemoveLiquidity.selector, hookDelta);
    }

    /// @dev Fee on a single currency's owed amount; ignores non-positive amounts.
    function _feeOn(int128 amountOwed, uint256 feeBps) internal pure returns (uint256) {
        if (amountOwed <= 0) return 0;
        return (uint256(uint128(amountOwed)) * feeBps) / BPS_DENOMINATOR;
    }

    /// @notice The exit fee (in bps) for a position of the given age.
    /// @dev Linear decay: `maxFeeBps` at age 0 down to 0 at `vestDuration` and beyond.
    function _feeBps(uint256 age) internal view returns (uint256) {
        if (age >= vestDuration) return 0;
        return (maxFeeBps * (vestDuration - age)) / vestDuration;
    }

    /// @notice Public view helper mirroring `_feeBps` for off-chain / test inspection.
    function quoteFeeBps(uint256 age) external view returns (uint256) {
        return _feeBps(age);
    }

    /// @dev Deterministic key for a position: (pool, owner, range, salt).
    function _positionKey(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, owner, tickLower, tickUpper, salt));
    }
}
