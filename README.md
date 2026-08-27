# Swap Priority Queue v2 — Test Infrastructure

Test infrastructure and benchmark results for Lian Wang's swap priority queue
v2 patch series, executed on a Kunpeng 920 server (256 cores, 249 GiB RAM,
aarch64, Kylin OS).

## Benchmark Results Summary

| Arm | Description | 2g avg | 3g avg | Conclusion |
|-----|-------------|:------:|:------:|------------|
| A | v1 base (rc2, 0 patches) | 8:50 | 5:37 | Baseline |
| B | v1+8p (per-device cluster) | 17:08 | 10:55 | Intermediate state |
| C | v1+13p (full v1) | 8:53 | 5:42 | Normal |
| D | v2 base (rc5, 0 patches) | 8:38 | 5:34 | Baseline |
| E | v2+13p (full v2) | 8:47 | 5:42 | Normal |

**Key finding**: A/C/D/E are all within 3% — the 13 patches introduce **no
performance regression**. See [CONCLUSIONS.md](CONCLUSIONS.md) for full details
(Chinese and English).

## Quick Start

```sh
# 1. Verify environment (no build needed)
ssh root@kp-server
cd /home/chentao/swapq-v2-test
ALLOW_NON_KP_HOST=1 bash scripts/99-verify-env.sh

# 2. Build and switch to target kernel (manual, one-time per arm)
cd /home/chentao/swapq-E/src
SWAPQ_ARM=E ./make.sh
# reboot into the new kernel

# 3. Run functional tests (Arm E only)
cd /home/chentao/swapq-v2-test
ALLOW_NON_KP_HOST=1 bash scripts/03-run-functional.sh

# 4. Run benchmarks (any arm, use nohup for long runs)
swapoff -a; modprobe -r zram 2>/dev/null; sleep 1
nohup env ALLOW_NON_KP_HOST=1 bash scripts/04-run-benchmark.sh 2g > bench-2g-E.log 2>&1 &

# 5. Collect results
ALLOW_NON_KP_HOST=1 bash scripts/05-collect-results.sh --compare
```

## Directory Structure

```
swapq-v2-test/
├── patches-v1/            # original v1 13-patch stack (A -> B -> C)
├── patches/               # reviewed v2 13-patch stack (D -> E)
│   ├── 0001-*.patch
│   ├── 0002-*.patch
│   ├── ...
│   └── 0013-*.patch
├── bundles/
│   └── swapq-v2-base-from-v1-base.bundle # exact Arm D incremental objects
├── ARTIFACTS.sha256       # bundle and both patch stacks
├── configs/               # Kernel build configs
│   └── base.config        # Copy from /boot/config-$(uname -r)
├── scripts/
│   ├── lib-common.sh      # Shared functions
│   ├── 00-apply-patches.sh    # Apply 13 patches to kp-server tree
│   ├── 01-build-arm.sh        # Build an exact A-E kernel
│   ├── 02-switch-kernel.sh    # Reboot into specified kernel
│   ├── 03-run-functional.sh   # Functional correctness tests
│   ├── 04-run-benchmark.sh    # Performance benchmarks
│   ├── 05-collect-results.sh  # Summarize and compare results
│   ├── 06-run-stress.sh       # CPU migration + ring mutation stress
│   ├── 07-run-multissd.sh     # destructive, gated real multi-SSD test
│   │   └── 99-verify-env.sh       # Pre-flight env check
├── results/               # All benchmark outputs (5 arms × 2 workloads × 13 samples)
│   ├── arm-A/bench-2g-*/ bench-3g-*/
│   ├── arm-B/bench-2g-*/ bench-3g-*/
│   ├── arm-C/bench-2g-*/ bench-3g-*/
│   ├── arm-D/bench-2g-*/ bench-3g-*/
│   └── arm-E/bench-2g-*/ bench-3g-*/
├── bench-*.log            # Benchmark run logs (stdout)
├── configs/               # Kernel build configs
│   └── base.config        # 6836 lines, from /proc/config.gz
├── CONCLUSIONS.md         # Test conclusions (English + Chinese)
└── README.md
```

## ARM Reference

| Arm | Branch | Commit | Description |
|-----|--------|--------|-------------|
| A | swapq-v1-before | `bdc38bfc126` | v1 baseline (rc2, 0 patches) |
| B | swapq-v1-patch8 | `5d5c0f6c4e6` | v1 through patch 8 |
| C | swapq-v1-patch13 | `9854da38189` | v1 through patch 13 |
| D | swapq-v2-base | `94f9b3980dd` | v2 baseline (rc5, 0 patches) |
| E | swapq-v2 | `aa162bca0b4` | v2 through patch 13 |

## Benchmark Workloads

| Workload | Description | Approx Time (kp-server) |
|----------|-------------|------------------------|
| 2g | fixed-source kernel build, make -j96, 2 GiB memcg, 8 ZRAM × 12 reps | host dependent |
| 3g | fixed-source kernel build, make -j96, 3 GiB memcg, 8 ZRAM × 12 reps | host dependent |
| brd | 12 brd devices, explicit usemem size | host dependent |

