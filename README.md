# Guards — continuously enforced contract properties

> Prototype. Unaudited. The attestation layer is mocked; see [Status](#status).

A contract's most valuable safety checks are the ones it cannot afford to run. Conservation of
accounting across every holder, global solvency, a per-holder concentration limit — each is an O(N)
sweep, so nobody puts them in the write path. They end up in a fuzzing campaign that runs before
deploy, or a monitoring script that notices afterwards.

**Guards move them into the write path.** A property is declared once, in Solidity, and evaluated on
every single state transition. It costs the chain nothing, because Gas Killer operators evaluate it
off-chain and simply refuse to sign a transition that breaks it.

These are not tests. A test runs pre-deploy against a fuzzer's guesses about what might happen. A
guard runs post-deploy against what actually happened, on every transition, forever.

## How it works

```
  user                       operators                          chain
   │                             │                                │
   │── request(action) ─────────────────────────────────────────▶ │  intent queued (no state change)
   │                             │                                │
   │                    simulate pending intents                  │
   │                    evaluate every property                   │
   │                    on the post-state + diff                  │
   │                             │                                │
   │                    ┌────────┴────────┐                       │
   │                    │ all hold?       │                       │
   │                    ├─ no  → refuse to sign (transition dies)  │
   │                    └─ yes → BLS-sign the diff ─── settle() ─▶ │  sstore the attested diff
```

A guarded contract has **no direct writers**. That is not incidental — it is what makes the guarantee
cover everything. An off-chain veto can only block a transition that waits for a quorum, so a
function that mutates state the moment it is mined gives operators nothing to veto. Routing every
write through attestation is the price of "no violating state change, ever" rather than "no violating
state change in the expensive functions".

The cost is asynchronous writes. That is a real integration ask, and for some contracts it will be
too invasive — the fallback there is optimistic apply plus halt-on-violation, which is detection
rather than prevention.

## Two adoption paths

**Async (`GuardedState`)** — the strong guarantee, for a contract you are writing now. No violating
state change, ever, because every write routes through attested settlement. Costs a rewrite.

**Additive (`Guardable`)** — for a contract that already exists. Annotate the functions that let value
out with `guardedOutflow(amount)`; change no existing line. See
[`src/subscribe/examples/LegacyVault.sol`](src/subscribe/examples/LegacyVault.sol), whose entire
integration is `is Guardable`, an attestor in the constructor, and one modifier on `withdraw`.

The additive path cannot prevent state corruption — nothing can veto a synchronous write, and any
design claiming otherwise is lying. It prevents *extraction*, by inverting who acts. Operators do not
veto; they periodically attest a spending budget with an expiry, having checked the property set
off-chain. On-chain an outflow costs one storage read and a comparison. If a property breaks,
operators stop refreshing and the budget lapses. **The absence of an attestation is the signal**, so
nothing needs proving on-chain.

That is fail-closed, which is right for a security device and a real liveness cost: a quorum that goes
silent freezes withdrawals even when nothing is wrong (`test_silentQuorumFreezesWithdrawalsEvenWhenHealthy`).
Exposure is bounded by the live budget, so budget size and expiry are the risk dial an integrator sets.

One honest limitation, tested rather than footnoted: the phantom-holder hole is **worse and
unclosable** here. `SlotDomain` shuts it in the async model by bounding the diff's domain; there is no
diff in the additive model, so value credited to an address the conservation sweep never visits stays
invisible and operators keep refreshing
(`test_phantomHolderEscapesDetectionEntirely`). A legacy adopter's properties must enumerate reachable
state, not a registration list.

## What the guarantee actually is

In the default `OffchainVeto` mode nothing on-chain re-executes anything. If ≥66% of quorum stake
signs a property-violating diff, this contract applies it. The guarantee is crypto-economic — an
honest supermajority — not a proof. `test_offchainVetoAppliesWhatAQuorumSignsEvenIfWrong` exists to
keep that honest.

`Mode.OnchainVerify` re-runs every property inside `settle` and reverts on violation. Objective, but
you pay for the check you were trying to avoid. Reasonable for cheap property sets, for a rollout
period, and for proving in tests that the guard is load-bearing rather than decorative.

## Subscribing

Properties are published in a `PropertyCatalogue` and adopters subscribe through a
`SubscriptionRegistry`. Configuration is stored per (adopter, property) and read at check time, so
**one property deployment serves every adopter** — a `Monotonic` on a chain protects everyone who asks
it to, each with their own slot set. Subscribing is a config write, not a deploy.

```solidity
subs.subscribe(adopter, monotonic, abi.encode(watchedSlots));   // once
subs.updateConfig(adopter, monotonic, abi.encode(newSlots));    // whenever
(bool ok, string memory which,) = subs.checkAll(adopter, ctx);  // operators, monitors, settle
```

Authorisation goes through a pluggable `IAdopterAdmin`, not `msg.sender == adopter`, because a
contract already deployed cannot call `subscribe` and never will:

| Verifier | Who may configure | For |
|---|---|---|
| `AdminVerifierSelf` | the adopter itself | contracts written against this system |
| `AdminVerifierOwnable` | whatever `owner()` returns | the large population of deployed Ownable contracts, untouched |
| `AdminVerifierAllowlist` | a curated binding | adopters whose admin cannot be read on-chain (multisig governance, external proxy admin) |

This mirrors Phylax's pluggable admin verifiers on their `StateOracle`; the parity audit listed its
absence as a gap on our side.

Two deliberate fail-closed choices. An unconfigured self-contained property refuses every transition
rather than passing them — a `SlotProtection` with no slots would otherwise read as protection while
providing none, which is worse than no guard. And `subscribe` rejects an empty config for those
properties, so the door has two locks.

Listings are versioned and immutable: a property's behaviour is a security assumption, so repointing a
listing at new code would repoint every subscriber's guarantees with it. A revision is a new listing.
Deprecation marks a listing unrecommended without breaking anyone already on it.

The five self-contained properties (`SlotProtection`, `Monotonic`, `DeltaBound`, `ValueConservation`,
`ValueRangeGuard`) read only the diff, so they need nothing from the adopter and are genuinely
drop-in. The rest read adopter view functions, which is the integration cost an ERC-4626-style adapter
would remove.

## Why properties live in their own contracts

Because evaluation is off-chain, composability is free. Properties are separate contracts in a
registry, so a team can add one to a live contract without redeploying it, reuse a library property
across contracts, and pay nothing on-chain for either. An O(holders) sweep per write is unremarkable
when nobody is paying gas for it.

| Property | Enforces |
|---|---|
| `Conservation` | sum of parts equals the declared total |
| `Solvency` | backing assets cover outstanding claims |
| `ConcentrationCap` | no holder exceeds a share of the total, above a bootstrap floor |
| `SlotDomain` | the diff writes only slots the target declared as its own |
| `SlotProtection` | declared slots are frozen — any write is a violation |
| `ValueConservation` | the total across a declared slot set is unchanged |
| `Monotonic` | declared slots never decrease |
| `DeltaBound` | a declared slot moves no more than its per-transition cap |
| `SharePriceFloor` | assets per share does not fall beyond a tolerance |
| `AssetFlowConsistency` | the asset delta matches the declared flow; zero address holds nothing |
| `ImplementationLock` | EIP-1967 implementation/admin/owner change only to an approved value |
| `Composite` | several properties under one AND/OR operator in a single evaluation |
| `PostOperationSolvency` | touched accounts end solvent; an underwater one is not made worse |
| `ConstantProduct` | the product of two reserves does not fall |
| `SpecConformance` | the diff is exactly what the adopter's own spec produces |
| `PanicState` | while paused, protected slots do not move |
| `ValueRangeGuard` | configuration slots stay inside their permitted range |
| `FeeConsistency` | fee accrual matches the declared rate on the base that moved |
| `OracleLiveness` | the mirrored oracle timestamp is not stale |
| `OracleDeviation` | spot does not diverge from TWAP beyond a bound |
| `ParticipantAllowlist` | every participant is on the adopter's allowlist |

### SlotDomain is the one that makes the others trustworthy

A value property is a sum over a set the contract enumerates. An attacker who writes value to an
address that set never visits does not break the sum — the sum never sees it. So conservation alone
is satisfiable by a diff that mints value out of nothing. This is the phantom-holder hole documented
in Gas Killer's own `GuardedVault` example.

Bounding the *domain* of the diff closes the class structurally instead of by adding another sum: an
undeclared slot is refused whatever it contains. `test_conservationAloneWouldMissThePhantom` removes
`SlotDomain` from the registry and shows the same diff sailing through with the books still
"balancing" while 1e18 shares exist off the register.

Two findings from building it, both worth knowing before you write your own properties:

- **A percentage cap is unsatisfiable at bootstrap.** The first depositor holds 100% of the vault, so
  a naive `ConcentrationCap` refuses every path to a healthy distribution — the property deadlocks
  the contract it guards. Hence `minTotalToEnforce`.
- **`checkNow()` is not an operator oracle.** It evaluates the post-state with an *empty* diff, so
  diff-inspecting properties have nothing to object to and return true. An operator deciding whether
  to sign must call `checkAll(ids, writes, idx)` with the real diff. Using `checkNow()` instead
  silently disables `SlotDomain` — which is exactly how a phantom credit gets attested by an operator
  that believed it was verifying. This was a live bug in the first version of the invariant handler.

## Ported from Phylax's assertion library

Phylax's Credible Layer solves an overlapping problem and their `credible-std` catalogue is the
closest thing to prior art. Their assertions are **execution-trace based**: an assertion runs in a
custom EVM (`PhEvm`) with two live forks and the transaction journal, so it can read foreign
contracts' storage, replay individual calls, and observe ERC-20 transfers. Ours are **diff based**:
a property sees the adopter's own storage diff and its view functions.

That difference decides what ports cleanly, what ports in weakened form, and what cannot port at all.

📋 **[`docs/PHYLAX-PARITY.md`](docs/PHYLAX-PARITY.md) is the full audit** — every one of their 26
protection assertions, 22 Assertions Book entries, 7 micro-patterns, 43 PhEvm cheatcodes, 9 trigger
types and 16 platform components, each marked Ported / Adapted / Weakened / Blocked / Open with the
work needed. The table below is the short version.

| Phylax assertion | Here | Fidelity |
|---|---|---|
| `SlotProtectionAssertion` / `forbidChangeForSlots` | `SlotProtection` | Full — including their conservative "a write counts even if the value is unchanged" |
| `BalanceConservationAssertion` | `ValueConservation` | Adapted — conserves the total across a declared slot set, permitting redistribution. Their foreign-token version does not port |
| monotonic-counter micro-pattern | `Monotonic` | Full, decidable from the diff alone |
| rate limits / step caps | `DeltaBound` | Full for a single transition |
| `ERC4626SharePriceAssertion` | `SharePriceFloor` | Full — endpoint comparison, tolerance in bps, empty-supply skip |
| `ERC4626AssetFlowAssertion` | `AssetFlowConsistency` | **Weakened** — checks the diff against the adopter's own declared flow, not against observed ERC-20 movement |
| `AnomalyGatedUpgradeAssertion` | `ImplementationLock` | Weakened — same EIP-1967 slots, but ungated: an allowlist replaces the anomaly score |
| `AnomalyCompositeAssertion` | `Composite` | Full for the structural part (AND/OR in one evaluation); the anomaly gate itself does not port |
| `ERC4626CumulativeOutflowAssertion` | `DeltaBound` only | **Weakened** — per-transition cap, not a rolling window |
| `SafeTxShapeAssertion`, `CowSettlementAssertion`, `UniswapV4PoolManagerAssertion` | — | **Cannot port** |

### What cannot port, and why

- **Call-level introspection.** `getCallInputs`, per-call forks, `ph.context()`. Gas Killer settles a
  storage diff; there is no call trace to inspect, so anything reasoning about *how* a state was
  reached — Safe transaction shape, CoW settlement structure, UniV4 pool-manager call sequences — has
  no expression here at all.
- **Foreign state.** `getErc20Transfers`, `changedErc20BalanceDeltas`, `load(target, slot)`. A diff
  describes the adopter's storage. The EVM has no cross-contract SLOAD, so on-chain evaluation cannot
  read a token contract's ledger even in principle. This is the gap behind the weakened
  `AssetFlowConsistency`: it catches accounting that disagrees with itself, not accounting that has
  drifted from the actual token ledger.
- **Anomaly scoring.** Their `AnomalyGated*` family blocks only when a transaction also scores as
  anomalous, which their executor computes. There is no equivalent signal here.
- **Executor-held state.** `watchCumulativeOutflow` works because their executor keeps rolling
  windows and TVL snapshots. A property here is a pure function of one transition and has nowhere to
  keep a window. Closing this is tractable — keep the window in guarded state, updated by the same
  attested diff — but it is a design change, not another property.

Trace-based assertions are strictly more expressive than diff-based properties. The compensating
advantage is that this model needs no cooperation from a block builder or sequencer, so it works on
any EVM chain with Cancun, and it can guard a computation that could never have run on-chain at all.

### Two things the port forced

- **The diff carries its own before-image.** `SlotWrite` gained `oldValue`, because nearly every
  ported assertion is a pre/post comparison and a property running inside `settle` has no second
  fork to read. `PreState` reconstructs the rest: for a touched slot pre-state is in the diff, for an
  untouched one pre-state *is* post-state.
- **Settlement verifies that before-image against live storage**, making each write a
  compare-and-swap. Without it every pre/post property is fiction — an operator could fabricate
  whatever history satisfies the check, and monotonicity, delta bounds and the share-price floor
  would all pass trivially. It also rejects a stale diff assembled against an older state.

A related trap, worth stating because it cost a real bug: a property must derive **both** endpoints
from the diff with the live read only as fallback. Reading the post endpoint from a view function
makes the property silently compare pre against pre when an operator evaluates a proposed diff before
applying it. `SharePriceFloor` had exactly that bug.

## Layout

```
src/
├── interfaces/IProperty.sol   IProperty, IGuardedDomain, IAttestor, SlotWrite, TransitionContext
├── PropertyRegistry.sol       the enforced property set, add/remove at runtime
├── GuardedState.sol           intent queue + attested settlement + checkAll
├── catalogue/                 PropertyCatalogue, SubscriptionRegistry, admin verifiers
├── subscribe/                 Guardable + LegacyVault: additive adoption for deployed contracts
├── properties/                21 property contracts, one per file
└── examples/GuardedVault.sol  worked integration; previewDeposit/previewTransfer are the spec
test/
├── GuardedVault.t.sol             12 unit tests
└── GuardedVault.invariant.t.sol   stateful suite; the handler runs a real operator veto
```

The stateful suite is worth a look for one reason: `VaultHandler._operatorSettle` simulates an honest
operator *faithfully* rather than by construction. It snapshots state, applies the diff, evaluates
every property on the result, rolls back, and settles for real only if the check passed — the same
veto a node performs. It also attempts non-conserving mints, phantom credits, and unattested
settlements on every run, and `test_handlerMakesRealProgressAndVetoesRealAttacks` asserts both that
value really accrues and that the attacks are really refused, so the invariants cannot pass vacuously.

## Running

```bash
forge build
forge test           # 97 tests: 12 vault + 26 ported + 26 reachable + 12 additive + 16 catalogue + 4 invariants + 1 anti-vacuity
```

Invariants run 256 × 64 by default (`foundry.toml`).

## Status

Built as a prototype outside the org to iterate quickly. What is real: the guard layer, the property
model, the registry, the domain check, and the test suite.

What is mocked or missing:

- **`IAttestor` is a mock.** Production wraps `GasKillerSDK.verifyAndUpdate`'s quorum check —
  aggregated BLS against an EigenLayer `IBLSSignatureChecker`, or the aggregate Schnorr scheme. The
  guard layer deliberately knows nothing about which scheme signed, only whether the digest carries
  quorum approval.
- **No EigenLayer dependency yet**, hence no `TransitionGuard`/EIP-1153 reentrancy handling. Wiring
  to the real SDK is the next step and will bring both.
- **`previewDeposit`/`previewTransfer` stand in for a general intent→diff builder.** Real operators
  need to derive a diff from arbitrary pending intents; here the vault hands them one.
- **No gas benchmarks.** The claim "properties cost nothing on-chain" is structurally true in
  `OffchainVeto` mode but unmeasured against a naive contract that checks inline. That comparison is
  the number the product should be sold on, and it does not exist yet.
