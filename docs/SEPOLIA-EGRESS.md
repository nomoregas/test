# Egress and the Sepolia run: what works

The "Full access" environment **can** reach a Sepolia node. The 403-at-CONNECT wall described in
[`SEPOLIA.md`](SEPOLIA.md) was that environment's allowlist, not a property of Claude sessions.

## The RPC endpoint that works

```
https://ethereum-sepolia-rpc.publicnode.com
```

`eth_chainId` returns `0xaa36a7`; `cast chain-id` returns `11155111`. No API key, no signup.

Probed on 2026-09-02, POSTing `eth_chainId`:

| Endpoint | Result |
| --- | --- |
| `ethereum-sepolia-rpc.publicnode.com` | **200, `0xaa36a7`** — works |
| `eth-sepolia.g.alchemy.com` (`/v2/demo`) | 200 transport, **429** rate-limited — needs a key |
| `sepolia.infura.io` | 200 transport, **401** `invalid project id` — needs a key |
| `rpc.ankr.com/eth_sepolia` | 200 transport, JSON-RPC `-32000` unauthorized — needs a key |
| `sepolia.drpc.org` | 400, `chain is not available on free plan` |
| `eth-sepolia.public.blastapi.io` | 403 from Blast itself, service retired |

The distinction that matters: every one of these completed a TLS connection and returned an
application-level response. None was refused by the egress proxy. Alchemy and Infura are reachable
and would work with a key — publicnode simply needs no key, so it is the one we use.

`publicnode` is a free public endpoint and may rate-limit under load. `run-bench.sh` passes `--slow`,
which sends one transaction at a time and waits for each receipt, so the request rate stays low.

## Funding address

```
0x86dF8164fA70312b26eB8f2211a7eAEaFf4Ad89b
```

Freshly generated with `cast wallet new`. The private key is held **outside this repository**, in the
session scratchpad at mode 600, and is not committed anywhere. It dies with the container — so this
address is worth exactly what is sent to it, and nothing should be sent to it that is not meant to be
spent on this benchmark.

Balance at time of writing: 0.

## The command to run once it is funded

```bash
RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
PRIVATE_KEY=<the key in the scratchpad> \
MARKETS=30 \
./script/run-bench.sh
```

### How much to send

`forge script` estimates **37,290,915 gas** for the whole run at 30 markets — the catalogue, the
registry, six market rules, the lending example, 30 seeding transactions, and the two `borrow()`
calls. Sepolia's gas price was 1.1 gwei when probed, which puts the run near 0.041 ETH. **0.1 ETH**
leaves comfortable headroom if the price moves.

## Toolchain notes for whoever runs this next

Neither Foundry nor `forge-std` is present in a fresh container, and two of the usual install paths
are closed:

- `foundryup` pulls from `foundry.paradigm.xyz` — not reachable here.
- `api.github.com` is scoped to this session's own repository, so the releases API returns 403 for
  `foundry-rs/foundry`. Asset *downloads* from `github.com/.../releases/download/...` do work.

What worked: download `foundry_stable_linux_amd64.tar.gz` from the `stable` tag directly. The
transfer was cut off twice mid-stream (~50 MB and ~55 MB of 79,867,740 bytes); the server honours
range requests, so `curl -C -` in a retry loop finishes it. Extract to `~/.foundry/bin`.

Then `git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std` — it is gitignored
rather than vendored, and nothing compiles without it.

Installed and verified: forge/cast 1.5.1-stable.

## The local baseline reproduces

Run in this container before spending anything real, against local anvil:

```
borrow(uint256,uint256)               764,114
unguardedBorrow(uint256,uint256)       31,986
```

Both match `SEPOLIA.md` to the gas. The harness is sound in this environment, so a Sepolia figure
that comes back different is a real difference and not a broken setup.
