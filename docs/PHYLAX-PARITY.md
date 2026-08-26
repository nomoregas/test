# Phylax parity audit

What has been taken from Phylax's Credible Layer, how faithfully, and what is still missing.

Audited against `phylaxsystems/credible-std` and `credible-layer-contracts` at clone time
(Aug 2026). Their docs site was unreachable from this environment, so everything here is read from
source and the whitepaper abstract rather than from documentation.

## Status vocabulary

| | Meaning |
|---|---|
| **Ported** | Faithful equivalent exists and is tested |
| **Adapted** | Equivalent exists; semantics deliberately differ |
| **Weakened** | Equivalent exists but is strictly less capable |
| **Blocked** | Cannot be expressed in a diff-based model at all |
| **Open** | Expressible here, simply not built yet |

## Why fidelity varies at all

Phylax assertions are **execution-trace based**. An assertion runs inside a custom EVM (`PhEvm`) with
two live forks of state and the transaction journal, so it can read any contract's storage, replay
individual calls, and observe ERC-20 transfers and logs.

Our properties are **diff based**. A property sees the storage diff being attested plus the adopter's
own view functions. This is more capable than it first sounds — the diff carries a before-image, so
pre/post reasoning works — but it has two hard edges: there is no call trace, and the EVM has no
cross-contract `SLOAD`, so on-chain evaluation cannot read foreign state even in principle.

Almost every **Blocked** row below traces to one of those two edges.

### The single highest-value fix

Our `SlotWrite` models `sstore` only. Gas Killer's real settlement format (`StateUpdateType[]` +
`bytes[]` in `StateChangeHandlerLib`) applies **`sstore`, `call`, and `log`**. Widening
`TransitionContext` to carry the call and log entries of the diff would move a whole block of rows
from Blocked to Open — anything reasoning about emitted events, and anything reasoning about the
external calls a settlement performs.

That is not the same as a transaction trace: it is what the *settlement* does, not what an arbitrary
user transaction did. But for a guarded contract the settlement is the only thing that changes state,
so for this model it is the equivalent object. **This should be the next core change.**

## A. PhEvm capability surface

The root-cause table: what a property here can and cannot observe, versus their 43 cheatcodes.

| Phylax capability | Here | Status | Work needed |
|---|---|---|---|
| `forkPreTx`, `forkPostTx` | `PreState.pre` / `.post` | **Adapted** | None. Diff carries the before-image; untouched slots have pre == post |
| `forkPreCall`, `forkPostCall` | — | **Blocked** | Needs per-call granularity; no call trace exists |
| `getStateChanges` | `ctx.writes` | **Ported** | None — the diff *is* this |
| `forbidChangeForSlot`, `forbidChangeForSlots` | `SlotProtection` | **Ported** | None, incl. their "a no-op write still counts" rule |
| `changedMappingKeys`, `mappingValueDiff` | — | **Open** | Small: `PreState` helpers over the diff. Slot preimages must be supplied by the adopter |
| `load(target, slot)`, `loadStateAt` | adopter view functions | **Blocked** for foreign targets | Own state only. Cross-contract `SLOAD` does not exist |
| `staticcallAt` | — | **Blocked** | Needs a fork to call against |
| `getCallInputs` and 4 variants, `matchingCalls`, `callOutputAt`, `callinputAt`, `context`, `getTxObject`, `getAssertionAdopter` | — | **Blocked** | No call trace. Partially unblocked by carrying the diff's `call` entries |
| `getLogs`, `getLogsQuery`, `getLogsForCall` | — | **Blocked** → **Open** | Unblocked by carrying the diff's `log` entries. See above |
| `getErc20Transfers`, `getErc20TransfersForTokens`, `changedErc20BalanceDeltas`, `reduceErc20BalanceDeltas`, `conserveBalance` | — | **Blocked** | Foreign token ledgers. The operator would have to attest to foreign state, which the diff cannot express |
| `anomalyContext`, `Sensitivity` levels | — | **Blocked** | Needs executor-side transaction scoring; no equivalent signal |
| `inflowRate`, `outflowRate`, `inflowContext`, `outflowContext` | — | **Blocked** | Needs executor-held rolling state. Tractable via guarded state — see §F |
| `oracleSanity`, `oracleSanityAt` | `OracleLiveness`, `OracleDeviation` | **Weakened** | Via mirrored adopter state; cannot read the feed itself |
| `assetsMatchSharePrice`, `ratioGe`, `mulDivUp/Down`, `normalizeDecimals` | inline in `SharePriceFloor` | **Open** | Pure math. Worth extracting into a shared library |

