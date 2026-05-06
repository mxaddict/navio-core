#!/usr/bin/env bash
# Build a synthetic blsctregtest source node with PoS-produced BLSCT-rich blocks.
#
# Bootstraps two BLSCT wallets, funds them with a short PoW window, has each
# stakelock so the chain has >=2 staked commitments, then runs navio-staker
# to mint PoS blocks. While the staker runs, this script injects BLSCT spend
# txs in a loop so each block carries the coinbase + 1 BLSCT tx (range proofs
# + agg sig load) while still exercising the full PoS validation path
# (set-membership proof, kernel range proof, stake modifier).
#
# REQUIRES the bench-only chainparams patch on this branch:
#   - blsctregtest nLastPOWHeight = 300
#   - blsctregtest nPosTargetSpacing = 1
#   - blsctregtest fPosNoRetargeting = true
#   - blsctregtest nBLSCTBlockReward = 2 * COIN
# (see src/kernel/chainparams.cpp:CBLSCTRegTestParams)
#
# Leaves naviod + navio-staker running daemonized at 127.0.0.1:18444 (P2P)
# so the runner script can connect a test node to it. Re-running is idempotent:
# if a chain already exists past the target height it skips load gen.
#
# Usage:
#   ./contrib/perf/setup-source-blsct-load.sh [--datadir DIR] [--cycles N]
#                                             [--p2p-port PORT] [--rpc-port PORT]
#                                             [--naviod-bin PATH] [--cli-bin PATH]
#                                             [--staker-bin PATH] [--wallet-bin PATH]

set -euo pipefail

DATADIR="${HOME}/navio-perf/load-source"
CYCLES=500
P2P_PORT=18444
RPC_PORT=18443
NAVIOD_BIN=""
CLI_BIN=""
STAKER_BIN=""
WALLET_BIN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --datadir) DATADIR=$2; shift 2 ;;
    --cycles) CYCLES=$2; shift 2 ;;
    --p2p-port) P2P_PORT=$2; shift 2 ;;
    --rpc-port) RPC_PORT=$2; shift 2 ;;
    --naviod-bin) NAVIOD_BIN=$2; shift 2 ;;
    --cli-bin) CLI_BIN=$2; shift 2 ;;
    --staker-bin) STAKER_BIN=$2; shift 2 ;;
    --wallet-bin) WALLET_BIN=$2; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ -z "$NAVIOD_BIN" ]] && NAVIOD_BIN="$REPO_ROOT/src/naviod"
[[ -z "$CLI_BIN" ]] && CLI_BIN="$REPO_ROOT/src/navio-cli"
[[ -z "$STAKER_BIN" ]] && STAKER_BIN="$REPO_ROOT/src/navio-staker"
[[ -z "$WALLET_BIN" ]] && WALLET_BIN="$REPO_ROOT/src/navio-wallet"

for b in "$NAVIOD_BIN" "$CLI_BIN" "$STAKER_BIN" "$WALLET_BIN"; do
  [[ -x "$b" ]] || { echo "binary not found at $b — build first" >&2; exit 2; }
done

RPC_USER=load
RPC_PASS=loadloadloadloadloadloadloadload

mkdir -p "$DATADIR"
cat > "$DATADIR/navio.conf" <<EOF
chain=blsctregtest
server=1
listen=1
dbcache=4096
fallbackfee=0.0002
[blsctregtest]
rpcuser=$RPC_USER
rpcpassword=$RPC_PASS
rpcport=$RPC_PORT
port=$P2P_PORT
EOF

cli() { "$CLI_BIN" -datadir="$DATADIR" -chain=blsctregtest "$@"; }
cli_w() { cli -rpcwallet="$1" "${@:2}"; }

stop_existing() {
  if pgrep -f "navio-staker.*-datadir=$DATADIR" >/dev/null; then
    pkill -f "navio-staker.*-datadir=$DATADIR" || true
    sleep 2
  fi
  if pgrep -f "naviod.*-datadir=$DATADIR" >/dev/null; then
    cli stop >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      pgrep -f "naviod.*-datadir=$DATADIR" >/dev/null || break
      sleep 1
    done
  fi
}

