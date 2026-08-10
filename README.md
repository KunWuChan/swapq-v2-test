# Swap Priority Queue v2 — Test Infrastructure

Server-side validation for the swap priority queue v2 patch series.

This repository is not the VM/KMB result archive.  It prepares the existing
v1 checkpoints (Arms A-C), the exact v2 base (Arm D), and the reviewed v2
source tree (Arm E) for real-server validation on `kp-server`.

## Quick Start

```sh
# 1. Verify environment (no build needed)
ssh root@kp-server
cd /home/chentao/swapq-v2-test
KERNEL_SRC=/home/chentao/mm bash scripts/99-verify-env.sh

# 2. Create exact A-E branches.  The v1 objects must already be present;
#    this script performs no download.  Fuzzy application is prohibited.
KERNEL_SRC=/home/chentao/mm bash scripts/00-apply-patches.sh

# 3. Copy kernel config
mkdir -p configs results
cp /boot/config-$(uname -r) configs/base.config
# Or: zcat /proc/config.gz > configs/base.config

# 4. Build the required arms (use the same config for every arm)
for arm in A B C D E; do bash scripts/01-build-arm.sh "$arm"; done

# 5. Test Arm E
GRUB_ENTRY='<verified submenu>entry id>' bash scripts/02-switch-kernel.sh E
# Verify the one-shot entry, then request the reboot explicitly:
GRUB_ENTRY='<verified submenu>entry id>' bash scripts/02-switch-kernel.sh E --reboot
# ... after reboot ...
bash scripts/03-run-functional.sh
bash scripts/04-run-benchmark.sh 2g

# 6. Test Arm D (baseline)
bash scripts/02-switch-kernel.sh D
# ... after reboot ...
bash scripts/04-run-benchmark.sh 2g

# 7. Collect results.  A/B/C and D/E are reported as separate families.
bash scripts/05-collect-results.sh --compare
```

## Directory Structure

```
swapq-v2-test/
├── patches/               # 13 kernel patches extracted from swap.txt
│   ├── 0001-*.patch
│   ├── 0002-*.patch
│   ├── ...
│   └── 0013-*.patch
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
│   └── 99-verify-env.sh       # Pre-flight env check
├── results/               # All test outputs
└── README.md
```

## ARM Reference

| Arm | Branch | Description |
|-----|--------|-------------|
| A | swapq-v1-before | v1 parent `bdc38bfc1262` |
| B | swapq-v1-patch8 | v1 through patch 8 `4a7d8bd1b664` |
| C | swapq-v1-patch13 | complete v1 `a438694aa41a` |
| D | swapq-v2-base | exact v2 base `94f9b3980dd4` |
| E | swapq-v2 | D + 13 swap priority queue v2 patches |

Arm E must have Git tree
`e41508faa11f60c1d4cf73051a0a9e38534352d5`, matching reviewed v2 tip
`d5c8964cf19f`.  Commit IDs created by `git am` may differ because the local
committer date differs; the source tree and preserved patch authors/trailers
are the comparison identity.

A/B/C form the v1 progression.  D/E form the clean v2 attribution pair.
Because the v1 and v2 base histories differ, an A/C versus D/E comparison may
be useful context but is not a patch-only performance attribution.

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

BRD has no implicit scaled default.  Set both sizes explicitly, for example:

```sh
BRD_DEVICE_SIZE_MIB=4096 BRD_PER_THREAD_MIB=1536 \
  bash scripts/04-run-benchmark.sh brd
```

The original 1536 MiB × 32 workload plus twelve memory-backed block devices
requires a sufficiently large server.  Smaller values are synthetic scaled
tests and must be labelled as such.

## Exact Base Requirement

The v1 checkpoints and v2 base are fixed by the commit IDs in the table.  The
colleague's kernel repository is expected to contain those objects already;
the scripts do not fetch or download them.  The v2 patches are based on
`94f9b3980dd4`, even if rebased mm-unstable no longer has a branch pointing at
it.  Import the exact objects into the local repository first.
`00-apply-patches.sh` refuses a moving base, a dirty tree, a fuzzy/manual
application, an incomplete patch count, or a mismatched final source tree.

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
