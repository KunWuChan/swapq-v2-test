# Swap Priority Queue v2 — Test Infrastructure

Test infrastructure and benchmark results for Lian Wang's swap priority queue
v2 patch series, executed on a Kunpeng 920 server (256 cores, 249 GiB RAM,
aarch64).

## Overview

This repository validates the 13-patch swap priority queue v2 series by
comparing 5 kernel builds (arms A-E) under controlled memory pressure.

### Why A/B/C/D/E?

```
v1 family (rc2):              v2 family (rc5):
A: 0 patches (baseline)       D: 0 patches (baseline)
  | +8 patches                  | +13 patches
  v                             v
B: patches 1-8                E: full v2 (patches 1-13)
  | +5 patches
  v
C: patches 1-13 (full v1)

Comparison rules:
  A -> C: v1 patch attribution (does adding all 13 patches regress?)
  D -> E: v2 patch attribution (does adding all 13 patches regress?)
  B:      intermediate state — verifies patch 8 needs patch 9
  A vs D: different kernel versions (rc2 vs rc5), not a patch attribution
```

- **A/C** and **D/E** are the two primary comparison pairs for performance
  attribution.
- **B** is an intermediate checkpoint: patches 1-8 without patch 9. The
  per-device percpu cluster (patch 8) conflicts with the old plist allocation
  when patch 9 (priority queue) is absent, causing 2.4x higher system time.
  C (which has all 13 patches) runs normally, confirming the patches must be
  used together.
- Functional and stress tests run only on **Arm E** (the full v2 patch set).

### What Each Arm Tested

| Arm | Functional (5 tests) | Stress (600s) | 2g benchmark | 3g benchmark |
|-----|:--------------------:|:-------------:|:------------:|:------------:|
| A | — | — | 12 samples | 12 samples |
| B | — | — | 12 samples | 12 samples |
| C | — | — | 12 samples | 12 samples |
| D | — | — | 12 samples | 12 samples |
| E | 5/5 PASS | PASS | 12 samples | 12 samples |

**Workload**: kernel build under memory cgroup (`make -j96 defconfig Image
modules`), 2 GiB / 3 GiB memcg, 8 ZRAM devices, 1 warm-up + 12 measured
samples per arm per workload.

## Benchmark Results Summary

| Arm | Description | 2g avg | 3g avg | Conclusion |
|-----|-------------|:------:|:------:|------------|
| A | v1 base (rc2, 0 patches) | 8:50 | 5:37 | Baseline |
| B | v1+8p (per-device cluster) | 17:08 | 10:55 | Intermediate state |
| C | v1+13p (full v1) | 8:53 | 5:42 | Normal |
| D | v2 base (rc5, 0 patches) | 8:38 | 5:34 | Baseline |
| E | v2+13p (full v2) | 8:47 | 5:42 | Normal |

**Key finding**: A / C / D / E are all within 3% (2g: 2.9%, 3g: 2.4%) —
the 13 patches introduce **no performance regression**. See
[CONCLUSIONS.md](CONCLUSIONS.md) for full details (English and Chinese).

### System Time (3g sample-01)

| Arm | User time | System time | Sys/User |
|-----|:---------:|:-----------:|:--------:|
| A | 6771s | 22532s | 3.3x |
| B | 6628s | 54392s | 8.2x |
| D | 6824s | 22208s | 3.3x |
| E | 6854s | 23204s | 3.4x |

### Key Findings

1. **No performance regression**: A, C, D, E are all within 3% (2g: 2.9%,
   3g: 2.4%). The 13 swap priority queue v2 patches introduce no measurable
   overhead on either baseline.

2. **B is an intermediate state**: B has patches 1-8 (per-device percpu
   cluster) but lacks patch 9 (priority queue). The per-device cluster
   conflicts with the old plist-based allocation, causing 2.4x higher system
   time (54392s vs ~22000s) while user time is similar (6628s vs ~6800s).
   C (which has all 13 patches) runs normally, confirming patch 8 must be
   used together with patch 9.

3. **Functional correctness**: All 5 KMB tests passed on Arm E. 600s stress
   test passed. dmesg clean throughout.

4. **v1/v2 baselines equivalent**: A (rc2) vs D (rc5) differ by 2.3% (2g),
   confirming kernel changes between rc2 and rc5 do not affect swap
   performance.

## Directory Structure

