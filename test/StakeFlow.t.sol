// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Targets} from "../src/Targets.sol";

/// @title DepositPool stake/withdraw flow against the live fork.
/// Establishes the attacker primitives (acquire stETH, stake, warp through
/// lock periods, withdraw) that any reward-accounting PoC builds on.
interface IDepositPoolScope {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function totalDepositedInPublicPools() external view returns (uint256);
    function rewardPoolsProtocolDetails(uint256)
        external view returns (uint128 withdrawLockAfterStake, uint128 claimLockAfterStake, uint128 claimLockAfterClaim, uint256 minimalStake, uint256 distributedRewards);
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function usersData(address, uint256)
        external view returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
}

interface IStETH {
    function submit(address) external payable;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract StakeFlowTest is Test {
    uint256 constant BLOCK = 25_930_106;
    uint256 constant REWARD_POOL = 0; // public stETH pool

    IDepositPoolScope dp = IDepositPoolScope(Targets.DEPOSIT_POOL_STETH);
    IStETH steth = IStETH(Targets.STETH);

    address attacker;

    function setUp() public {
        vm.createSelectFork("eth", BLOCK);
        attacker = makeAddr("attacker");
    }

    /// Attacker acquires stETH via Lido submit and stakes.
    /// DepositPool.stake() pulls funds through Distributor.supply(), so the
    /// stETH allowance goes to the Distributor. No pre-warp: a big warp makes
    /// every Chainlink feed stale (allowedPriceUpdateDelay) and the price
    /// path reverts with "DR: price for pair is zero" — the same failure a
    /// long stall would cause on mainnet.
    function _acquireAndStake(uint256 amountEth, uint128 lockEnd) internal returns (uint256 staked) {
        vm.deal(attacker, amountEth);
        vm.startPrank(attacker);
        steth.submit{value: amountEth}(attacker);
        uint256 bal = steth.balanceOf(attacker);
        steth.approve(Targets.DISTRIBUTOR, bal);
        dp.stake(REWARD_POOL, bal, lockEnd, address(0));
        vm.stopPrank();
        return bal;
    }

    function test_attacker_can_stake() public {
        uint256 staked = _acquireAndStake(10 ether, 0);
        (, uint256 deposited, , , , , , , ) = dp.usersData(attacker, REWARD_POOL);
        assertGt(deposited, 0, "stake not recorded");
        assertApproxEqRel(deposited, staked, 1e12, "staked amount mismatch (rounding ok)");
    }

    /// Real stETH/ETH Chainlink answer at the pinned block, captured before
    /// any warp. Forks do not advance Chainlink feeds, so after vm.warp the
    /// freshness gate (allowedPriceUpdateDelay) zeroes the price. Mainnet
    /// feeds update hourly; we keep the REAL captured price and only mock
    /// the freshness gate for post-warp calls.
    function _realStethPrice() internal view returns (uint256) {
        bytes32 stethPathId = 0x7890db9c0a88d1cacb4485f81f93172a6b7b8c19af9c1a9985563f7d45ce2e6f;
        (bool ok, bytes memory res) = Targets.CHAINLINK_DATA_CONSUMER.staticcall(
            abi.encodeWithSignature("getChainLinkDataFeedLatestAnswer(bytes32)", stethPathId)
        );
        require(ok, "price read failed");
        uint256 p = abi.decode(res, (uint256));
        require(p > 0, "no real price at pinned block");
        return p;
    }

    function _mockFreshChainlink(uint256 realPrice) internal {
        vm.mockCall(
            Targets.CHAINLINK_DATA_CONSUMER,
            abi.encodeWithSignature("getChainLinkDataFeedLatestAnswer(bytes32)"),
            abi.encode(realPrice)
        );
    }

    /// Full flow: stake -> warp past the 7-day withdraw lock -> withdraw,
    /// asserting the principal fully exits the pool and lands back in the
    /// attacker's wallet. Reward claims route through L1Sender (LayerZero)
    /// and cannot complete on a fork; withdraws prove the accounting path.
    function test_stake_then_withdraw_after_lock() public {
        uint256 realPrice = _realStethPrice();
        (, , , uint256 minimalStake, ) = dp.rewardPoolsProtocolDetails(REWARD_POOL);
        assertGt(minimalStake, 0, "minimalStake read failed");
        uint256 staked = _acquireAndStake(10 ether, 0);
        assertGt(staked, 0, "nothing staked");

        // Warp past the 7-day withdraw lock; keep the real price valid by
        // mocking only the freshness gate (forks freeze Chainlink feeds).
        vm.warp(block.timestamp + 7 days + 1);
        _mockFreshChainlink(realPrice);

        uint256 balBefore = steth.balanceOf(attacker);
        vm.prank(attacker);
        dp.withdraw(REWARD_POOL, staked);

        // Principal exits the pool (stETH share rounding leaves <= 10 wei dust).
        (, uint256 depositedAfter, , , , , , , ) = dp.usersData(attacker, REWARD_POOL);
        assertApproxEqAbs(
            depositedAfter,
            0,
            10,
            "withdraw did not exit principal (beyond stETH dust <= 10 wei)"
        );

        // Principal is back in the attacker's wallet.
        uint256 recovered = steth.balanceOf(attacker) - balBefore;
        assertApproxEqAbs(
            recovered,
            staked,
            10,
            "attacker did not recover principal (beyond stETH dust <= 10 wei)"
        );
    }
}