## B. Trigger model

Phylax scopes each assertion to triggers, so only relevant assertions run. We evaluate every
registered property on every transition.

| Phylax trigger | Here | Status | Work needed |
|---|---|---|---|
| `registerStorageChangeTrigger(fn, slot)` | — | **Open** | Cheap and worth doing: skip a property when the diff touches none of its slots |
| `registerTxEndTrigger` | default behaviour | **Ported** | None — every property is effectively tx-end |
| `registerCallTrigger`, `registerFnCallTrigger` | — | **Blocked** | Selector-scoped; no call trace |
| `registerBalanceChangeTrigger` | — | **Blocked** | Native balance is not in the diff |
| `registerErc20ChangeTrigger` | — | **Blocked** | Foreign ledger |
| `watchCumulativeOutflow`, `watchCumulativeInflow` | `DeltaBound` (per-transition only) | **Weakened** | Rolling window needs state — see §F |
| `watchAnomaly` | — | **Blocked** | No anomaly scoring |

Adding slot-scoped triggers is the cheapest real win in this table: it turns property evaluation from
O(all properties) into O(relevant properties) per transition, which matters once a registry is large.

## C. Protection-suite assertions

Their curated library, `src/protection/`. 26 assertion contracts across 7 families.

| Phylax assertion | Here | Status | Work needed |
|---|---|---|---|
| `SlotProtectionAssertion` | `SlotProtection` | **Ported** | None |
| `BalanceConservationAssertion` | `ValueConservation` | **Adapted** | Ours conserves a slot-set total, permitting redistribution; theirs freezes specific foreign-token balances. The foreign-token half is Blocked |
| `SharePriceAssertion` (access_control) | `SharePriceFloor` | **Weakened** | Theirs is a *symmetric* deviation policy across configured vaults; ours bounds only the downward move for one adopter. Symmetric bound + multi-vault config is Open |
| `AccessControlBaseAssertion` | — | **Open** | A base/mixin convention for property families would reduce boilerplate |
| `ERC4626SharePriceAssertion` | `SharePriceFloor` | **Ported** | None — endpoint comparison, bps tolerance, empty-supply skip |
| `ERC4626AssetFlowAssertion` | `AssetFlowConsistency` | **Weakened** | Ours checks the diff against the adopter's *declared* flow; theirs against *observed* ERC-20 movement, catching fee-on-transfer and rebasing tokens. Not closable without foreign state |
| `ERC4626CumulativeOutflowAssertion` | `DeltaBound` | **Weakened** | Per-transition cap only. Rolling window — see §F |
| `ERC4626PreviewAssertion` | `SpecConformance` | **Ported** | Generalised: the diff must equal the adopter's own preview. Only usable where the spec is cheap to evaluate |
| `ERC4626BaseAssertion`, `IERC4626` | — | **Open** | An ERC-4626 adapter so any standard vault can be guarded without bespoke view functions. High practical value |
| `MetaMorphoVaultAssertion` | — | **Open** | Protocol-specific example |
| `AnomalyCompositeAssertion` | `Composite` | **Adapted** | The structural part (AND/OR in one evaluation) ports exactly, including the reason: blocking is disjunctive across registrations, so a conjunction must live in one `check`. The anomaly gate does not port |
| `AnomalyGatedUpgradeAssertion` | `ImplementationLock` | **Weakened** | Same EIP-1967 slots; ungated. An allowlist replaces the anomaly score, which is a different and blunter policy |
| `AnomalyGatedAccountingAssertion` | partially `SharePriceFloor` | **Weakened** | Share-price move without the anomaly gate |
| `AnomalyGatedOutflowAssertion` | partially `DeltaBound` | **Weakened** | Outflow without the gate or the window |
| `AnomalyGatedOracleAssertion` | `OracleDeviation`, `OracleLiveness` | **Weakened** | Oracle observation now exists via mirrored adopter state; the anomaly gate still does not port |
| `AnomalyUngatedAssertion`, `AnomalyGatedBaseAssertion` | — | **Blocked** | Base classes for the gating mechanism itself |
| `SafeConfigLockAssertion` | `ValueRangeGuard` + `SlotProtection` | **Weakened** | Threshold minimums and frozen guard/handler slots are covered; owner/module *set-hash* matching still needs a helper |
| `SafeTxShapeAssertion` | — | **Blocked** | Inspects transaction shape; no call trace |
| `CowSettlementAssertion` | — | **Blocked** | Settlement call structure |
| `UniswapV4PoolManagerAssertion` | — | **Blocked** | Pool-manager call sequences |
| `LendingBaseAssertion`, `AaveV3LikeOperationSafety`, `AaveV3PostOperationSolvency`, `SparkLendV1OperationSafety` | `PostOperationSolvency` | **Ported** | Per-account, with the liquidation-improves branch. Protocol-specific health-factor maths still needs oracle prices |
| `PerpetualBaseAssertion` | — | **Open** | Family scaffold, no concrete checks |

