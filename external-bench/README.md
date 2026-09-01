# External benchmarks

`SchnorrSettlementGas.t.sol` measures a real Schnorr `verifyAndUpdate` end to end. It needs the
Gas Killer SDK's sources, so it does **not** compile in this repo — run it inside a clone of
`gas-killer/solidity-sdk`:

```bash
git clone --depth 1 https://github.com/gas-killer/solidity-sdk
cp external-bench/SchnorrSettlementGas.t.sol solidity-sdk/test/
cd solidity-sdk && forge test --match-path 'test/SchnorrSettlementGas.t.sol' -vv
```

It generates real aggregate Schnorr signatures rather than replaying a fixture, because
`verifyAndUpdate` binds `msgHash` to `sha256(transitionIndex, target, targetFunction,
storageUpdates)` — a pre-baked message cannot satisfy it. Scalar multiplication is double-and-add
over the SDK's own `Secp256k1`, since the pinned forge predates the `ecMulAffine` cheatcode and
upgrading the toolchain could reprice modexp (EIP-7883) and shift every number.

Gas is deterministic for a given EVM version, so these equal what a Sepolia receipt would show for
the same diff. Sepolia would validate the *pipeline* — router, operators, aggregation — not the gas.
