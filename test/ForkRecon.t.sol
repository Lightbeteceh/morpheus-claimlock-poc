// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Targets} from "../src/Targets.sol";

/// @title Recon test: sanity-check fork state at the pinned block.
contract ForkReconTest is Test {
    // Pin a recent block: public endpoints prune historical state fast.
    // Re-pin (and re-verify) right before any report submission — the
    // program requires a specific block anyway.
    uint256 constant BLOCK = 25_930_106;

    function setUp() public {
        vm.createSelectFork("eth", BLOCK);
    }

    function test_total_deposited_nonzero() public view {
        // totalDepositedInPublicPools() returns uint256
        uint256 total = IDepositPool(Targets.DEPOSIT_POOL_STETH).totalDepositedInPublicPools();
        assertGt(total, 0, "no deposits in scope pool");
    }

    function test_distributor_set() public view {
        address distributor = IDepositPool(Targets.DEPOSIT_POOL_STETH).distributor();
        assertEq(distributor, Targets.DISTRIBUTOR, "distributor mismatch");
    }
}

interface IDepositPool {
    function totalDepositedInPublicPools() external view returns (uint256);
    function distributor() external view returns (address);
}
