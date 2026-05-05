# mcl backend perf benchmarks

Scripts to compare GMP vs OMP variants of the `mcl` BLS arithmetic backend
on a navio block sync workload, with network factored out (loopback source
node).

## Pre-reqs

**Linux (Debian/Ubuntu):**
```sh
sudo apt install build-essential autoconf automake libtool pkg-config \
                 libgmp-dev libomp-dev
```

**macOS:** install build tools via Homebrew, then build the navio `depends/`
toolchain (gives you libgmp, libomp, boost, sqlite, etc.):
```sh
brew install autoconf automake libtool pkg-config
make -C depends NO_QT=1
```

`run-bench.sh` auto-detects the depends prefix at `depends/$(./depends/config.guess)`
and feeds its `config.site` to `./configure`, so you don't need to set
`CONFIG_SITE` yourself.

## Quick start (fresh machine)

```sh
./contrib/perf/run-bench.sh
```

This will:

1. Check system deps (autotools, gcc/g++, libgmp/libomp headers).
2. Build a bootstrap naviod with all backends enabled.
3. Start a `blsctregtest` source node and generate ~500 BLSCT-rich blocks
   (~3 range proofs/block).
4. Build 4 naviod variants (`neither` / `gmp_only` / `omp_only` / `both`),
   run 3 IBD iterations of each against the source over loopback, parse
   `[perf]` and `[bench]` output from `debug.log`.
5. Print a summary table and BLSCT-verify breakdown.

Results land in `~/navio-perf/results/`.

## Modes

```sh
# default — synthetic blsctregtest load
./contrib/perf/run-bench.sh

# real testnet (needs Tor or a clearnet --addnode)
./contrib/perf/run-bench.sh --mode testnet --addnode testnet.nav.io:18333

# more cycles, more iterations
./contrib/perf/run-bench.sh --cycles 1000 --runs 5

# subset of scenarios
./contrib/perf/run-bench.sh --scenarios "neither gmp_only"

# force rebuild (default reuses existing src/naviod and per-scenario binaries)
./contrib/perf/run-bench.sh --force-build
```

By default, `run-bench.sh` and `bench-mcl-backends.sh` reuse the bootstrap
`src/naviod` and per-scenario binaries (`$RESULTS_DIR/naviod.<scenario>`) if
they exist. Pass `--force-build` to rebuild from scratch — useful after
pulling new code or changing configure flags.

## Pieces

| Script | What it does |
|---|---|
| `run-bench.sh` | End-to-end driver. Use this. |
| `setup-source-blsct-load.sh` | Spin up blsctregtest naviod, mine 101 funding blocks, then loop `sendtoaddress + generate` for N cycles. Leaves naviod running. |
| `setup-source-testnet.sh` | Start a testnet naviod, wait until synced. |
| `bench-mcl-backends.sh` | The benchmark itself. Configures + builds 4 variants, runs N IBD iterations each against an existing source on `127.0.0.1:<PORT>`, emits `summary.tsv` and BLSCT-verify breakdown. |

Each piece works standalone. `run-bench.sh` is the orchestrator.

## What gets measured

For each scenario × iteration:

- **`[perf]` log line** (added in `Chainstate::ConnectTip`): cumulative `us/block_avg` and `blocks/s` after each block. Enabled by `-debug=bench`, filtered by `grep '\[perf\]'`.
- **`[bench]` lines** already in upstream: per-call ms for `BLSCT block rangeproof batch` and `BLSCT aggregate signatures`. The summary aggregates these into per-call means.

The end-of-run summary shows:
- Per-run `us/block_avg`, `blocks/s`, total blocks, total time.
- Per-scenario means.
- Per-scenario BLSCT verify breakdown (rangeproof + aggsig + wait_async).

The summary is printed to stdout and saved to `$RESULTS_DIR/summary.txt`. The
machine-readable per-run rows are also in `$RESULTS_DIR/summary.tsv`.

## Why these scenarios

The four points cover the full GMP × OMP product:

| Scenario | mcl bignum | mcl threading | configure flags |
|---|---|---|---|
| neither | VINT (bundled) | single | `--without-gmp --disable-openmp` |
| gmp_only | GMP | single | `--with-gmp --disable-openmp` |
| omp_only | VINT | OMP MSM | `--without-gmp --enable-openmp` |
| both | GMP | OMP MSM | `--with-gmp --enable-openmp` |

This isolates GMP-vs-VINT and OMP-vs-single-thread independently.

## Notes

- Each scenario forces a clean rebuild of `src/bls` and `src/bls/mcl`
  (libmcl/libbls don't notice when only configure flags change otherwise).
- The test datadir is wiped before every iteration; source datadir is preserved.
- Source node uses default `MCL_USE_GMP=1 MCL_USE_OMP=0` for the bootstrap;
  it doesn't affect what's being measured (only the test node's config matters).
- Loopback `connect=` eliminates network: dnsseed disabled, no listen, single
  manual peer.