## D. Assertions Book

Their teaching catalogue, `examples/assertions-book` — 22 entries, numbered with gaps.

| # | Pattern | Here | Status |
|---|---|---|---|
| 1 | Implementation change | `ImplementationLock` | **Ported** |
| 2 | ERC-4626 operations | `SharePriceFloor` + `AssetFlowConsistency` | **Weakened** |
| 4 | KYC / whitelist | `ParticipantAllowlist` | **Adapted** — adopter names its own participants |
| 5 | Owner change | `ImplementationLock` (owner slot) | **Ported** |
| 6 | Constant product (AMM `k`) | `ConstantProduct` | **Ported** |
| 7 | Lending health factor | `PostOperationSolvency` | **Weakened** — health from mirrored state, not live prices |
| 8 | Positions sum | `Conservation` | **Ported** |
| 9 | Timelock verification | `SlotProtection` (delay slots) | **Adapted** |
| 10 | Oracle liveness | `OracleLiveness` | **Weakened** — reads a mirrored timestamp, not the feed |
| 11 | TWAP deviation | `OracleDeviation` | **Weakened** — mirrored prices |
| 12 | ERC-4626 assets/shares | `SharePriceFloor` | **Ported** |
| 13 | ERC-4626 deposit/withdraw | `AssetFlowConsistency` | **Weakened** |
| 14 | Fee verification | `FeeConsistency` | **Ported** |
| 15 | Price within ticks | `ValueRangeGuard` | **Adapted** |
| 16 | Liquidation health factor | `PostOperationSolvency` | **Weakened** — liquidation branch works; prices mirrored |
| 17 | Panic-state verification | `PanicState` | **Ported** — checks both endpoints |
| 18 | Harvest increases balance | `Monotonic` | **Adapted** |
| 19 | Tokens-borrowed invariant | `Conservation` | **Adapted** |
| 20 | ERC-20 drain | `DeltaBound` | **Weakened** — no foreign ledger, no window |
| 21 | Ether drain | — | **Blocked** — native balance is not in the diff |
| 22 | ERC-20 inflow breaker | — | **Blocked** — foreign ledger + window |
| 28 | Intra-tx oracle deviation | — | **Blocked** — intra-transaction granularity |

## E. Micro-patterns

Their reusable building blocks, `examples/micro-patterns` — the most directly comparable set to ours.

| Phylax micro-pattern | Here | Status | Work needed |
|---|---|---|---|
| `AccountingConservation` — aggregate identities hold after any tx | `Conservation`, `ValueConservation` | **Ported** | None |
| `ConfigurationGuard` — init/wiring/timing sanity | `SlotProtection` + `ValueRangeGuard` | **Ported** | Freeze *and* validate-within-range are both covered |
| `PostOperationSolvency` — risk-increasing ops leave the account solvent; liquidations improve it | `PostOperationSolvency` | **Ported** | Both branches, per touched account |
| `TieredCircuitBreaker` — soft breach → liquidation-only, hard breach → stop | `DeltaBound` (single tier) | **Weakened** | Tiers plus a rolling window — see §F |
| `ParticipantGate` — extract participants from calls, block listed accounts | `ParticipantAllowlist` | **Weakened** | Adopter names its participants; extraction from a trace is still Blocked, so a bug in `participantsOf` is a hole rather than a catch |
| `OracleReduceOnlyGate` — on oracle drift, block risk-increasing calls, leave repay open | — | **Blocked** | Needs oracle observation and call classification |
| `CallSandwichHonesty` — compare calldata, pre-call preview, return value, emitted event | — | **Blocked** | Needs calls, returns and logs together. Partially unblocked by carrying diff logs |

## F. Platform and infrastructure

Everything around the assertion library. We have essentially none of it, which is the honest headline.

