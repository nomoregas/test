# What a risk policy costs, and what Gas Killer removes

Reproduce with:

```bash
forge test --match-path 'test/bench/*.bench.t.sol' -vv
```

## The result

A `borrow()` on a multi-asset lending protocol, guarded by a six-rule risk policy: per-market
solvency, supply and borrow caps, oracle freshness, index floors, risk-parameter consistency, and a
recomputation of the protocol's running totals from the per-market figures.

| Markets | Unguarded | Guarded | Policy cost | Via Gas Killer | Saving |
|---:|---:|---:|---:|---:|---:|
| 1 | 15,632 | 98,030 | 82,398 | 300,944 | −202,914 |
| 5 | 15,632 | 186,951 | 171,319 | 300,944 | −113,993 |
| 10 | 15,632 | 298,110 | 282,478 | 300,944 | −2,834 |
| 20 | 15,632 | 520,436 | 504,804 | 300,944 | **+219,492** |
| 30 | 15,632 | 742,779 | 727,147 | 300,944 | **+441,835** |
| 40 | 15,632 | 965,132 | 949,500 | 300,944 | **+664,188** |

**Break-even is around 10 markets.** Aave carries roughly thirty, so a real multi-asset lending
protocol sits well past it — at 30 markets the policy costs 2.5× what settlement does.

The unguarded call is a flat 15,632 at every size, because it only touches one market. At 30 markets
the policy is **47× the cost of the transaction it protects**. That is the number that explains why
nobody runs these checks today.

## It is the combination that makes it worth it

At a fixed 30 markets, adding one rule at a time:

| Rules | Guarded | Verdict |
|---:|---:|---|
| 1 | 186,297 | on-chain is cheaper |
| 2 | 323,565 | Gas Killer wins |
| 3 | 488,860 | Gas Killer wins |
| 4 | 651,506 | Gas Killer wins |
| 5 | 692,151 | Gas Killer wins |
| 6 | 742,779 | Gas Killer wins |

No single rule justifies Gas Killer. **Two do.** Each rule carries its own fixed overhead — a cold
account access, an external call, a registry read — on top of its reads, so a policy grows faster
than the reads alone would suggest.

## Why settlement is flat

A guard performs no storage writes: the rules are view calls. So a guarded transition produces
exactly the same diff as an unguarded one, and settlement costs the same either way. The policy is
pure compute, and pure compute is what Gas Killer removes.

The settlement figure is measured, not modelled. A real `verifyAndUpdate` on Sepolia
([`0x865bf3ab…fb7c`](https://eth-sepolia.blockscout.com/tx/0x865bf3ab1d23566bce98261c1096822fb9a7ff8a52fbd07da9b5e804ec17fb7c))
cost **300,944 gas**, traced into **224,827 of BLS signature verification** and 76,117 for tx base,
calldata, applying the diff and the transition counter. The BLS figure is constant in how much
compute the operators did off-chain, which is the whole reason a flat cost can beat a growing one.

Note it is Gas Killer's own `GuardedVault` transaction, not one of ours. Anchoring our case needs a
live settlement of this protocol.

## Methodology, and a mistake worth not repeating

Gas here is dominated by EIP-2929 cold access: 2,100 for the first `SLOAD` of a slot, 100 after. A
Foundry test runs as one transaction, so anything a setup loop touches is warm for the rest of the
test — and a policy that sweeps every market touches everything.

`vm.cool` does **not** fix this. Probed directly (`test/bench/CoolProbe.t.sol`): the same call
measured 15,423 warm and 5,317 after `vm.cool`. Cooling made it *cheaper*, because `vm.cool` resets
EIP-2200 dirty-store tracking and leaves access warmth alone. An earlier version of this benchmark
used it and labelled the output "cold"; those numbers were wrong and have been deleted rather than
corrected in place.

The only unambiguous cold measurement is one per transaction. Every data point above is a separate
test function in a separate contract, with all fill work in `setUp`. The check that it worked: the
unguarded baseline comes out identical (15,632) at every market count, which it cannot do if
warmth is leaking between measurements.

Also fixed deliberately:

- **Steady state.** Every market has non-zero totals before measuring, so no measured write is a 20k
  zero-to-non-zero.
- **Realistic packing.** Market config is packed into one word, as Aave packs its reserve
  configuration bitmap. Not packing would have inflated every figure.
- **No refunds.** Nothing is zeroed, so the 20% refund cap never engages.

## An earlier benchmark that asked the wrong question

The first version measured one rule (`Conservation`) summing an enumerable holder array, and found
break-even at ~42 holders. It has been deleted. Real contracts do not enumerate holders — ERC-20
cannot — they keep running totals and never iterate. The vault had a `holders[]` array only so the
rule could sweep it, which made the benchmark circular: build a contract to suit an expensive check,
then measure that the check is expensive.

The lesson generalises. The individually valuable rules are O(1) — an upgrade lock reads two slots, an
oracle bound reads two. Those never justify a 300k settlement on their own. What a protocol cannot
afford is a *policy*: a dozen cheap checks applied across every listed asset, on every interaction.

## Not yet measured

- **Non-signer count.** 224,827 was one specific quorum. `verifyAndUpdate` passes per-operator
  non-signer stakes, so the figure should move with how many operators did not sign.
- **A live settlement of this protocol**, to anchor our own case rather than borrowing Gas Killer's.
  Needs an API key and a funded Sepolia key.
- **L2 costs.** All L1 gas here. On an L2 the calldata component dominates differently and break-even
  moves.
