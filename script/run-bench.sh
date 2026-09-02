#!/usr/bin/env bash
# Deploy the guards and the lending example to a chain, send one guarded and one unguarded
# borrow(), and print the gas each receipt reports.
#
#   ./script/run-bench.sh                          # local anvil, nothing to set up
#   RPC_URL=... PRIVATE_KEY=... ./script/run-bench.sh   # any real chain
#
# MARKETS defaults to 30, roughly what Aave carries.

set -euo pipefail
cd "$(dirname "$0")/.."

MARKETS="${MARKETS:-30}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ANVIL_PID=""

# Anvil's first well-known dev key. Only ever used against a local node.
ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

if [[ "$RPC_URL" == *127.0.0.1* || "$RPC_URL" == *localhost* ]]; then
  if ! cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo "starting anvil..."
    anvil --port "${RPC_URL##*:}" --silent &
    ANVIL_PID=$!
    trap '[[ -n "$ANVIL_PID" ]] && kill "$ANVIL_PID" 2>/dev/null || true' EXIT
    for _ in $(seq 1 30); do
      cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break
      sleep 1
    done
  fi
  PRIVATE_KEY="${PRIVATE_KEY:-$ANVIL_KEY}"
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "PRIVATE_KEY is required for a non-local RPC." >&2
  exit 1
fi

CHAIN=$(cast chain-id --rpc-url "$RPC_URL")
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")

echo "chain=$CHAIN  markets=$MARKETS"
echo "deployer=$DEPLOYER  balance=$(cast from-wei "$BALANCE") ETH"

if [[ "$BALANCE" == "0" ]]; then
  echo "Deployer has no balance — fund it first." >&2
  exit 1
fi

MARKETS="$MARKETS" PRIVATE_KEY="$PRIVATE_KEY" \
  forge script script/GuardBench.s.sol --rpc-url "$RPC_URL" --broadcast --slow

echo
echo "=== gas from the receipts ==="
python3 - "$CHAIN" <<'PY'
import json, sys
run = f"broadcast/GuardBench.s.sol/{sys.argv[1]}/run-latest.json"
d = json.load(open(run))
rcs = {r["transactionHash"]: r for r in d["receipts"]}
for t in d["transactions"][-2:]:
    r = rcs.get(t["hash"], {})
    used = int(r.get("gasUsed", "0x0"), 16)
    print(f'  {(t.get("function") or "?"):<34} {used:>10,}   {t["hash"]}')
print()
print("  These are full-transaction figures: intrinsic (21,000 + calldata) plus execution.")
print("  docs/GAS.md quotes harness execution, which runs about 16,340 lower. See the")
print("  'Harness versus receipt' note there before comparing.")
PY