```
swapq-v2-test/
├── scripts/                    # All test scripts (see below)
│   ├── lib-common.sh           #   Shared functions (detect arm, init zram)
│   ├── 00-apply-patches.sh     #   Apply 13 patches to kp-server tree
│   ├── 01-build-arm.sh         #   Build a kernel for a specific arm
│   ├── 02-switch-kernel.sh     #   Reboot into specified kernel
│   ├── 03-run-functional.sh    #   5 functional correctness tests
│   ├── 04-run-benchmark.sh     #   Performance benchmarks (2g/3g/brd)
│   ├── 05-collect-results.sh   #   Summarize and compare results
│   ├── 06-run-stress.sh        #   CPU migration + ring mutation stress
│   ├── 07-run-multissd.sh      #   Destructive real multi-SSD test
│   ├── 99-verify-env.sh        #   Pre-flight environment check
│   └── extract_patches.py      #   Extract patches from email
├── patches-v1/                 # Original v1 13-patch stack (A -> B -> C)
├── patches/                    # Reviewed v2 13-patch stack (D -> E)
├── bundles/                    # Git bundle for offline Arm D reproduction
├── configs/
│   └── base.config             # Kernel config (6836 lines, from /proc/config.gz)
├── results/                    # All benchmark outputs (5 arms × 2 workloads)
│   ├── arm-A/bench-2g-*/ bench-3g-*/
│   ├── arm-B/bench-2g-*/ bench-3g-*/
│   ├── arm-C/bench-2g-*/ bench-3g-*/
│   ├── arm-D/bench-2g-*/ bench-3g-*/
│   └── arm-E/bench-2g-*/ bench-3g-*/
├── bench-{2g,3g}-{A,B,C,D,E}.log  # Benchmark run logs (stdout from nohup)
├── BRANCH-COMMITS.md           # Branch commit reference with relationship diagram
├── CONCLUSIONS.md              # Test conclusions (English + Chinese)
├── TEST-PLAN.md                # Test plan and execution record
├── VERIFY.md                   # Manual verification guide (Chinese)
├── VERIFY-EN.md                # Manual verification guide (English)
├── ARTIFACTS.sha256            # SHA-256 checksums for bundles and patches
└── README.md
```

## ARM Reference

| Arm | Branch | Commit | Patches | Kernel | Description |
|-----|--------|--------|:-------:|:------:|-------------|
| A | swapq-v1-before | `bdc38bfc126` | 0 | rc2 | v1 baseline |
| B | swapq-v1-patch8 | `5d5c0f6c4e6` | 8 | rc2 | v1 through patch 8 |
| C | swapq-v1-patch13 | `9854da38189` | 13 | rc2 | v1 through patch 13 |
| D | swapq-v2-base | `94f9b3980dd` | 0 | rc5 | v2 baseline |
| E | swapq-v2 | `aa162bca0b4` | 13 | rc5 | v2 through patch 13 |

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

## Manual Verification

See [VERIFY.md](VERIFY.md) (Chinese) or [VERIFY-EN.md](VERIFY-EN.md) (English)
for a step-by-step verification guide covering:

- Branch and commit history
- 120 sample exit codes and OOM status
- Average elapsed times per arm
- System time comparison
- Documentation consistency

Quick check:
```sh
grep -r "build_exit=0" results/arm-*/bench-*/sample-*/result.txt | wc -l  # 120
grep -r "oom_kill=0" results/arm-*/bench-*/sample-*/result.txt | wc -l    # 120
grep -l "complete" bench-*.log | wc -l                                    # 10
```

## Benchmark Workloads

| Workload | Description |
|----------|-------------|
| 2g | Kernel build, make -j96, 2 GiB memcg, 8 ZRAM |
| 3g | Kernel build, make -j96, 3 GiB memcg, 8 ZRAM |
| brd | 12 brd devices, explicit usemem size (requires usemem) |

Use `--quick` flag to run only warm-up (no measured reps).

Every build sample is valid only when `build_exit=0`, `oom_kill=0`, pswpout
increases, and dmesg delta is clean.

## Offline Reproduction

The kernel repository needs the existing Arm A commit. Everything else is
self-contained in this repository:

- `patches-v1/` rebuilds B and C from A;
- `bundles/swapq-v2-base-from-v1-base.bundle` supplies D if kernel.org no
  longer advertises `94f9b3980dd4`;
- `patches/` rebuilds E from D.

Verify artifacts:
```sh
sha256sum -c ARTIFACTS.sha256
```

## Review Focus (per Lian's request)

1. Same-priority as queue/ring definition
2. Task-local cursor + migrate_disable() boundary
3. Queue publication, tag updates, swapoff lifetime ordering
4. Exactly-once same-ring retry + large folio semantics
5. Synchronous discard bound for allocation latency
6. A/B/C/D/E + real multi-SSD validation plan
