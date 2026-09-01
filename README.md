# Guards — contract safety rules that run on every call

> Prototype. Unaudited.

The most valuable checks a contract could run are the ones it cannot afford to. Do the balances still
add up across every holder? Is the vault still solvent? Has one account grown past its cap? Each is a
sweep over everything the contract stores, on every call. Too expensive, so they get pushed into
pre-deploy fuzzing or a monitoring script that notices afterwards.

**Guards put them in the call.** A rule is a Solidity contract. A guarded function runs its rules
before returning and reverts if any of them break, so a violating call never lands.

## This needs nothing but the EVM

No operators. No quorum. No attestation. No cooperation from a sequencer or block builder. Deploy on
any EVM and the guard works, because it is just Solidity.

**Gas Killer is orthogonal, and it is the reason this is worth doing.** Running an O(N) sweep on every
call costs real gas, which is exactly why contracts do not already do it. Gas Killer executes the call
off-chain and settles the result, so that compute is free to the user. It has no idea what the code it
accelerates does, and is not a party to the security of anything here.

So: the guard provides the security, Gas Killer removes the reason not to use it. Either half works
without the other.

## Two modes

`Enforce` (the default) reverts on a violation, so the bad state never lands. `Detect` lets the call
succeed and emits `GuardViolation` instead.

Detect exists for two reasons. Rolling a new rule out over a live protocol in Enforce mode means
discovering a false positive by breaking user transactions; Detect measures the false-positive rate
against real traffic first. And an Enforce-mode violation leaves **no on-chain trace at all** — the
call reverted — so anything that needs evidence a rule was broken (an incident timeline, a claims
process, an insurer) has nothing to cite.

Detect provides no protection. A contract in Detect mode is monitored, not guarded.

## Integration

```solidity
contract Vault is Guarded {                                   // + inherit
    constructor(SubscriptionRegistry r) Guarded(r) {}         // + pass the registry

    function deposit(uint256 assets) external guarded {       // + one modifier
        shares[msg.sender] += assets;
        totalShares += assets;
        totalAssets += assets;
    }
}
```

Nothing becomes asynchronous. `deposit` credits the caller in the same transaction, same as before.
See [`src/examples/Vault.sol`](src/examples/Vault.sol) for the whole thing, including a deliberate
accounting bug that the guard reverts and an unguarded copy of the same bug that lands.

## Subscribing

Rules are published in a `PropertyCatalogue` and contracts subscribe through a
`SubscriptionRegistry`. Configuration is stored per (contract, rule) and read at check time, so **one
rule deployment serves every subscriber** — a single `Monotonic` on a chain protects everyone who asks
it to, each with their own watched slots. Subscribing is a config write, not a deploy.

```solidity
subs.subscribe(myContract, monotonic, abi.encode(watchedSlots));
subs.updateConfig(myContract, monotonic, abi.encode(newSlots));
subs.unsubscribe(myContract, monotonic);
```

Subscribing is what turns a rule on: the `guarded` modifier evaluates exactly the rules the contract
subscribes to. Unsubscribe and it stops being enforced on the next call, with no redeployment.

Authorisation goes through a pluggable `IAdopterAdmin`, not `msg.sender == adopter`, because a
contract already deployed cannot call `subscribe` and never will:

| Verifier | Who may configure | For |
|---|---|---|
| `AdminVerifierSelf` | the contract itself | contracts written against this system |
| `AdminVerifierOwnable` | whatever `owner()` returns | deployed Ownable contracts, untouched |
| `AdminVerifierAllowlist` | a curated binding | contracts whose admin cannot be read on-chain |

Listings are versioned and immutable. A rule's behaviour is a security assumption, so repointing a
listing at new code would repoint every subscriber's guarantees with it. A revision is a new listing;
deprecation marks one unrecommended without breaking anyone on it.

## The rules

| Rule | Enforces |
|---|---|
| `Conservation` | sum of parts equals the declared total |
| `Solvency` | backing assets cover outstanding claims |
| `ConcentrationCap` | no holder exceeds a share of the total, above a bootstrap floor |
| `PostOperationSolvency` | touched accounts end solvent; an underwater one is not made worse |
| `ConstantProduct` | the product of two reserves does not fall |
| `SharePriceFloor` | assets per share does not fall beyond a tolerance |
| `AssetFlowConsistency` | the asset delta matches the declared flow; zero address holds nothing |
| `FeeConsistency` | fee accrual matches the declared rate on the base that moved |
| `ValueConservation` | the total across a declared slot set is unchanged |
| `Monotonic` | declared slots never decrease |
| `DeltaBound` | a declared slot moves no more than its per-call cap |
| `ValueRangeGuard` | configuration slots stay inside their permitted range |
| `SlotProtection` | declared slots are frozen — any write is a violation |
| `SlotDomain` | only slots the contract declared as its own may change |
| `ImplementationLock` | EIP-1967 implementation/admin/owner change only to an approved value |
| `PanicState` | while paused, protected slots do not move |
| `OracleLiveness` | the mirrored oracle timestamp is not stale |
| `OracleDeviation` | spot does not diverge from TWAP beyond a bound |
| `ParticipantAllowlist` | every participant is on the contract's allowlist |
| `SpecConformance` | changes are exactly what the contract's own preview produces |
| `Composite` | several rules under one AND/OR operator in a single evaluation |
| `CallAllowlist` | a transition only calls approved addresses, within value limits |
| `RequiredEvent` | a state change must announce itself with a given event |
| `NoUnexpectedEvents` | every event emitted is one the contract declared |

