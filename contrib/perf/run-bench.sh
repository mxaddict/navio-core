#!/usr/bin/env bash
# End-to-end driver: dep check → build a bootstrap naviod → start a source node
# → run the 4-scenario benchmark against it → print summary.
#
# Suitable for a fresh machine. Default mode builds a synthetic blsctregtest
# load source and benchmarks against it.
#
# Modes:
#   blsct       (default) build blsctregtest source with BLSCT-rich blocks
#   testnet     start a testnet source and wait for it to sync from network
#
# Usage:
#   ./contrib/perf/run-bench.sh
#   ./contrib/perf/run-bench.sh --mode testnet --addnode testnet.nav.io:18333
#   ./contrib/perf/run-bench.sh --runs 5 --cycles 1000

set -euo pipefail

MODE=blsct
RUNS=3
CYCLES=500
ADDNODE=""
USE_TOR=0
SCENARIOS="neither gmp_only omp_only both"
RESULTS_DIR="${HOME}/navio-perf/results"
FORCE_BUILD=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode) MODE=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --cycles) CYCLES=$2; shift 2 ;;
    --addnode) ADDNODE=$2; shift 2 ;;
    --use-tor) USE_TOR=1; shift ;;
    --scenarios) SCENARIOS=$2; shift 2 ;;
    --results-dir) RESULTS_DIR=$2; shift 2 ;;
    --force-build) FORCE_BUILD=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# --------- system dep check ---------
echo "=== system dep check ==="
missing=()
for cmd in autoconf automake libtoolize make gcc g++ pkg-config; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
# headers / pkgconf — avoid hard-failing if not strictly needed
if ! pkg-config --exists gmp 2>/dev/null && ! [[ -f /usr/include/gmp.h ]]; then
  echo "  warning: libgmp dev headers not found — gmp_only/both scenarios will fail to build"
fi
if ! [[ -f /usr/include/omp.h || -f /usr/lib/llvm*/include/omp.h ]] && ! pkg-config --exists openmp 2>/dev/null; then
  echo "  warning: omp.h not found — omp_only/both scenarios may fail to build"
fi
if (( ${#missing[@]} )); then
  echo "  missing required tools: ${missing[*]}" >&2
  exit 2
fi
echo "  ok"
echo

# --------- bootstrap naviod (build with all backends so we can use it for source setup) ---------
if [[ -x src/naviod && "$FORCE_BUILD" != "1" ]]; then
  echo "=== reusing existing src/naviod (use --force-build to rebuild) ==="
else
  echo "=== bootstrap build (with all backends, for source-node setup) ==="
  ./autogen.sh >/dev/null 2>&1
  ./configure --disable-bench --disable-tests --disable-fuzz --disable-fuzz-binary --without-gui \
              --with-gmp --enable-openmp >/dev/null
  make -C src/bls clean >/dev/null 2>&1 || true
  make -C src/bls/mcl clean >/dev/null 2>&1 || true
  make >/dev/null
  echo "  ok ($(stat -c%s src/naviod) bytes)"
fi
echo

# --------- start source node ---------
case "$MODE" in
  blsct)
    SOURCE_PORT=18444
    echo "=== building blsctregtest source ($CYCLES BLSCT spend cycles) ==="
    "$REPO_ROOT/contrib/perf/setup-source-blsct-load.sh" --cycles "$CYCLES" --p2p-port "$SOURCE_PORT"
    BENCH_CHAIN=blsctregtest
    ;;
  testnet)
    SOURCE_PORT=18333
    echo "=== starting and syncing testnet source ==="
    args=( --p2p-port "$SOURCE_PORT" )
    [[ -n "$ADDNODE" ]] && args+=( --addnode "$ADDNODE" )
    (( USE_TOR )) && args+=( --use-tor )
    "$REPO_ROOT/contrib/perf/setup-source-testnet.sh" "${args[@]}"
    BENCH_CHAIN=test
    ;;
  *)
    echo "unknown mode: $MODE" >&2; exit 2 ;;
esac
echo

# --------- run the benchmark ---------
echo "=== running $RUNS iterations × ${SCENARIOS} ==="
bench_args=(
  --source-port "$SOURCE_PORT"
  --chain "$BENCH_CHAIN"
  --runs "$RUNS"
  --scenarios "$SCENARIOS"
  --results-dir "$RESULTS_DIR"
)
(( FORCE_BUILD )) && bench_args+=( --force-build )
"$REPO_ROOT/contrib/perf/bench-mcl-backends.sh" "${bench_args[@]}"

echo
echo "results dir: $RESULTS_DIR"
echo "  summary.tsv  — per-run table"
echo "  *_perf.txt   — [perf] log line per scenario × run"
echo "  *_debug.log  — full debug.log per scenario × run"
