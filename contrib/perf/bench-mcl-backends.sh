#!/usr/bin/env bash
# Benchmark mcl backends (GMP / OMP / both / neither) on a navio block sync workload.
#
# Builds 4 naviod variants, runs each against a fully-synced source node served
# over loopback (so network is eliminated as a variable), and parses the per-block
# `[perf]` log lines into a summary table.
#
# Pre-reqs:
#   - Source node already running on 127.0.0.1:<SOURCE_PORT> with the chain you
#     want to benchmark against (testnet, blsctregtest with synthetic load, etc).
#   - System libgmp / libgmpxx / libomp installed.
#   - Build tools (autoconf, make, gcc/g++).
#
# Usage:
#   ./contrib/perf/bench-mcl-backends.sh [--source-port PORT] [--runs N]
#                                        [--results-dir DIR] [--scenarios LIST]
#                                        [--chain CHAIN]
#
# Examples:
#   # Default: 3 runs of all 4 scenarios, source on testnet port 18333
#   ./contrib/perf/bench-mcl-backends.sh
#
#   # Just gmp_only and neither, 5 runs, against blsctregtest source
#   ./contrib/perf/bench-mcl-backends.sh --scenarios "gmp_only neither" \
#       --runs 5 --chain blsctregtest --source-port 18444

set -euo pipefail

# --------- defaults ---------
SOURCE_HOST=127.0.0.1
SOURCE_PORT=18333
RUNS=3
RESULTS_DIR="${HOME}/navio-perf/results"
TEST_DATADIR="${HOME}/navio-perf/test-node"
TEST_RPCPORT=18342
TEST_P2PPORT=18343
SCENARIOS="neither gmp_only omp_only both"
CHAIN=test
COMMON_CONFIGURE_FLAGS="--disable-bench --disable-tests --disable-fuzz --disable-fuzz-binary --without-gui"

# --------- parse args ---------
while [[ $# -gt 0 ]]; do
  case $1 in
    --source-host) SOURCE_HOST=$2; shift 2 ;;
    --source-port) SOURCE_PORT=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --results-dir) RESULTS_DIR=$2; shift 2 ;;
    --test-datadir) TEST_DATADIR=$2; shift 2 ;;
    --scenarios) SCENARIOS=$2; shift 2 ;;
    --chain) CHAIN=$2; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

mkdir -p "$RESULTS_DIR" "$TEST_DATADIR"

# --------- chain section header for navio.conf ---------
case "$CHAIN" in
  test) CHAIN_SECTION="test" ;;
  signet) CHAIN_SECTION="signet" ;;
  regtest) CHAIN_SECTION="regtest" ;;
  blsctregtest) CHAIN_SECTION="blsctregtest" ;;
  main) CHAIN_SECTION="main" ;;
  *) echo "unknown chain: $CHAIN" >&2; exit 2 ;;
esac

# --------- write test-node config ---------
cat > "$TEST_DATADIR/navio.conf" <<EOF
chain=$CHAIN
server=1
debug=bench
dbcache=4096
[$CHAIN_SECTION]
connect=$SOURCE_HOST:$SOURCE_PORT
rpcuser=perf
rpcpassword=perfperfperfperfperfperfperfperf
rpcport=$TEST_RPCPORT
port=$TEST_P2PPORT
EOF

# --------- helpers ---------
configure_for_scenario() {
  local s=$1 flags=""
  case "$s" in
    neither)  flags="--without-gmp --disable-openmp" ;;
    gmp_only) flags="--with-gmp --disable-openmp" ;;
    omp_only) flags="--without-gmp --enable-openmp" ;;
    both)     flags="--with-gmp --enable-openmp" ;;
    *) echo "unknown scenario: $s" >&2; exit 2 ;;
  esac
  ./autogen.sh >/dev/null 2>&1
  ./configure $COMMON_CONFIGURE_FLAGS $flags >/dev/null
}

build_scenario() {
  # libbls/libmcl don't notice when only configure flags change → force rebuild
  make -C src/bls clean >/dev/null 2>&1 || true
  make -C src/bls/mcl clean >/dev/null 2>&1 || true
  make >/dev/null
}

cli() {
  src/navio-cli -datadir="$TEST_DATADIR" "$@"
}

