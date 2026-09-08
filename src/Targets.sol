// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title In-scope Morpheus target addresses (Appendix A of the bounty).
/// Pinned block: verify all state reads against this block in fork tests.
library Targets {
    // Ethereum mainnet
    address constant MOR_TOKEN = 0xcBB8f1BDA10b9696c57E13BC128Fe674769DCEc0;
    address constant DEPOSIT_POOL_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant DEPOSIT_POOL_WETH = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant DEPOSIT_POOL_WBTC = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant DEPOSIT_POOL_USDC = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant DEPOSIT_POOL_USDT = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant CHAINLINK_DATA_CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    address constant L1_SENDER_V2 = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;

    // Tokens
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // RPC endpoint label used by vm.createSelectFork("eth", BLOCK)
    string constant ETH_RPC_LABEL = "eth";
    string constant BASE_RPC_LABEL = "base";
    string constant ARB_RPC_LABEL = "arb";
}
