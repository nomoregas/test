# Running this on Sepolia

Everything in [`docs/GAS.md`](GAS.md) is measured locally. Gas is deterministic for a given EVM
version, so a Sepolia receipt shows the same numbers for the same diff — what a live run adds is
proof of the **pipeline**: that the router sequences a task, operators actually sign it, and real
aggregation verifies on-chain.

## Prerequisites

A Claude Code web session cannot reach any RPC endpoint unless the environment's network policy
allows it. All of these returned 403 at the egress proxy on CONNECT: Ankr, Blast, BlockPI, Omnia,
Tenderly, thirdweb, ZAN, Alchemy, Infura, drpc, RockX, SubQuery, OnFinality, Grove, publicnode,
rpc.sepolia.org. `example.com` and `google.com` fail the same way while GitHub, npm and PyPI pass,
so it is an allowlist rather than per-host blocking.

To run from a web session, the environment needs one RPC host allowed — `eth-sepolia.g.alchemy.com`
or `sepolia.infura.io`, plus `api-sepolia.etherscan.io` if you want verification. Network policy is
set when an environment is created, so a policy change needs a **new session** to take effect; the
running container keeps the policy it started with.

Nothing here needs a Claude session, though. It all runs from a laptop.

## 1. The guarded call, on-chain

```bash
RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY \
PRIVATE_KEY=0xyour_funded_key \
MARKETS=30 \
./script/run-bench.sh
```

Deploys the catalogue, registry, six rules and the lending example, seeds the markets one
transaction at a time, then sends one guarded and one unguarded `borrow()` and prints the gas from
both receipts. Budget about 0.1 ETH at 30 markets.

Expected, from the anvil run: **764,114** guarded and **31,986** unguarded at 30 markets. These are
full-transaction figures — see *Harness versus receipt* in `GAS.md` for why they sit 16,339 above
the numbers a Foundry test reports.

## 2. Settlement

```bash
git clone --depth 1 https://github.com/gas-killer/solidity-sdk
cp external-bench/SchnorrSettlementGas.t.sol solidity-sdk/test/
cd solidity-sdk && forge test --match-path 'test/SchnorrSettlementGas.t.sol' -vv
```

This is local and needs no key — it stands up a real `SchnorrStakeRegistry`, registers operators
whose keys it generates, signs the diff itself, and calls `verifyAndUpdate`. Expected **56,369** for
a two-word diff at full participation.

To put the same thing on Sepolia, the test becomes a script: deploy `SchnorrStakeRegistry` and a
`SchnorrGasKillerSDK` consumer, `registerOperator` each key with its proof of possession, then send
`verifyAndUpdate`. The signing helpers port across unchanged. Note this plays the operators itself,
so it proves the on-chain path, not the AVS.

## 3. The actual pipeline

Steps 1 and 2 never involve Gas Killer's own infrastructure. For that: `gas-killer/service` has a
`docker compose` local stack (Anvil fork of Sepolia, EigenLayer deploy, three operators, router,
Cerberus signer). Point it at a deployed guarded contract, have the router assemble a certificate
over a real transition, and settle that.

This is the part with genuinely unknown outcomes — operator-set churn, `blockStaleMeasure` windows,
`StaleSnapshot` rejections under registration races. The gas is settled; the integration is not.

## Notes

- A key generated inside a Claude session dies with the container. Fund an address you control, or
  open egress first and generate one only once a node is reachable.
- The `gk_` API key belongs to the router/service, not to any of the above. Nothing in steps 1 or 2
  uses it.
- `gaskiller.xyz` is blocked from web sessions, so the SDK README rather than the hosted docs is the
  reference for integration.
