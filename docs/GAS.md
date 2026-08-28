# What the guards cost, and what Gas Killer removes

Local measurements. Reproduce with:

```bash
forge test --match-path 'test/bench/*.bench.t.sol' -vv
```

## The claim being tested

A guarded call does everything the unguarded call does, then sweeps every holder to check the books.
That sweep is the cost. Gas Killer runs the call's compute off-chain and settles the result, so the
sweep stops being paid for on-chain.

**A guard performs no storage writes.** `checkAll` is a view call. So a guarded transition produces
exactly the same diff as an unguarded one, and settlement costs the same either way. The rule sweep is
pure compute, and pure compute is precisely what Gas Killer removes.

## Result

Deposit into a vault subscribed to `Conservation`, `Solvency` and `ConcentrationCap`.

| Holders | Unguarded | Guarded | Cost of the rules | Via Gas Killer | Saving |
|---:|---:|---:|---:|---:|---:|
| 1 | 13,111 | 33,829 | 20,718 | 300,944 | **−267,115** |
| 10 | 13,111 | 95,886 | 82,775 | 300,944 | **−205,058** |
| 25 | 13,111 | 199,316 | 186,205 | 300,944 | **−101,628** |
| 50 | 13,111 | 371,708 | 358,597 | 300,944 | +70,764 |
| 100 | 13,111 | 716,521 | 703,410 | 300,944 | +415,577 |
| 200 | 13,111 | 1,406,265 | 1,393,154 | 300,944 | +1,105,321 |
| 400 | 13,111 | 2,786,221 | 2,773,110 | 300,944 | +2,485,277 |
| 800 | 13,111 | 5,548,009 | 5,534,898 | 300,944 | +5,247,065 |

Guarded cost grows at roughly **6,900 gas per holder**. Settlement is flat.

**Break-even is around 42 holders.** Below that, Gas Killer costs more than running the check
on-chain and should not be used. This is the same discipline Gas Killer's own repo applied when it
removed two examples that measured as net losses.

## The ceiling

At 2,000 holders a guarded deposit costs **13,848,371 gas** — 46% of a mainnet block for a single
deposit. Extrapolating, the check stops fitting in a block at roughly **4,300 holders**.

Past that the check cannot run on-chain at any price. That is a stronger claim than "expensive": for a
protocol of that size, continuous verification is not available without something like Gas Killer.

There is a matching ceiling on the other side. Operators simulate at `tx.gas_limit =
block.gas_limit`, so a call that cannot execute within 30M cannot be simulated or diffed either.
`gas-analyzer/docs/UNBOUNDED_MODE.md` may lift this; until it is read, treat ~4,300 holders as the
upper bound for both paths rather than a limit Gas Killer escapes.

## Where the settlement number comes from

Not modelled. A real `verifyAndUpdate` on Sepolia
([`0x865bf3ab…fb7c`](https://eth-sepolia.blockscout.com/tx/0x865bf3ab1d23566bce98261c1096822fb9a7ff8a52fbd07da9b5e804ec17fb7c))
cost **300,944 gas**, traced into **224,827 of BLS signature verification** and 76,117 for tx base,
calldata, applying the diff and the transition counter.

The BLS figure is the load-bearing one: it is constant in how much compute the operators did
off-chain. That is the entire reason a flat settlement cost can beat a growing on-chain one.

Since our example vault's deposit also writes three words, its settlement cost is that same 300,944.
Note this is the same measurement, not an independent confirmation of it.

## Measurement conditions

These move the numbers, so they are fixed deliberately:

- **Cold storage.** `vm.cool` is called before each measurement. Foundry runs a whole test as one
  transaction, so without it every holder slot is warm and each `SLOAD` costs 100 instead of 2,100 —
  which understates the sweep roughly twentyfold and moved apparent break-even from 42 holders to 99.
  A real deposit is its own transaction and reads those slots cold.
- **Steady state.** Every holder already has a non-zero balance, so no measured write is a 20k
  zero-to-non-zero.
- **No refunds.** Nothing is zeroed, so the 20% refund cap never engages.
- **Gas measured around the external call only**, so the harness is excluded.

## Not yet measured

- **Non-signer count.** 224,827 was one specific quorum. `verifyAndUpdate` passes per-operator
  non-signer stakes, so the figure should move with how many operators did not sign. Needs measuring
  with a full quorum and with one non-signer.
- **A live settlement of a guarded contract.** The 300,944 is from Gas Killer's own `GuardedVault`,
  not from one of ours. Anchoring our case needs an API key and a funded Sepolia key.
- **Other rule sets.** These three are all O(holders). The diff-based rules (`SlotProtection`,
  `Monotonic`, `DeltaBound`) are O(1) and should be nearly free; that bracket is worth showing.
- **L2 costs.** Everything here is L1 gas. On an L2 the calldata component dominates differently and
  the break-even will move.
