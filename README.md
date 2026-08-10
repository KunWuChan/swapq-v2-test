# Swap Priority Queue v2 — Test Infrastructure

Testing Lian Wang's swap priority queue v2 patch series on kp-server.

## Quick Start

```sh
# 1. Verify environment (no build needed)
ssh root@kp-server
cd /home/chentao/swapq-v2-test
bash scripts/99-verify-env.sh

# 2. Apply patches (with manual fixup for rejects)
bash scripts/00-apply-patches.sh

# 3. Copy kernel config
cp /boot/config-$(uname -r) configs/base.config
# Or: zcat /proc/config.gz > configs/base.config

# 4. Build both arms
bash scripts/01-build-arm.sh D   # base (mm-unstable)
bash scripts/01-build-arm.sh E   # v2 (13 patches)

# 5. Test Arm E
bash scripts/02-switch-kernel.sh E
# ... after reboot ...
bash scripts/03-run-functional.sh
bash scripts/04-run-benchmark.sh 2g

# 6. Test Arm D (baseline)
bash scripts/02-switch-kernel.sh D
# ... after reboot ...
bash scripts/04-run-benchmark.sh 2g

# 7. Collect results
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
│   ├── 01-build-arm.sh        # Build a kernel for ARM D or E
│   ├── 02-switch-kernel.sh    # Reboot into specified kernel
│   ├── 03-run-functional.sh   # Functional correctness tests
│   ├── 04-run-benchmark.sh    # Performance benchmarks
│   ├── 05-collect-results.sh  # Summarize and compare results
│   └── 99-verify-env.sh       # Pre-flight env check
├── results/               # All test outputs
└── README.md
```

## ARM Reference

| Arm | Branch | Description |
|-----|--------|-------------|
| D | swapq-v2-base | mm-unstable current HEAD (baseline, no patches) |
| E | swapq-v2 | D + 13 swap priority queue v2 patches |

## Benchmark Workloads

| Workload | Description | Approx Time (kp-server) |
|----------|-------------|------------------------|
| 2g | kernel build, make -j96, 2 GiB memcg, 8 ZRAM × 12 reps | ~2-3 hours |
| 3g | kernel build, make -j96, 3 GiB memcg, 8 ZRAM × 12 reps | ~1-2 hours |
| brd | 12 brd devices, usemem -n 32 160M | ~10 minutes |

Use `--quick` flag to run only warm-up (no measured reps).

## Base Commit Issue

The v2 patches are based on `94f9b3980dd4` which is no longer referenced
by any branch on kernel.org (mm-unstable is rebased). Therefore we apply
the patches with `patch -F5` (fuzz factor) to kp-server's current tree.

Patches 1-3 apply cleanly (line offsets only). Patches 4-13 may have
rejects that need manual fixup. `00-apply-patches.sh` handles the process
interactively — it stops at each failing patch and asks you to fix and
commit before continuing.

## Review Focus (per Lian's request)

1. Same-priority as queue/ring definition
2. Task-local cursor + migrate_disable() boundary
3. Queue publication, tag updates, swapoff lifetime ordering
4. Exactly-once same-ring retry + large folio semantics
5. Synchronous discard bound for allocation latency
6. A/B/C/D/E + real multi-SSD validation plan
