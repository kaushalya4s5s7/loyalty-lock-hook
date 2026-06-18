// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {LoyaltyLockHook} from "../src/LoyaltyLockHook.sol";

/// @notice Deploys LoyaltyLockHook to a CREATE2 address whose low bits encode the hook's
///         permission flags. If `POOL_MANAGER` is unset (e.g. local anvil) a fresh
///         PoolManager is deployed first.
///
/// Env:
///   PRIVATE_KEY   - deployer key (required)
///   POOL_MANAGER  - canonical v4 PoolManager (optional; deployed fresh if 0/unset)
///   MAX_FEE_BPS   - max exit fee in bps (default 300)
///   VEST_DURATION - vesting seconds (default 2592000 = 30 days)
contract DeployLoyaltyLockHook is Script {
    // Canonical deterministic CREATE2 factory used by `new{salt:}` in forge scripts.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (LoyaltyLockHook hook, IPoolManager poolManager) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 maxFeeBps = vm.envOr("MAX_FEE_BPS", uint256(300));
        uint256 vestDuration = vm.envOr("VEST_DURATION", uint256(30 days));
        address pmEnv = vm.envOr("POOL_MANAGER", address(0));

        vm.startBroadcast(pk);

        poolManager = pmEnv == address(0)
            ? IPoolManager(address(new PoolManager(vm.addr(pk))))
            : IPoolManager(pmEnv);

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, maxFeeBps, vestDuration);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(LoyaltyLockHook).creationCode, constructorArgs);

        hook = new LoyaltyLockHook{salt: salt}(poolManager, maxFeeBps, vestDuration);
        require(address(hook) == hookAddress, "DeployLoyaltyLockHook: address mismatch");

        vm.stopBroadcast();

        console2.log("PoolManager:   ", address(poolManager));
        console2.log("LoyaltyLockHook:", address(hook));
        console2.log("maxFeeBps:     ", maxFeeBps);
        console2.log("vestDuration:  ", vestDuration);
    }
}
