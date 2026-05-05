#!/usr/bin/env bash
# Build a synthetic blsctregtest source node with BLSCT-rich blocks for perf testing.
#
# Each cycle does one BLSCT spend then mines one block. The resulting chain has
# the coinbase + 1 BLSCT spend tx (~3 range proofs total) per block — far more
# load per block than testnet7, which is mostly empty.
#
# Leaves naviod running daemonized at 127.0.0.1:18444 (P2P) so the runner script
# can connect a test node to it. Re-running is idempotent: if a chain already
# exists at the target height it will skip generation.
#
# Pre-reqs:
#   - naviod and navio-cli built (run from repo root or pass --naviod-bin / --cli-bin).
#   - System libgmp / libgmpxx (or built --without-gmp).
#
# Usage:
#   ./contrib/perf/setup-source-blsct-load.sh [--datadir DIR] [--cycles N]
#                                             [--p2p-port PORT] [--rpc-port PORT]
#                                             [--naviod-bin PATH] [--cli-bin PATH]

set -euo pipefail

DATADIR="${HOME}/navio-perf/load-source"
CYCLES=500
P2P_PORT=18444
RPC_PORT=18443
NAVIOD_BIN=""
CLI_BIN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --datadir) DATADIR=$2; shift 2 ;;
    --cycles) CYCLES=$2; shift 2 ;;
    --p2p-port) P2P_PORT=$2; shift 2 ;;
    --rpc-port) RPC_PORT=$2; shift 2 ;;
    --naviod-bin) NAVIOD_BIN=$2; shift 2 ;;
    --cli-bin) CLI_BIN=$2; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ -z "$NAVIOD_BIN" ]] && NAVIOD_BIN="$REPO_ROOT/src/naviod"
[[ -z "$CLI_BIN" ]] && CLI_BIN="$REPO_ROOT/src/navio-cli"

[[ -x "$NAVIOD_BIN" ]] || { echo "naviod not found at $NAVIOD_BIN — build first" >&2; exit 2; }
[[ -x "$CLI_BIN" ]] || { echo "navio-cli not found at $CLI_BIN" >&2; exit 2; }

mkdir -p "$DATADIR"
cat > "$DATADIR/navio.conf" <<EOF
chain=blsctregtest
server=1
listen=1
dbcache=4096
fallbackfee=0.0002
[blsctregtest]
rpcuser=load
rpcpassword=loadloadloadloadloadloadloadload
rpcport=$RPC_PORT
port=$P2P_PORT
EOF

cli() { "$CLI_BIN" -datadir="$DATADIR" -chain=blsctregtest "$@"; }

# kill any existing instance using this datadir
if pgrep -f "naviod.*-datadir=$DATADIR" >/dev/null; then
  echo "stopping existing naviod at $DATADIR"
  cli stop >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    pgrep -f "naviod.*-datadir=$DATADIR" >/dev/null || break
    sleep 1
  done
fi

echo "starting naviod (blsctregtest) at $DATADIR"
"$NAVIOD_BIN" -datadir="$DATADIR" -daemon >/dev/null
for _ in $(seq 1 30); do cli getblockchaininfo >/dev/null 2>&1 && break; sleep 1; done

# load (or create) wallet
if cli listwallets 2>/dev/null | grep -q '"load"'; then
  :
elif [[ -d "$DATADIR/blsctregtest/wallets/load" ]]; then
  cli loadwallet load >/dev/null
else
  cli -named createwallet wallet_name=load blsct=true >/dev/null
fi
cli_w() { cli -rpcwallet=load "$@"; }

current_height=$(cli getblockcount)
target_height=$((101 + CYCLES))
if (( current_height >= target_height )); then
  echo "chain already at height $current_height (target $target_height) — skipping load gen"
  echo "source node ready at 127.0.0.1:$P2P_PORT"
  exit 0
fi

ADDR=$(cli_w getnewaddress "" blsct)

if (( current_height < 101 )); then
  echo "mining 101 funding blocks"
  cli_w generatetoblsctaddress 101 "$ADDR" >/dev/null
fi

# accumulate trusted balance (need ~200 mature blocks for sendmany/send)
trusted=$(cli_w getbalances | grep -oP '"trusted":\s*\K[0-9.]+' | head -1)
if (( $(echo "$trusted < 100" | bc -l) )); then
  echo "mining 200 blocks to mature balance"
  cli_w generatetoblsctaddress 200 "$ADDR" >/dev/null
fi

start=$(date +%s)
echo "running $CYCLES BLSCT spend+mine cycles"
for i in $(seq 1 "$CYCLES"); do
  a=$(cli_w getnewaddress "" blsct)
  cli_w sendtoaddress "$a" 0.001 >/dev/null 2>&1 || echo "send failed at cycle $i" >&2
  cli_w generatetoblsctaddress 1 "$ADDR" >/dev/null
  if (( i % 50 == 0 )); then
    h=$(cli getblockcount)
    echo "  cycle=$i height=$h elapsed=$(($(date +%s) - start))s"
  fi
done

final=$(cli getblockcount)
echo "done. final height=$final, naviod still running at 127.0.0.1:$P2P_PORT"
echo "next: run contrib/perf/bench-mcl-backends.sh --chain blsctregtest --source-port $P2P_PORT"
