#!/usr/bin/env bash
# Start a testnet source node and wait for full sync against the public network.
#
# Leaves naviod running daemonized. Use this when you want to benchmark against
# a realistic testnet chain rather than the synthetic blsctregtest load.
#
# Pre-reqs:
#   - naviod / navio-cli built (defaults to repo's src/naviod, src/navio-cli).
#   - Reachable network. testnet7 fixed seeds are .onion only — if you don't run
#     Tor locally, pass --addnode <CLEARNET_HOST:PORT> (e.g. testnet.nav.io:18333).
#
# Usage:
#   ./contrib/perf/setup-source-testnet.sh [--datadir DIR] [--addnode HOST:PORT]
#                                          [--p2p-port PORT] [--rpc-port PORT]
#                                          [--use-tor]
#                                          [--naviod-bin PATH] [--cli-bin PATH]

set -euo pipefail

DATADIR="${HOME}/navio-perf/source-node"
ADDNODE=""
USE_TOR=0
P2P_PORT=18333
RPC_PORT=18332
NAVIOD_BIN=""
CLI_BIN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --datadir) DATADIR=$2; shift 2 ;;
    --addnode) ADDNODE=$2; shift 2 ;;
    --use-tor) USE_TOR=1; shift ;;
    --p2p-port) P2P_PORT=$2; shift 2 ;;
    --rpc-port) RPC_PORT=$2; shift 2 ;;
    --naviod-bin) NAVIOD_BIN=$2; shift 2 ;;
    --cli-bin) CLI_BIN=$2; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ -z "$NAVIOD_BIN" ]] && NAVIOD_BIN="$REPO_ROOT/src/naviod"
[[ -z "$CLI_BIN" ]] && CLI_BIN="$REPO_ROOT/src/navio-cli"

[[ -x "$NAVIOD_BIN" ]] || { echo "naviod not found at $NAVIOD_BIN — build first" >&2; exit 2; }

mkdir -p "$DATADIR"
{
  echo "testnet=1"
  echo "server=1"
  echo "listen=1"
  echo "txindex=1"
  echo "dbcache=4096"
  echo "[test]"
  echo "rpcuser=perf"
  echo "rpcpassword=perfperfperfperfperfperfperfperf"
  echo "rpcport=$RPC_PORT"
  echo "port=$P2P_PORT"
  [[ -n "$ADDNODE" ]] && echo "addnode=$ADDNODE"
} > "$DATADIR/navio.conf"

cli() { "$CLI_BIN" -datadir="$DATADIR" "$@"; }

if pgrep -f "naviod.*-datadir=$DATADIR" >/dev/null; then
  echo "naviod already running at $DATADIR"
else
  args=( -datadir="$DATADIR" -daemon )
  if (( USE_TOR )); then
    if ! ss -tln 2>/dev/null | grep -q "127.0.0.1:9050"; then
      echo "warning: --use-tor passed but tor not listening on 9050" >&2
    fi
    args+=( -proxy=127.0.0.1:9050 -onion=127.0.0.1:9050 )
  fi
  echo "starting naviod (testnet)"
  "$NAVIOD_BIN" "${args[@]}" >/dev/null
fi
for _ in $(seq 1 30); do cli getblockchaininfo >/dev/null 2>&1 && break; sleep 1; done

echo "waiting for sync (this may take a while)..."
last_h=-1
stable_ticks=0
while :; do
  info=$(cli getblockchaininfo 2>/dev/null) || { sleep 5; continue; }
  blocks=$(echo "$info" | grep -oP '"blocks":\s*\K[0-9]+')
  headers=$(echo "$info" | grep -oP '"headers":\s*\K[0-9]+')
  ibd=$(echo "$info" | grep -oP '"initialblockdownload":\s*\K(true|false)')
  net=$(cli getnetworkinfo 2>/dev/null)
  conn=$(echo "$net" | grep -oP '"connections":\s*\K[0-9]+')
  echo "  $(date +%H:%M:%S) blocks=$blocks/$headers peers=$conn ibd=$ibd"
  if [[ "$ibd" == "false" && "$blocks" -ge "$headers" && "$blocks" -gt 0 ]]; then
    if [[ "$blocks" == "$last_h" ]]; then
      stable_ticks=$((stable_ticks + 1))
      (( stable_ticks >= 2 )) && break
    else
      stable_ticks=0
    fi
    last_h=$blocks
  fi
  sleep 30
done

echo "synced. blocks=$blocks peers=$conn"
echo "source node ready at 127.0.0.1:$P2P_PORT"
echo "next: run contrib/perf/bench-mcl-backends.sh --source-port $P2P_PORT"
