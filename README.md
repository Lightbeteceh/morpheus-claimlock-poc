# Morpheus Capital Protocol — Claim-Lock Reward Boost Is Never Enforced Against Withdrawals

PoC for the Morpheus bug bounty (https://mor.org/bug-bounty). Foundry fork
tests against the deployed bytecode at the pinned block.

## TL;DR
`DepositPool.stake()` lets any staker declare a far-future `claimLockEnd_`
(e.g. 2040), which grants the maximal ~10.7x virtual-deposit multiplier on
the staked capital. The long lock is only ever enforced against **claims**
(`DS: user claim is locked`), never against **withdrawals**: `_withdraw()`
checks only the 7-day `withdrawLockPeriodAfterStake`. A staker can therefore
take the ~10.7x boost, farm one distribution period, withdraw the principal
after 7 days, and re-stake — cycling the same capital indefinitely while
accruing the reward rate of a 14-year committed staker. Each cycle's boosted
`pendingRewards` snapshot survives the withdrawal and is claimable later.

## One-command run
```bash
forge test -vv
```
Public keyless RPC endpoints are already in `foundry.toml`
(`eth = https://eth.drpc.org`). No `.env`, no keys, no manual setup.

## Tests
| File | What it proves |
|---|---|
| `test/LockSkipAccrual.t.sol` | Same capital, same window: attacker with a 2040 lock accrues **10.7x** the honest staker's multiplier, then withdraws **all principal** after the 7-day lock. Boosted `pendingRewards` persist after principal is out. |
| `test/RepeatCycle.t.sol` | 3 stake → wait → withdraw cycles with the same 10 stETH match **1.00x** the accrual of an honest staker who held the same capital max-locked the entire time — while the attacker's capital was free every 7 days. |

Attacker = `makeAddr("attacker")` in all tests. No `vm.prank` as owner,
admin, or multisig anywhere.

## Impact (measured at block 25,930,106)
- Pool 0 (stETH) state: `totalVirtualDeposited` = 16,946.80 stETH-virtual,
  real `totalDeposited` = 8,208.44 stETH, daily pool emission = 2,897.2 MOR
  (RewardPool: initial 3,456 MOR/day, decrease 0.5926 MOR/day, day 943).
- Over-issuance vs. the same capital at 1x: with 1,000 stETH cycled,
  ~11,608 MOR/week (~$22,500 at $1.94/MOR), ~603,600 MOR/year
  (~$1.17M) redirected from honest stakers' pro-rata share.
- Every honest staker in the pool is diluted for the attacker's whole
  boosted window, each cycle.

## Pinned block
All fork tests pin `BLOCK = 25,930,106` (Ethereum mainnet). Re-pin to a
recent block before the reward programs re-reads; the vulnerability is
unconditional in the deployed logic and not block-dependent.

## Out-of-scope hygiene
- Fork tests only (`vm.createSelectFork`); nothing here touches mainnet state.
- No private keys; public RPC endpoints only.
