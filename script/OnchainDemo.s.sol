// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LoyaltyLockHook} from "../src/LoyaltyLockHook.sol";

/// @notice Full on-chain lifecycle against a deployed LoyaltyLockHook:
///   init pool -> add stayer -> add mercenary -> mercenary exits (fee donated)
///   -> stayer exits (earns the donated fee). Logs token deltas at each step.
///
/// Env: PRIVATE_KEY, POOL_MANAGER, HOOK
contract OnchainDemo is Script {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1<<96
    int24 internal constant TL = -120;
    int24 internal constant TU = 120;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        LoyaltyLockHook hook = LoyaltyLockHook(vm.envAddress("HOOK"));

        vm.startBroadcast(pk);

        // 1. Tokens + router.
        MockERC20 a = new MockERC20("Loyalty Test A", "LTA", 18);
        MockERC20 b = new MockERC20("Loyalty Test B", "LTB", 18);
        a.mint(me, 1e24);
        b.mint(me, 1e24);

        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));

        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(manager);
        MockERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);

        // 2. Init pool with the hook.
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        console2.log("pool initialized");

        // 3. Stayer deposits (salt 0). Record what it puts in.
        (uint256 s0, uint256 s1) = _bal(c0, c1, me);
        _modify(router, key, 1e18, bytes32(uint256(0)));
        (uint256 s0b, uint256 s1b) = _bal(c0, c1, me);
        uint256 stayerIn0 = s0 - s0b;
        uint256 stayerIn1 = s1 - s1b;
        console2.log("stayer deposited token0/token1:", stayerIn0, stayerIn1);

        // 4. Mercenary deposits (salt 1) then immediately exits.
        _modify(router, key, 1e18, bytes32(uint256(1)));
        (uint256 m0, uint256 m1) = _bal(c0, c1, me);
        _modify(router, key, -1e18, bytes32(uint256(1)));
        (uint256 m0b, uint256 m1b) = _bal(c0, c1, me);
        console2.log("mercenary got back token0/token1:", m0b - m0, m1b - m1);

        // 5. Stayer exits last (sole LP -> no fee on itself, collects donated fee).
        (uint256 e0, uint256 e1) = _bal(c0, c1, me);
        _modify(router, key, -1e18, bytes32(uint256(0)));
        (uint256 e0b, uint256 e1b) = _bal(c0, c1, me);
        uint256 stayerOut0 = e0b - e0;
        uint256 stayerOut1 = e1b - e1;
        console2.log("stayer withdrew token0/token1:", stayerOut0, stayerOut1);

        vm.stopBroadcast();

        // 6. Assert the headline: the stayer earned more than it deposited.
        console2.log("stayer surplus token0:", stayerOut0 - stayerIn0);
        console2.log("stayer surplus token1:", stayerOut1 - stayerIn1);
        require(stayerOut0 > stayerIn0, "stayer did not earn token0");
        require(stayerOut1 > stayerIn1, "stayer did not earn token1");
        console2.log("OK: stayer earned the mercenary's exit fee on-chain");
        console2.log("currency0:", Currency.unwrap(c0));
        console2.log("currency1:", Currency.unwrap(c1));
        console2.log("router:", address(router));
    }

    function _modify(PoolModifyLiquidityTest router, PoolKey memory key, int256 ld, bytes32 salt) internal {
        router.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: ld, salt: salt}),
            ""
        );
    }

    function _bal(Currency c0, Currency c1, address who) internal view returns (uint256, uint256) {
        return (MockERC20(Currency.unwrap(c0)).balanceOf(who), MockERC20(Currency.unwrap(c1)).balanceOf(who));
    }
}
