// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {LoyaltyLockHook} from "../src/LoyaltyLockHook.sol";

contract LoyaltyLockHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 internal constant MAX_FEE_BPS = 300; // 3%
    uint256 internal constant VEST = 30 days;
    uint256 internal constant START_TIME = 1_000_000;

    // keccak256("LoyaltyFeeAssessed(bytes32,address,int24,int24,uint128,uint256,uint256,uint256)")
    bytes32 internal constant FEE_TOPIC = keccak256(
        "LoyaltyFeeAssessed(bytes32,address,int24,int24,uint128,uint256,uint256,uint256)"
    );

    LoyaltyLockHook internal hook;
    PoolId internal poolId;

    bytes32 internal constant SALT_BASE = bytes32(uint256(0)); // the "sticky" stayer
    bytes32 internal constant SALT_MERC = bytes32(uint256(1)); // the mercenary

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0x4444 << 144));
        deployCodeTo("LoyaltyLockHook.sol:LoyaltyLockHook", abi.encode(manager, MAX_FEE_BPS, VEST), hookAddr);
        hook = LoyaltyLockHook(hookAddr);

        (key, poolId) = initPool(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        vm.warp(START_TIME);
    }

    // --- Helpers -----------------------------------------------------------

    function _modify(int256 liquidityDelta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: liquidityDelta,
                salt: salt
            }),
            ZERO_BYTES
        );
    }

    /// @dev Removes `liq` of the given position and returns the LoyaltyFeeAssessed payload.
    function _removeAndReadFee(uint256 liq, bytes32 salt)
        internal
        returns (uint256 feeBps, uint256 fee0, uint256 fee1)
    {
        vm.recordLogs();
        _modify(-int256(liq), salt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_TOPIC && logs[i].emitter == address(hook)) {
                (,,, feeBps, fee0, fee1) =
                    abi.decode(logs[i].data, (int24, int24, uint128, uint256, uint256, uint256));
                return (feeBps, fee0, fee1);
            }
        }
        revert("LoyaltyFeeAssessed not emitted");
    }

    function _bal() internal view returns (uint256 b0, uint256 b1) {
        b0 = currency0.balanceOfSelf();
        b1 = currency1.balanceOfSelf();
    }

    // --- Pure decay math ---------------------------------------------------

    function test_quoteFeeBps_decaysLinearly() public view {
        assertEq(hook.quoteFeeBps(0), MAX_FEE_BPS, "age 0 -> max");
        assertEq(hook.quoteFeeBps(VEST / 2), MAX_FEE_BPS / 2, "half vest -> half");
        assertEq(hook.quoteFeeBps(VEST), 0, "full vest -> zero");
        assertEq(hook.quoteFeeBps(VEST * 2), 0, "past vest -> zero");
    }

    // --- Exit fee is captured (value actually moves) -----------------------

    function test_age0_capturesFee_andReducesLPProceeds() public {
        _modify(1e18, SALT_BASE); // a stayer so the donation has a recipient
        _modify(1e18, SALT_MERC);

        (uint256 before0, uint256 before1) = _bal();
        (uint256 feeBps, uint256 fee0, uint256 fee1) = _removeAndReadFee(1e18, SALT_MERC);
        (uint256 after0, uint256 after1) = _bal();

        uint256 got0 = after0 - before0;
        uint256 got1 = after1 - before1;

        assertEq(feeBps, MAX_FEE_BPS, "fresh position pays max fee");
        assertGt(fee0, 0, "fee0 charged");
        assertGt(fee1, 0, "fee1 charged");

        // The LP received principal minus fee; fee/(principal) must equal the bps rate.
        assertApproxEqAbs((fee0 * 10_000) / (got0 + fee0), MAX_FEE_BPS, 1, "fee0 rate");
        assertApproxEqAbs((fee1 * 10_000) / (got1 + fee1), MAX_FEE_BPS, 1, "fee1 rate");
    }

    function test_afterVest_noFee_fullProceeds() public {
        _modify(1e18, SALT_BASE);
        _modify(1e18, SALT_MERC);

        vm.warp(START_TIME + VEST);
        (uint256 feeBps, uint256 fee0, uint256 fee1) = _removeAndReadFee(1e18, SALT_MERC);

        assertEq(feeBps, 0, "vested -> no fee");
        assertEq(fee0, 0, "no fee0");
        assertEq(fee1, 0, "no fee1");
    }

    function test_halfVest_chargesHalfFee() public {
        _modify(1e18, SALT_BASE);
        _modify(1e18, SALT_MERC);

        vm.warp(START_TIME + VEST / 2);
        (uint256 feeBps,,) = _removeAndReadFee(1e18, SALT_MERC);
        assertEq(feeBps, MAX_FEE_BPS / 2, "half vest -> half fee");
    }

    // --- The headline: stayers earn the exiting LP's fee -------------------

    function test_stayer_earnsExitFeeFromMercenary() public {
        // Base LP deposits; record what they put in.
        (uint256 preAdd0, uint256 preAdd1) = _bal();
        _modify(1e18, SALT_BASE);
        (uint256 postAdd0, uint256 postAdd1) = _bal();
        uint256 baseIn0 = preAdd0 - postAdd0;
        uint256 baseIn1 = preAdd1 - postAdd1;

        // Mercenary enters and immediately exits, paying the max fee (donated to base).
        _modify(1e18, SALT_MERC);
        (, uint256 fee0, uint256 fee1) = _removeAndReadFee(1e18, SALT_MERC);
        assertGt(fee0, 0);
        assertGt(fee1, 0);

        // Base now withdraws. It is the sole remaining LP, so it pays no fee itself
        // and collects the donated mercenary fee on top of its principal.
        (uint256 preOut0, uint256 preOut1) = _bal();
        (uint256 baseFeeBps,,) = _removeAndReadFee(1e18, SALT_BASE);
        (uint256 postOut0, uint256 postOut1) = _bal();
        uint256 baseOut0 = postOut0 - preOut0;
        uint256 baseOut1 = postOut1 - preOut1;

        assertEq(baseFeeBps, MAX_FEE_BPS, "fee rate computed even when waived");
        // The lone exiting LP is not charged (nobody to reward).
        assertGt(baseOut0, baseIn0, "stayer withdrew more token0 than deposited");
        assertGt(baseOut1, baseIn1, "stayer withdrew more token1 than deposited");
        // The surplus is the donated mercenary fee (within rounding dust).
        assertApproxEqAbs(baseOut0 - baseIn0, fee0, 2, "surplus0 == donated fee0");
        assertApproxEqAbs(baseOut1 - baseIn1, fee1, 2, "surplus1 == donated fee1");
    }

    // --- Liquidity-weighted deposit time -----------------------------------

    function test_weightedTimestamp_blendsAcrossAdds() public {
        _modify(1e18, SALT_BASE); // stayer for the donation
        _modify(1e18, SALT_MERC); // first merc add at START_TIME
        vm.warp(START_TIME + VEST);
        _modify(1e18, SALT_MERC); // second equal add -> blended time = START_TIME + VEST/2

        // Age at removal = (START_TIME+VEST) - (START_TIME+VEST/2) = VEST/2 -> half fee.
        (uint256 feeBps,,) = _removeAndReadFee(2e18, SALT_MERC);
        assertEq(feeBps, MAX_FEE_BPS / 2, "blended age -> half fee");
    }
}
