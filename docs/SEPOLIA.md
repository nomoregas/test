# Running this on Sepolia

Everything in [`docs/GAS.md`](GAS.md) is measured locally. Gas is deterministic for a given EVM
version, so a Sepolia receipt shows the same numbers for the same diff — what a live run adds is
proof of the **pipeline**: that the router sequences a task, operators actually sign it, and real
aggregation verifies on-chain.

## Prerequisites

A funded key and an RPC endpoint. From a laptop that is all.

`https://ethereum-sepolia-rpc.publicnode.com` works with no API key or signup — verified returning
chain id `11155111`. Alchemy and Infura work too but need a key; drpc rejects Sepolia on its free
plan and Blast's public endpoint is retired.

**If you are running this from a Claude Code web session**, its environment's network policy has to
allow an RPC host. On a restrictive policy every provider returns 403 at the egress proxy on
CONNECT, and so do `example.com` and `google.com` while GitHub, npm and PyPI pass — an allowlist,
not per-host blocking. Policy is fixed when an environment is created, so a change needs a **new**
session; a running container keeps what it started with.

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

## Toolchain notes

Neither Foundry nor `forge-std` is in a fresh container, and two usual install paths may be closed:

- `foundryup` pulls from `foundry.paradigm.xyz`, which a restrictive egress policy blocks.
- The GitHub *releases API* can be scoped to a single repository, returning 403 for
  `foundry-rs/foundry`. Asset **downloads** from `github.com/.../releases/download/...` still work.

What worked: download `foundry_stable_linux_amd64.tar.gz` from the `stable` tag directly, and
`curl -C -` in a retry loop — the 80 MB transfer was cut off twice mid-stream and the server honours
range requests. Then `git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std`,
since it is gitignored rather than vendored and nothing compiles without it.
