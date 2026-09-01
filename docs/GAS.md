# What a risk policy costs, and what Gas Killer removes

Reproduce with:

```bash
forge test --match-path 'test/bench/*.bench.t.sol' -vv
```

## The result

A `borrow()` on a multi-asset lending protocol, guarded by a six-rule risk policy: per-market
solvency, supply and borrow caps, oracle freshness, index floors, risk-parameter consistency, and a
recomputation of the protocol's running totals from the per-market figures.

Settlement is via `SchnorrGasKillerSDK` at a **measured 56,369** gas — a real `verifyAndUpdate`
carrying this transition's two-word diff, at full quorum participation. The BLS column is the
measured alternative; [why the two differ](#the-signature-scheme-is-the-whole-story) is the most
important number on this page.

| Markets | Unguarded | Guarded | Policy cost | Via Schnorr | Saving | (via BLS) |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 15,635 | 103,200 | 87,565 | 56,369 | **+46,831** | −197,744 |
| 5 | 15,635 | 192,097 | 176,462 | 56,369 | **+135,728** | −108,847 |
| 10 | 15,635 | 303,226 | 287,591 | 56,369 | **+246,857** | +2,282 |
| 20 | 15,635 | 525,492 | 509,857 | 56,369 | **+469,123** | +224,548 |
| 30 | 15,635 | 747,775 | 732,140 | 56,369 | **+691,406** | +446,831 |
| 40 | 15,635 | 970,068 | 954,433 | 56,369 | **+913,699** | +669,124 |

**Under Schnorr there is no break-even — the six-rule policy wins at every size, from one market,
and keeps winning with three non-signers.** Under BLS it arrives around ten. Aave carries roughly
thirty.

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
single rule justifies it** — one `MarketSolvency` sweep breaks even at 6 markets, against 53
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
time in its transaction.

### The settlement itself, measured

An earlier version of this document composed a Schnorr total by taking the BLS receipt and swapping
its signature term — 76,117 of "everything else" plus 17,091 of verification, for 93,208. **That was
wrong by 65%.** The borrowed remainder carried the BLS transaction's own diff and its certificate
calldata, neither of which belongs to a Schnorr settlement of this transition.

So measure the whole call instead. `external-bench/SchnorrSettlementGas.t.sol` runs a real
`verifyAndUpdate` against the real `SchnorrStakeRegistry` with a real aggregate signature, generated
in-test because `verifyAndUpdate` binds `msgHash` to `sha256(transitionIndex, target,
targetFunction, storageUpdates)` and a fixture cannot satisfy that. Totals are execution plus
intrinsic (21,000 base and EIP-2028 calldata), which is what a receipt shows:

| Diff words | Non-signers | Execution | Intrinsic | **Total** |
|---:|---:|---:|---:|---:|
| 1 | 0 | 27,607 | 24,744 | **52,351** |
| 2 | 0 | 30,937 | 25,432 | **56,369** |
| 2 | 1 | 41,312 | 25,812 | **67,124** |
| 2 | 3 | 62,044 | 26,548 | **88,592** |
| 8 | 0 | 50,946 | 29,728 | **80,674** |

A guarded `borrow()` writes two storage words (`test/bench/DiffSize.t.sol`, which also asserts the
guarded and unguarded diffs are identical — the claim settlement flatness rests on), so **56,369**
is this protocol's figure.

Two things fall out. Each diff word costs about 3,320. And **total operator count does not matter,
only non-signers**: ten operators with three non-signers costs exactly three operators with zero
plus 3 × 10,369. The registry loops over non-signers alone; the aggregate and total weight are
cached.

Gas is deterministic for a given EVM version, so these are the numbers a Sepolia receipt would show
for the same diff. Sepolia would validate the *pipeline* — router, operators, aggregation — not the
gas. Measured at solc 0.8.29, forge 1.5.1, cancun.

One conservative bias: the harness cools the target, so the measurement pays a cold account access
(~2,600) that a real transaction does not, since EIP-2929 pre-warms `tx.to`. The true figure is
around 2,500 lower.

### Non-signers

Subtracting a non-signer's key from the aggregate has no secp256k1 precompile, so it is Solidity EC
arithmetic: a modexp-based inverse plus three cold `SLOAD`s of the operator's record. Measured at
**10,375 per non-signer** end to end, agreeing with the 10,194 the registry benchmark shows in
isolation.

Under BLS this hid beneath a 225k constant. Under Schnorr it is about 18% of settlement each, so it
belongs in any quote:

| Non-signers | Settlement | Policy break-even | Single-rule break-even |
|---:|---:|---:|---:|
| 0 | 56,369 | 1 market | 6 markets |
| 1 | 67,124 | 1 | 8 |
| 3 | 88,592 | 1 | 12 |

One thing to watch: EIP-7883 (Fusaka) removes the historical `GQUADDIVISOR=3` for ≤32-byte modexp
operands, tripling that call from 1,360 to 4,080 and raising the per-non-signer marginal by roughly
2,700. Every figure here is pre-repricing; the SDK's own test comments flag the same thing.

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
justify settlement even at 56k, let alone at 300k. What a protocol cannot afford is a *policy*: a dozen
cheap checks applied across every listed asset, on every interaction. Schnorr lowers the bar a
policy has to clear; it does not make a single flat rule worth settling.

## Not yet measured

- **A settlement on a live network.** Everything here is local. Gas is deterministic, so the
  figures should hold, but nothing has exercised the router, the operators or real aggregation
  end to end. That is a pipeline question, not a gas one.
- **The BLS non-signer cost**, never isolated — 224,827 was one specific quorum. Only the Schnorr
  side is characterised against non-signer count.
- **Post-EIP-7883 repricing.** Fusaka triples ≤32-byte modexp, taking the warm non-signer marginal
  from ~4.2k to ~6.9k. Re-run once the toolchain ships it.
- **A live settlement of this protocol**, to anchor our own case rather than borrowing Gas Killer's.
  Needs an API key and a funded Sepolia key.
- **L2 costs.** All L1 gas here. On an L2 the calldata component dominates differently and break-even
  moves — in Schnorr's favour, since its certificate is a fraction of a BLS one.