| Phylax component | Here | Status | Notes |
|---|---|---|---|
| Enforcement at transaction inclusion (bonded enforcers: builders, sequencers, searchers) | Contract-level attested settlement | **Adapted** | Fundamentally different. Theirs needs no change to protocol logic; ours makes all writes async. Ours needs no builder cooperation and works on any Cancun EVM |
| State Oracle: Proof of Possibility / Proof of Realization | — | **Blocked** by Gas Killer's model | No fraud proof exists in the SDK, so there is nothing to prove a violation against |
| Bonding and slashing of enforcers | — | **Open** at the AVS layer | Gas Killer has no slashing either (its own `SECURITY.md` says so). This is where their guarantee is objectively stronger |
| `assertion-executor` | Operator node (`gas-killer/service`) | **Open** | Property evaluation is not wired into the real node at all |
| `assertion-da` (assertion data availability) | — | **Open** | Property code must be published and pinned somewhere verifiable |
| `credible-layer-contracts` (StateOracle, Batch, admin/DA verifier registries) | `PropertyCatalogue` + `SubscriptionRegistry` + `IAdopterAdmin` | **Adapted** | Admin verifiers ported (self/ownable/allowlist), listings versioned. DA verifiers still absent — property code has nowhere verifiable to live |
| `pcl` CLI (`pcl test`, `pcl apply`) | `forge test` | **Open** | No deploy/apply workflow, no config format |
| `phoundry` (patched Foundry) | stock Foundry | **Adapted** | We need no fork, because properties are ordinary Solidity with no custom precompiles |
| `CredibleTestWithBacktesting` — replay historical transactions | — | **Open** | High value: lets you measure a property's false-block rate before shipping it |
| `Sensitivity` levels (tunable firing rate) | — | **Blocked** | Only meaningful with anomaly scoring |
| `SpecRecorder` (declares which precompiles an assertion uses) | — | **N/A** | No precompiles to declare |
| Assertion gas budget per adopter | — | **Open** | Worth noting theirs is *not* unbounded either; we have no budget concept at all |
| Besu plugin, reth fork, OP-Stack (Ajax), Linea integration | — | **N/A** | Not needed — that is the point of the contract-level approach |
| Design partners shipping assertions (Aave v3, 0x, Cap) | — | **Open** | They have protocol-specific suites in production repos; we have one example vault |
| `agent-skills` for authoring assertions | — | **Open** | They ship AI-assisted authoring |

## Summary

| Category | Ported / Adapted | Weakened | Blocked | Open |
|---|---|---|---|---|
| PhEvm capabilities (15 groups) | 3 | 1 | 8 | 3 |
| Triggers (9) | 1 | 1 | 5 | 2 |
| Protection assertions (26) | 6 | 9 | 5 | 6 |
| Assertions Book (22) | 13 | 6 | 3 | 0 |
| Micro-patterns (7) | 4 | 2 | 1 | 0 |
| Platform (16) | 2 | 1 | 2 | 11 |

Read the Blocked column as the model's boundary and the Open column as the backlog. Every
Assertions Book entry and every micro-pattern that is reachable at all is now built; the remaining
Open rows are platform work and two convenience items, not properties.

The Weakened column grew as the Open column shrank, and that is the honest result: several patterns
are now *expressible* but only against state the adopter mirrors into its own storage. An oracle
property reading a mirrored timestamp protects you only if the mirror is maintained. Pair those with
a `Monotonic` on the same slot, and treat a bug in the adopter's own reporting view as a hole in the
guard rather than something the guard catches.

## Prioritised work list

1. **Carry the diff's `call` and `log` entries in `TransitionContext`.** Gas Killer already applies
   all three update types; only our prototype is `sstore`-only. Unblocks every log-based property and
   part of `CallSandwichHonesty`.
2. **Rolling-window circuit breaker.** Keep the window in guarded state, updated by the same attested
   diff. Turns four Weakened rows into Ported ones. The property stops being stateless, which is the
   design decision to make deliberately.
3. **DA for property code.** A subscriber trusts a listing's address; nothing publishes or pins the
   source behind it. Their `assertion-da` exists for exactly this.
4. **Slot-scoped triggers.** Skip a property when the diff touches none of its slots. Cheap, and
   required before a registry gets large.
5. **An ERC-4626 adapter.** Lets any standard vault be guarded without hand-written view functions —
   the difference between a library and a demo.
6. **Backtesting against historical transactions.** Their `CredibleTestWithBacktesting` measures a
   property's false-block rate before it ships. Without this, `ConcentrationCap`-style deadlocks (see
   the README) are found in production rather than in review.
7. **Wire property evaluation into the real operator node.** Until `gas-killer/service` evaluates
   properties and vetoes on violation, none of this is enforced anywhere.
