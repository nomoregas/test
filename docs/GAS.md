# What a risk policy costs, and what Gas Killer removes

Reproduce with:

```bash
forge test --match-path 'test/bench/*.bench.t.sol' -vv
```

## The result

A `borrow()` on a multi-asset lending protocol, guarded by a six-rule risk policy: per-market
solvency, supply and borrow caps, oracle freshness, index floors, risk-parameter consistency, and a
recomputation of the protocol's running totals from the per-market figures.

Settlement is via `SchnorrGasKillerSDK` at **93,208** gas, assuming full quorum participation.
The BLS column is the measured alternative; [why the two differ](#the-signature-scheme-is-the-whole-story)
is the most important number on this page.

| Markets | Unguarded | Guarded | Policy cost | Via Schnorr | Saving | (via BLS) |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 15,635 | 103,200 | 87,565 | 93,208 | **+9,992** | −197,744 |
| 5 | 15,635 | 192,097 | 176,462 | 93,208 | **+98,889** | −108,847 |
| 10 | 15,635 | 303,226 | 287,591 | 93,208 | **+210,018** | +2,282 |
| 20 | 15,635 | 525,492 | 509,857 | 93,208 | **+432,284** | +224,548 |
| 30 | 15,635 | 747,775 | 732,140 | 93,208 | **+654,567** | +446,831 |
| 40 | 15,635 | 970,068 | 954,433 | 93,208 | **+876,860** | +669,124 |

**Under Schnorr with full participation there is no break-even — the six-rule policy wins at every
size, starting at one market.** One non-signer pushes it to two markets. Under BLS it arrives around
ten. Aave carries roughly thirty.

The unguarded call is a flat 15,635 at every size, because it only touches one market — that it does
not move is the sanity check that the sweep, not the setup, is what the guarded column measures. At
30 markets the policy is **48× the cost of the transaction it protects**. That is the number that
explains why nobody runs these checks today.

## How many rules it takes

At a fixed 30 markets, adding one rule at a time:

| Rules | Guarded | vs Schnorr | vs BLS |
|---:|---:|---|---|
| 1 | 187,665 | wins | on-chain is cheaper |
| 2 | 325,789 | wins | wins |
| 3 | 491,760 | wins | wins |
| 4 | 655,060 | wins | wins |
| 5 | 696,381 | wins | wins |
| 6 | 747,775 | wins | wins |

Under BLS the story was that no single rule justifies settlement and two do. **Under Schnorr a
single rule justifies it** — one `MarketSolvency` sweep breaks even at 13 markets, against 53
under BLS. The combination still helps, but it is no longer the thing carrying the argument.

Each rule carries its own fixed overhead — a cold
account access, an external call, a registry read — on top of its reads, so a policy grows faster
than the reads alone would suggest.

## Why settlement is flat

A guard performs no storage writes: the rules are view calls. So a guarded transition produces
exactly the same diff as an unguarded one, and settlement costs the same either way. The policy is
pure compute, and pure compute is what Gas Killer removes.

Whatever the scheme, settlement is constant in how much compute the operators did off-chain, which
is the whole reason a flat cost can beat a growing one.

## The signature scheme is the whole story

Settlement is dominated by verifying that a quorum signed the diff, and the two schemes the SDK
offers are an order of magnitude apart.

**BLS — measured.** A real `verifyAndUpdate` on Sepolia
([`0x865bf3ab…fb7c`](https://eth-sepolia.blockscout.com/tx/0x865bf3ab1d23566bce98261c1096822fb9a7ff8a52fbd07da9b5e804ec17fb7c))
cost **300,944 gas**, traced into **224,827** of aggregated BLS verification against EigenLayer's
`IBLSSignatureChecker` and **76,117** for tx base, calldata, applying the diff and the transition
counter.

**Schnorr — verification measured, composition arithmetic.** `SchnorrGasKillerSDK` verifies a single
aggregate secp256k1 signature against `SchnorrStakeRegistry`, using the audited Chronicle/MakerDAO
"Scribe" `ecrecover` trick: **one** `ecrecover` and no elliptic-curve scalar multiplication.

Its cost is not a guess. The SDK ships its own benchmark, `test/SchnorrStakeRegistryGas.t.sol`,
reproduced here against `gas-killer/solidity-sdk` at solc 0.8.29:

| Context | Gas |
|---|---:|
| cold, full participation | **17,091** |
| cold, one non-signer | 27,285 |
| warm, full participation | 6,570 |
| warm, marginal per non-signer | 4,197 |

Cold is the context that matters: a standalone `verifyAndUpdate` touches the registry for the first
time in its transaction, which is what a receipt reflects. So:

| Term | Gas | Basis |
|---|---:|---|
| signature verification | 17,091 | measured, cold, full participation |
| everything else | 76,117 | measured, carried over whole |
| **total** | **93,208** | composition |

Carrying the 76,117 over whole is deliberately conservative: a 64-byte signature is far less calldata
than a BLS certificate with its non-signer public keys, so that term should shrink too. What remains
unmeasured is a Schnorr `verifyAndUpdate` end to end — 93,208 is arithmetic on two measured parts,
not an observed receipt.

### Non-signers

Subtracting a non-signer's key from the aggregate has no secp256k1 precompile, so it is Solidity EC
arithmetic: a modexp-based inverse plus three cold `SLOAD`s of the operator's record. Measured at
**10,194 cold** for the first non-signer, and linear warm across k = 1..8 at 4,197 each. Cold beyond
k = 1 is extrapolated from those two results.

Under BLS this hid beneath a 225k constant. Under Schnorr it is around 11% of settlement per
non-signer, so it belongs in any quote:

| Non-signers | Settlement | Policy break-even | Single-rule break-even |
|---:|---:|---:|---:|
| 0 | 93,208 | 1 market | 13 markets |
| 1 | 103,402 | 2 | 15 |
| 3 | 123,790 | 2 | 19 |

One thing to watch: EIP-7883 (Fusaka) removes the historical `GQUADDIVISOR=3` for ≤32-byte modexp
operands, tripling that call from 1,360 to 4,080 and raising the warm marginal from ~4.2k to ~6.9k.
Every figure here is pre-repricing; the SDK's own test comments flag the same thing.

Note the BLS transaction is Gas Killer's own `GuardedVault` settlement, not one of ours. Anchoring
our case still needs a live settlement of this protocol, under Schnorr.

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
unguarded baseline comes out identical (15,635) at every market count, which it cannot do if
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
oracle bound reads two. A guarded call carrying one of those runs to roughly 27k, so it does not
justify settlement at 93k, let alone at 300k. What a protocol cannot afford is a *policy*: a dozen
cheap checks applied across every listed asset, on every interaction. Schnorr lowers the bar a
policy has to clear; it does not make a single flat rule worth settling.

## Not yet measured

- **A Schnorr `verifyAndUpdate` end to end.** Verification is measured and the remainder is
  measured, but 93,208 is their sum rather than an observed receipt. Carrying the BLS calldata
  term over whole should make it an overestimate; confirm that.
- **Non-signers beyond k=1, cold.** Cold is measured at k=0 and k=1; the rest extrapolates from
  warm linearity. Under BLS the non-signer cost was never isolated at all — 224,827 was one
  specific quorum.
- **Post-EIP-7883 repricing.** Fusaka triples ≤32-byte modexp, taking the warm non-signer marginal
  from ~4.2k to ~6.9k. Re-run once the toolchain ships it.
- **A live settlement of this protocol**, to anchor our own case rather than borrowing Gas Killer's.
  Needs an API key and a funded Sepolia key.
- **L2 costs.** All L1 gas here. On an L2 the calldata component dominates differently and break-even
  moves — in Schnorr's favour, since its certificate is a fraction of a BLS one.
