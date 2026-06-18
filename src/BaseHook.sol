// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title BaseHook
/// @notice Minimal base contract for Uniswap v4 hooks.
/// @dev Vendored locally because v4-periphery's `main` branch no longer ships a `BaseHook`.
///      Implements every `IHooks` callback as a revert, so a concrete hook only needs to
///      override the callbacks it actually uses. Enforces that the deployed address encodes
///      the permission flags returned by `getHookPermissions()`.
abstract contract BaseHook is IHooks {
    error NotPoolManager();
    error HookNotImplemented();

    /// @notice The pool manager that is allowed to call this hook.
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        validateHookAddress(this);
    }

    /// @notice Only the PoolManager may call the hook callbacks.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Returns which hook callbacks this contract implements.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    /// @dev Reverts during construction if the address flags don't match `getHookPermissions()`.
    function validateHookAddress(BaseHook _this) internal pure virtual {
        Hooks.validateHookPermissions(_this, getHookPermissions());
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