stop_existing
echo "starting naviod (blsctregtest) at $DATADIR"
"$NAVIOD_BIN" -datadir="$DATADIR" -daemon >/dev/null
for _ in $(seq 1 30); do cli getblockchaininfo >/dev/null 2>&1 && break; sleep 1; done

# --------- ensure two BLSCT wallets exist ---------
ensure_wallet() {
  local w=$1
  if cli listwallets 2>/dev/null | grep -q "\"$w\""; then return; fi
  if [[ ! -d "$DATADIR/blsctregtest/wallets/$w" ]]; then
    "$WALLET_BIN" -datadir="$DATADIR" -blsct -chain=blsctregtest -wallet="$w" create >/dev/null 2>&1
  fi
  cli loadwallet "$w" >/dev/null
}
ensure_wallet w1
ensure_wallet w2

A1=$(cli_w w1 getnewaddress "" blsct)
A2=$(cli_w w2 getnewaddress "" blsct)
THROW=$(cli_w w1 getnewaddress "" blsct)

# --------- bootstrap if not already done (idempotent) ---------
current_height=$(cli getblockcount)
target_pow_height=290
if (( current_height < target_pow_height )); then
  echo "PoW funding phase: mining to height $target_pow_height"
  # 100 to w1, 100 to w2, then 90 to throwaway so w2's coinbases mature
  cli_w w1 generatetoblsctaddress 100 "$A1" >/dev/null
  cli_w w2 generatetoblsctaddress 100 "$A2" >/dev/null
  cli_w w1 generatetoblsctaddress 90 "$THROW" >/dev/null
fi

# --------- stakelock on both wallets if needed ---------
sc_count=$(cli getblocktemplate '{"rules":["segwit"],"coinbasedest":"'"$A1"'"}' \
  | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("staked_commitments",[])))' 2>/dev/null || echo 0)
if (( sc_count < 2 )); then
  echo "stakelock phase: locking 150 from each wallet"
  cli_w w1 stakelock 150 >/dev/null
  cli_w w2 stakelock 150 >/dev/null
  cli_w w1 generatetoblsctaddress 5 "$THROW" >/dev/null
fi

# --------- start staker ---------
if ! pgrep -f "navio-staker.*-datadir=$DATADIR" >/dev/null; then
  echo "starting navio-staker (mints to w1)"
  "$STAKER_BIN" -datadir="$DATADIR" -chain=blsctregtest -wallet=w1 \
    -rpcuser="$RPC_USER" -rpcpassword="$RPC_PASS" -rpcport="$RPC_PORT" \
    > "$DATADIR/staker.log" 2>&1 &
  disown
  sleep 2
fi

target_height=$((target_pow_height + 5 + CYCLES))
current_height=$(cli getblockcount)
if (( current_height >= target_height )); then
  echo "chain already at height $current_height (target $target_height) — skipping spend cycles"
  echo "source node ready at 127.0.0.1:$P2P_PORT"
  exit 0
fi

# --------- spend cycles: send a BLSCT tx, wait for next block ---------
echo "running $CYCLES BLSCT spend cycles (PoS blocks via staker)"
start=$(date +%s)
last_height=$(cli getblockcount)
for i in $(seq 1 "$CYCLES"); do
  a=$(cli_w w1 getnewaddress "" blsct)
  cli_w w1 sendtoaddress "$a" 0.001 >/dev/null 2>&1 || true
  # wait for staker to mint a new block including the tx
  for w in $(seq 1 60); do
    h=$(cli getblockcount)
    (( h > last_height )) && break
    sleep 1
  done
  last_height=$(cli getblockcount)
  if (( i % 50 == 0 )); then
    echo "  cycle=$i height=$last_height elapsed=$(($(date +%s) - start))s"
  fi
done

final=$(cli getblockcount)
echo "done. final height=$final, naviod + navio-staker still running at 127.0.0.1:$P2P_PORT"
echo "next: run contrib/perf/bench-mcl-backends.sh --chain blsctregtest --source-port $P2P_PORT"
