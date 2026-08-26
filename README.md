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

## What the guarantee actually is

In the default `OffchainVeto` mode nothing on-chain re-executes anything. If ≥66% of quorum stake
signs a property-violating diff, this contract applies it. The guarantee is crypto-economic — an
honest supermajority — not a proof. `test_offchainVetoAppliesWhatAQuorumSignsEvenIfWrong` exists to
keep that honest.

`Mode.OnchainVerify` re-runs every property inside `settle` and reverts on violation. Objective, but
you pay for the check you were trying to avoid. Reasonable for cheap property sets, for a rollout
period, and for proving in tests that the guard is load-bearing rather than decorative.

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

## Layout

```
src/
├── interfaces/IProperty.sol   IProperty, IGuardedDomain, IAttestor, SlotWrite, TransitionContext
├── PropertyRegistry.sol       the enforced property set, add/remove at runtime
├── GuardedState.sol           intent queue + attested settlement + checkAll
├── properties/                Conservation, Solvency, ConcentrationCap, SlotDomain
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
forge test           # 17 tests: 12 unit + 4 invariants + 1 anti-vacuity check
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