Rules split into three kinds:

- **State** rules read the contract's own view functions and need no configuration.
- **Diff** rules (`SlotProtection`, `Monotonic`, `DeltaBound`, `ValueConservation`, `ValueRangeGuard`,
  `SlotDomain`) judge *what changed* rather than the resulting state. `PreState` reconstructs
  before-and-after from the diff.
- **Effect** rules (`CallAllowlist`, `RequiredEvent`, `NoUnexpectedEvents`) judge what the transition
  did outwardly. Gas Killer's settlement applies `sstore`, `call` **and** `log`, so a settlement's
  calls and events are part of the diff and a rule can judge them. `CallAllowlist` is the important
  one: a settlement that can call anything can move anything, so bounding call targets does for
  outward effects what `SlotDomain` does for storage.

Diff and effect rules need the transition handed to them via `_guardedWith`; the bare `guarded`
modifier passes empty lists, since a plain call has no declared effect list.

Two findings worth knowing before writing your own:

- **A percentage cap is unsatisfiable at bootstrap.** The first depositor holds 100% of the vault, so
  a naive `ConcentrationCap` refuses every path to a healthy distribution — the rule deadlocks the
  contract it guards. Hence `minTotalToEnforce`.
- **`SlotDomain` is what makes value rules trustworthy.** A conservation sum only visits accounts the
  contract enumerates, so value written to an unregistered address is invisible to it and the books
  still balance. Bounding which slots may change closes that class structurally.

## Layout

```
src/
├── Guarded.sol                the modifier; runs the rules, reverts on violation
├── PreState.sol               before/after reconstruction for diff-based rules
├── catalogue/                 PropertyCatalogue, SubscriptionRegistry, admin verifiers
├── properties/                24 rules, one per file
└── examples/Vault.sol         ordinary synchronous vault, guarded
test/                          125 tests
```

## Running

```bash
forge build
forge test
```

## What it costs

Measured, not modelled — [`docs/GAS.md`](docs/GAS.md) has the method and the caveats.

A `borrow()` on a multi-asset lending protocol under a six-rule risk policy (per-market solvency,
caps, oracle freshness, index floors, risk parameters, global accounting):

| Markets | Unguarded | Guarded | Via Gas Killer | Saving |
|---:|---:|---:|---:|---:|
| 5 | 15,635 | 192,097 | 93,208 | **+98,889** |
| 10 | 15,635 | 303,226 | 93,208 | **+210,018** |
| 20 | 15,635 | 525,492 | 93,208 | **+432,284** |
| 30 | 15,635 | 747,775 | 93,208 | **+654,567** |
| 40 | 15,635 | 970,068 | 93,208 | **+876,860** |

Settlement is via `SchnorrGasKillerSDK` — one aggregate secp256k1 signature verified in constant
gas. **There is no break-even: the policy wins at every size, from one market.** Aave carries
roughly thirty, where the policy costs 48× the transaction it protects, which is why nobody runs
these checks today.

The 93,208 is 76,117 of measured non-signature transaction plus **17,091 of measured Schnorr
verification** — the SDK's own `SchnorrStakeRegistryGas` benchmark, cold, at full participation.
The composition is arithmetic; a Schnorr settlement has not been observed end to end. Each
non-signer adds 10,194. The BLS path costs **300,944**, of which 224,827 is signature verification
alone. Choosing the scheme changes the argument completely: under BLS a single rule does not justify
settlement and two do, while under Schnorr one rule breaks even at 13 markets. [`docs/GAS.md`](docs/GAS.md) has the
derivation and the one caveat that cuts the other way.

Settlement is flat because a guard writes nothing, so a guarded call produces the same diff as an
unguarded one.

## Status## Status

Built: the 24 rules, the catalogue and subscription model, the `Guarded` modifier, a worked example,
125 tests including a stateful suite, and the gas benchmark above.

Not built:
- **Nothing verifies a rule does what it says.** A subscriber trusts an address. Phylax publishes
  assertion code to a DA layer for this reason.
- **No backtesting.** Replaying historical transactions would show how often a rule blocks something
  legitimate. Two rules here already turned out to deadlock the contracts they guard; both were caught
  by hand.
- **Only the self-contained rules are configurable through the catalogue.** The rest read contract
  view functions, so integrating them still means writing those views. An ERC-4626 adapter would
  remove that for standard vaults.