run_one_sync() {
  local name=$1 binary=$2 iter=$3
  rm -rf "$TEST_DATADIR/$CHAIN_SECTION" "$TEST_DATADIR/.lock" 2>/dev/null || true
  "$binary" -datadir="$TEST_DATADIR" -daemon >/dev/null 2>&1
  # let RPC come up
  for _ in $(seq 1 30); do
    cli getblockchaininfo >/dev/null 2>&1 && break
    sleep 1
  done
  # wait until synced (ibd=false and blocks==headers)
  while true; do
    local info blocks headers ibd
    info=$(cli getblockchaininfo 2>/dev/null) || { sleep 2; continue; }
    blocks=$(echo "$info" | grep -oP '"blocks":\s*\K[0-9]+')
    headers=$(echo "$info" | grep -oP '"headers":\s*\K[0-9]+')
    ibd=$(echo "$info" | grep -oP '"initialblockdownload":\s*\K(true|false)')
    if [[ "$ibd" == "false" && -n "$blocks" && "$blocks" -ge "$headers" && "$blocks" -gt 0 ]]; then
      break
    fi
    sleep 3
  done
  cli stop >/dev/null 2>&1
  # wait for shutdown (lockfile gone)
  for _ in $(seq 1 30); do
    [[ ! -e "$TEST_DATADIR/.lock" ]] && break
    sleep 1
  done

  local debug_log="$TEST_DATADIR/$CHAIN_SECTION/debug.log"
  cp "$debug_log" "$RESULTS_DIR/${name}_run${iter}_debug.log"
  grep '\[perf\]' "$RESULTS_DIR/${name}_run${iter}_debug.log" \
    > "$RESULTS_DIR/${name}_run${iter}_perf.txt" || true

  local last avg rate ts secs
  last=$(tail -1 "$RESULTS_DIR/${name}_run${iter}_perf.txt" 2>/dev/null || echo "")
  avg=$(echo "$last" | grep -oP 'us/block_avg=\K[0-9.]+' || echo "n/a")
  rate=$(echo "$last" | grep -oP 'blocks/s=\K[0-9.]+' || echo "n/a")
  ts=$(echo "$last" | grep -oP 'total_blocks=\K[0-9]+' || echo "n/a")
  secs=$(echo "$last" | grep -oP 'total_s=\K[0-9.]+' || echo "n/a")
  echo "$name run$iter: us/blk_avg=$avg blocks/s=$rate total_blocks=$ts total_s=$secs"
}

# --------- main loop ---------
echo "scenarios: $SCENARIOS"
echo "runs/scenario: $RUNS"
echo "source: $SOURCE_HOST:$SOURCE_PORT (chain=$CHAIN)"
echo "results: $RESULTS_DIR"
echo

for s in $SCENARIOS; do
  echo "=== building $s ==="
  configure_for_scenario "$s"
  build_scenario
  cp src/naviod "$RESULTS_DIR/naviod.$s"
  echo "=== running $s ($RUNS iterations) ==="
  for i in $(seq 1 "$RUNS"); do
    run_one_sync "$s" "$RESULTS_DIR/naviod.$s" "$i"
  done
  echo
done

# --------- summary ---------
SUMMARY="$RESULTS_DIR/summary.tsv"
{
  echo -e "scenario\trun\tus_per_block_avg\tblocks_per_sec\ttotal_blocks\ttotal_s"
  for s in $SCENARIOS; do
    for i in $(seq 1 "$RUNS"); do
      f="$RESULTS_DIR/${s}_run${i}_perf.txt"
      [[ -s "$f" ]] || { echo -e "$s\t$i\tNA\tNA\tNA\tNA"; continue; }
      last=$(tail -1 "$f")
      avg=$(echo "$last" | grep -oP 'us/block_avg=\K[0-9.]+')
      rate=$(echo "$last" | grep -oP 'blocks/s=\K[0-9.]+')
      ts=$(echo "$last" | grep -oP 'total_blocks=\K[0-9]+')
      secs=$(echo "$last" | grep -oP 'total_s=\K[0-9.]+')
      echo -e "$s\t$i\t${avg:-NA}\t${rate:-NA}\t${ts:-NA}\t${secs:-NA}"
    done
  done
} > "$SUMMARY"

REPORT="$RESULTS_DIR/summary.txt"
{
  echo "=== run config ==="
  echo "scenarios: $SCENARIOS"
  echo "runs/scenario: $RUNS"
  echo "source: $SOURCE_HOST:$SOURCE_PORT (chain=$CHAIN)"
  echo "host: $(uname -srm) — $(nproc) CPUs"
  echo "date: $(date -Iseconds)"
  echo
  echo "=== summary (also at $SUMMARY) ==="
  column -t -s $'\t' "$SUMMARY"
  echo
  echo "=== means by scenario ==="
  awk -F'\t' '
    NR>1 && $3 != "NA" { sum_us[$1] += $3; sum_rate[$1] += $4; n[$1]++ }
    END {
      printf "%-12s %14s %14s\n", "scenario", "mean_us/block", "mean_blocks/s"
      for (s in n) printf "%-12s %14.2f %14.2f\n", s, sum_us[s]/n[s], sum_rate[s]/n[s]
    }
  ' "$SUMMARY"
  echo
  echo "=== BLSCT verify breakdown (means per call, ms) ==="
  printf "%-12s %12s %12s %12s\n" "scenario" "rangeproof" "aggsig" "wait_async"
  for s in $SCENARIOS; do
    awk -v scenario="$s" -v dir="$RESULTS_DIR" -v runs="$RUNS" '
      BEGIN {
        for (i = 1; i <= runs; i++) {
          f = dir "/" scenario "_run" i "_debug.log"
          while ((getline line < f) > 0) {
            if (match(line, /rangeproof batch \(([0-9]+) proofs\): ([0-9.]+)ms/, m)) {
              rp += m[2]; rn++
            }
            if (match(line, /\[bench\][[:space:]]+- BLSCT aggregate signatures: ([0-9.]+)ms/, m)) {
              ag += m[1]; an++
            }
            if (match(line, /Wait for async BLSCT agg sig verify: ([0-9.]+)ms/, m)) {
              wa += m[1]; wn++
            }
          }
          close(f)
        }
        if (rn) printf "%-12s %12.3f %12.3f %12.3f\n", scenario, rp/rn, (an?ag/an:0), (wn?wa/wn:0)
        else printf "%-12s %12s %12s %12s\n", scenario, "n/a", "n/a", "n/a"
      }
    '
  done
} | tee "$REPORT"
echo
echo "saved report: $REPORT"
