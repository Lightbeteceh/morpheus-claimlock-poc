# Morpheus Bug Bounty PoC Workspace

## Overview
Foundry workspace for PoC development against the Morpheus bug bounty
(https://mor.org/bug-bounty). Targets live mainnet contracts via fork tests
pinned to specific blocks. PoCs must run with `forge test` one-command,
no privileged accounts, assert the loss.

## Commands
```bash
# RPC endpoints (public, keyless)
ETH_RPC=https://ethereum-rpc.publicnode.com
BASE_RPC=https://base-rpc.publicnode.com
ARB_RPC=https://arb1.arbitrum.io/rpc

# Build
forge build

# Run all fork tests (set FOUNDRY_PROFILE=ci for fewer fuzz runs)
forge test -vvv

# Single test
forge test --match-test <name> -vvv
```

## Conventions
- Every PoC test: `vm.createSelectFork(RPC, BLOCK)` with the pinned block
  number as a constant; never unpinned forks.
- Attacker = fresh `makeAddr("attacker")`; **NEVER** `vm.prank` as owner,
  admin, or multisig.
- Assert the loss: balance delta or broken invariant, never a revert.

## Boundaries
- **NEVER** execute against mainnet state outside a fork (`vm.createSelectFork` only).
- **NEVER** commit private keys or RPC keys; public endpoints only.
- Report target = the proxy address from Appendix A, pinned at a specific block.
- Out of scope per the program: admin-key findings, gas, style, DoS-only griefing,
  theoretical issues, known/disclosed issues.

## Dependencies
- foundry (forge/anvil/cast) 1.8.0 — `~/.foundry/bin`
- Morpheus source at `/home/work/morpheus` (verified: deployed bytecode for
  DepositPool impl `0xdb10...` and Distributor impl `0x52f7...` matches repo
  commit 868db55 modulo library link addresses)

## In-scope targets (Appendix A, eth mainnet)
- MOR token: 0xcBB8f1BDA10b9696c57E13BC128Fe674769DCEc0
- DepositPool(stETH) proxy: 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790
- Distributor proxy: 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A
- RewardPool proxy: 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87
- L1SenderV2 proxy: 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84

## Error Handling
- Fork tests fail on RPC rate limits: retry, or pin a block already cached.
- `execution reverted` on state reads usually means wrong block pin — check
  the contract existed at that block.

## Troubleshooting
- Fork gives stale balances: ensure `vm.createSelectFork(RPC, BLOCK)` pins
  the block; do not use `--fork-url` flag (forge 1.8.0 panics on it in some
  environments; use foundry.toml rpc_endpoints + createSelectFork).