Use `--quick` flag to run only warm-up (no measured reps).

Every build sample is valid only when the build exits zero, `oom_kill` is zero,
`pswpout` increases, and the dmesg delta is clean.  The collector excludes any
sample that does not meet all four gates.

`KERNEL_SRC_ARCHIVE` must point to one fixed source archive for every arm.
Optionally set `KERNEL_SRC_SHA256` to make the script verify it.  ZRAM defaults
to eight devices of 8 GiB each (`ZRAM_DEVICE_SIZE=8G`), for 64 GiB total logical
swap.  Archives with a top-level source directory use the default
`KERNEL_ARCHIVE_STRIP_COMPONENTS=1`; set it to `0` only for a flat archive.

Kernel-under-test builds use independent output directories under
`BUILD_ROOT` (default `/home/chentao/swapq-build/arm-{A..E}`).  Objects,
generated headers and `.config` are never shared between arms.  The build
script refuses tracked source changes, less than 20 GiB free in the build
filesystem, or less than 1 GiB free on `/boot`; override the thresholds only
after checking the server with `MIN_BUILD_FREE_GIB` and `MIN_BOOT_FREE_MIB`.

BRD has no implicit scaled default.  Set both sizes explicitly, for example:

```sh
BRD_DEVICE_SIZE_MIB=4096 BRD_PER_THREAD_MIB=1536 \
  bash scripts/04-run-benchmark.sh brd
```

The original 1536 MiB × 32 workload plus twelve memory-backed block devices
requires a sufficiently large server.  Smaller values are synthetic scaled
tests and must be labelled as such.

## Offline Reproduction and Exact Bases

The colleague's kernel repository needs the existing Arm A commit and its
history.  Everything else needed to reproduce the matrix is checked into this
repository:

- `patches-v1/` rebuilds B after patch 8 and C after patch 13;
- `bundles/swapq-v2-base-from-v1-base.bundle` supplies D if the rebased
  kernel.org repository no longer advertises `94f9b3980dd4`;
- `patches/` rebuilds E from D.

The D bundle is a 3.5 MiB incremental Git bundle whose prerequisites are
reachable from the exact A history.  `00-apply-patches.sh` verifies its
SHA-256 and Git prerequisites before importing it.  It then checks exact base
commits, exact source trees, patch counts and `git diff --check`.  No network
fetch, moving-base substitution, fuzzy application or manual fixup is allowed.

To inspect the artifacts independently:

```sh
sha256sum -c ARTIFACTS.sha256
git -C /home/chentao/mm bundle verify \
  "$PWD/bundles/swapq-v2-base-from-v1-base.bundle"
```

## CPU Migration and Ring Mutation

Run this on Arm E after functional testing:

```sh
bash scripts/06-run-stress.sh             # 10 minutes by default
bash scripts/06-run-stress.sh --quick     # 30-second plumbing check
```

The test holds several memory-pressure workers in a cgroup, repeatedly moves
them across online CPUs with `taskset`, and concurrently inserts/removes a
fifth zram device at the same priority.  It requires live workers, successful
CPU moves and ring mutations, swap-out activity, use of at least two base
devices, and a clean dmesg delta.  This is a correctness/stability gate and
must not be presented as a performance result.

## Real Multi-SSD Test

ZRAM, BRD, loop, device-mapper, and partitions from one physical SSD cannot
establish real multi-SSD behavior.  Use at least two unmounted targets on
distinct parent disks.  The script deliberately has no default devices and
requires both an absolute workload script and an explicit destructive flag:

```sh
SWAP_DEVICES='/dev/nvme1n1p1 /dev/nvme2n1p1' \
  bash scripts/07-run-multissd.sh \
  --workload-script /root/run-swap-pressure.sh \
  --confirm-destructive
```

It refuses mounted or active-swap targets, duplicate devices, the root disk,
targets sharing one parent disk, or targets without distinct serial/sysfs
physical identities.  It records topology, swap usage,
diskstats, vmstat, workload timing and dmesg.  All listed targets must receive
swap traffic.  **It writes swap signatures and cannot restore previous device
contents or signatures**, so only dedicated test partitions may be supplied.

## Coverage Boundary

The functional script checks basic same-priority use, priority isolation,
swapon/swapoff concurrency, full/peer behavior, observed THP swap counters,
and dmesg.  CPU migration and concurrent ring mutation are covered separately
by `06-run-stress.sh`.  ZRAM and BRD results do not constitute real multi-SSD
evidence; hardware claims require the gated `07-run-multissd.sh` result from at
least two independent SSD/NVMe parent devices.

## Review Focus (per Lian's request)

1. Same-priority as queue/ring definition
2. Task-local cursor + migrate_disable() boundary
3. Queue publication, tag updates, swapoff lifetime ordering
4. Exactly-once same-ring retry + large folio semantics
5. Synchronous discard bound for allocation latency
6. A/B/C/D/E + real multi-SSD validation plan
