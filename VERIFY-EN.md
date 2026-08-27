# Swap Queue v2 Test — Manual Verification Guide

## 1. Quick Verification (5 commands)

```bash
cd swapq-v2-test

# 1. Clean branch and commit history
git log --oneline
# Expected: 15 commits, first 6 are original, last 9 are our changes

# 2. All 120 samples passed (exit=0, oom=0)
grep -r "build_exit=0" results/arm-*/bench-*/sample-*/result.txt | wc -l
# Expected: 120
grep -r "oom_kill=0" results/arm-*/bench-*/sample-*/result.txt | wc -l
# Expected: 120

# 3. All bench logs are complete
grep -l "complete" bench-*.log | wc -l
# Expected: 10

# 4. Script modifications are correct
grep "defconfig Image modules" scripts/04-run-benchmark.sh
# Expected: output (aarch64 fix)
grep "NO_INSTALL" scripts/01-build-arm.sh
# Expected: output (user-managed build option)

# 5. Kernel config is complete
wc -l configs/base.config
# Expected: 6836
```

## 2. Verify Benchmark Results

### 2.1 Average elapsed time per arm

```bash
# 2g averages
for arm in A B C D E; do
  echo -n "arm-$arm 2g: "
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    grep "Elapsed" results/arm-$arm/bench-2g-*/sample-$i/time.txt | awk '{print $NF}'
  done | awk -F: '{s=$1*60+$2; sum+=s; n++} END {printf "%d:%02d\n", sum/n/60, sum/n%60}'
done
# Expected: A=8:50 B=17:08 C=8:53 D=8:38 E=8:47

# 3g averages
for arm in A B C D E; do
  echo -n "arm-$arm 3g: "
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    grep "Elapsed" results/arm-$arm/bench-3g-*/sample-$i/time.txt | awk '{print $NF}'
  done | awk -F: '{s=$1*60+$2; sum+=s; n++} END {printf "%d:%02d\n", sum/n/60, sum/n%60}'
done
# Expected: A=5:37 B=10:55 C=5:42 D=5:34 E=5:42
```

### 2.2 View a single sample's full data

```bash
# Full time.txt for arm-D 2g sample-01
cat results/arm-D/bench-2g-*/sample-01/time.txt
# Key fields: Elapsed, User time, System time, Major page faults

# result.txt for arm-D 2g sample-01
cat results/arm-D/bench-2g-*/sample-01/result.txt
# Key fields: build_exit=0, oom_kill=0
```

### 2.3 System time comparison

```bash
for arm in A B D E; do
  echo -n "arm-$arm system time: "
  grep "System time" results/arm-$arm/bench-3g-*/sample-01/time.txt | awk '{printf "%.0f\n", $4}'
done
# Expected: A~22532 B~54392 D~22208 E~23204
```

### 2.4 Verify data source (from kp-server)

```bash
# Each result directory contains source.sha256 recording the build workload origin
for arm in A B C D E; do
  echo "arm-$arm 2g: $(cat results/arm-$arm/bench-2g-*/source.sha256)"
  echo "arm-$arm 3g: $(cat results/arm-$arm/bench-3g-*/source.sha256)"
done
# Expected: all point to /root/linux.tar.xz (build workload on kp-server)
```

## 3. Verify Documentation Consistency

### 3.1 CONCLUSIONS.md matches raw data

```bash
# View numbers in CONCLUSIONS.md
grep -E "^\| [A-E]" CONCLUSIONS.md | grep -E "8:|17:|5:"

# Compare with actual data
for arm in A B C D E; do
  echo -n "arm-$arm 2g: "
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    grep "Elapsed" results/arm-$arm/bench-2g-*/sample-$i/time.txt | awk '{print $NF}'
  done | awk -F: '{s=$1*60+$2; sum+=s; n++} END {printf "%d:%02d\n", sum/n/60, sum/n%60}'
done
# Both should match exactly
```

### 3.2 TEST-PLAN.md matches execution record

```bash
# View section 5 of TEST-PLAN.md
grep -A10 "测试执行记录" TEST-PLAN.md

# Confirm each arm has 2g and 3g results
for arm in A B C D E; do
  echo "arm-$arm: 2g=$(ls -d results/arm-$arm/bench-2g-*/sample-*/ | wc -l) samples, 3g=$(ls -d results/arm-$arm/bench-3g-*/sample-*/ | wc -l) samples"
done
# Expected: 12 samples each
```

## 4. Files Per Sample

```bash
ls results/arm-D/bench-2g-*/sample-01/
# Expected: build.log, dmesg.delta, peak-swap.txt, result.txt, time.txt,
#           vmstat.after, vmstat.before, vmstat.delta
```

## 5. Complete Checklist

| Check | Command | Expected |
|-------|---------|----------|
| Clean branch | `git status` | No untracked files |
| Commit count | `git log --oneline \| wc -l` | 15 |
| Bench logs | `ls bench-*.log \| wc -l` | 10 |
| Arm directories | `ls -d results/arm-* \| wc -l` | 5 |
| 2g samples per arm | `ls results/arm-A/bench-2g-*/sample-*/ \| wc -l` | 12 |
| 3g samples per arm | `ls results/arm-A/bench-3g-*/sample-*/ \| wc -l` | 12 |
| Total exit=0 | `grep -r "build_exit=0" results/ \| wc -l` | 120 |
| Total oom=0 | `grep -r "oom_kill=0" results/ \| wc -l` | 120 |
| Total complete | `grep -l "complete" bench-*.log \| wc -l` | 10 |
| Config lines | `wc -l configs/base.config` | 6836 |
| Script count | `ls scripts/ \| wc -l` | 11 |
| Patch count | `ls patches-v1/ \| wc -l` | 13 |
| Doc count | `ls *.md \| wc -l` | 7 |