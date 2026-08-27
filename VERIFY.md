# Swap Queue v2 Test — 手动验证指南

## 一、快速验证（5 条命令）

```bash
cd swapq-v2-test

# 1. 分支和提交干净
git log --oneline
# 预期: 15 个提交，前 6 个是原版，后 9 个是我们的改动

# 2. 所有 120 个 sample 都通过（exit=0, oom=0）
grep -r "build_exit=0" results/arm-*/bench-*/sample-*/result.txt | wc -l
# 预期: 120
grep -r "oom_kill=0" results/arm-*/bench-*/sample-*/result.txt | wc -l
# 预期: 120

# 3. 所有 bench 日志都完整
grep -l "complete" bench-*.log | wc -l
# 预期: 10

# 4. 脚本修改正确
grep "defconfig Image modules" scripts/04-run-benchmark.sh
# 预期: 有输出（aarch64 修复）
grep "NO_INSTALL" scripts/01-build-arm.sh
# 预期: 有输出（用户手动构建选项）

# 5. 配置完整
wc -l configs/base.config
# 预期: 6836
```

## 二、验证测试结果数据

### 2.1 查看平均耗时

```bash
# 2g 每个臂的平均值
for arm in A B C D E; do
  echo -n "arm-$arm 2g: "
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    grep "Elapsed" results/arm-$arm/bench-2g-*/sample-$i/time.txt | awk '{print $NF}'
  done | awk -F: '{s=$1*60+$2; sum+=s; n++} END {printf "%d:%02d\n", sum/n/60, sum/n%60}'
done
# 预期: A=8:50 B=17:08 C=8:53 D=8:38 E=8:47

# 3g 每个臂的平均值
for arm in A B C D E; do
  echo -n "arm-$arm 3g: "
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    grep "Elapsed" results/arm-$arm/bench-3g-*/sample-$i/time.txt | awk '{print $NF}'
  done | awk -F: '{s=$1*60+$2; sum+=s; n++} END {printf "%d:%02d\n", sum/n/60, sum/n%60}'
done
# 预期: A=5:37 B=10:55 C=5:42 D=5:34 E=5:42
```

### 2.2 查看单个 sample 的完整数据

```bash
# 查看 arm-D 2g sample-01 的完整 time.txt
cat results/arm-D/bench-2g-*/sample-01/time.txt
# 关注: Elapsed, User time, System time, Major page faults

# 查看 arm-D 2g sample-01 的 result.txt
cat results/arm-D/bench-2g-*/sample-01/result.txt
# 关注: build_exit=0, oom_kill=0
```

### 2.3 查看 system time 对比

```bash
for arm in A B D E; do
  echo -n "arm-$arm system time: "
  grep "System time" results/arm-$arm/bench-3g-*/sample-01/time.txt | awk '{printf "%.0f\n", $4}'
done
# 预期: A~22532 B~54392 D~22208 E~23204
```

### 2.4 验证数据来源（来自 kp-server）

```bash
# 每个结果目录都有 source.sha256，记录编译负载的来源
for arm in A B C D E; do
  echo "arm-$arm 2g: $(cat results/arm-$arm/bench-2g-*/source.sha256)"
  echo "arm-$arm 3g: $(cat results/arm-$arm/bench-3g-*/source.sha256)"
done
# 预期: 全部指向 /root/linux.tar.xz（kp-server 上的编译负载）
```

## 三、验证文档一致性

### 3.1 CONCLUSIONS.md 与原始数据一致

```bash
# 查看 CONCLUSIONS.md 中的数字
grep -E "^\| [A-E]" CONCLUSIONS.md | grep -E "8:|17:|5:" 

# 对比实际数据
for arm in A B C D E; do
  echo -n "arm-$arm 2g: "
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    grep "Elapsed" results/arm-$arm/bench-2g-*/sample-$i/time.txt | awk '{print $NF}'
  done | awk -F: '{s=$1*60+$2; sum+=s; n++} END {printf "%d:%02d\n", sum/n/60, sum/n%60}'
done
# 两者应该完全一致
```

### 3.2 TEST-PLAN.md 与执行记录一致

```bash
# 查看 TEST-PLAN.md 第五节的执行记录
grep -A10 "测试执行记录" TEST-PLAN.md

# 确认每个臂都有 2g 和 3g 结果
for arm in A B C D E; do
  echo "arm-$arm: 2g=$(ls -d results/arm-$arm/bench-2g-*/sample-*/ | wc -l) samples, 3g=$(ls -d results/arm-$arm/bench-3g-*/sample-*/ | wc -l) samples"
done
# 预期: 每个都是 12 个 sample
```

## 四、每个 sample 包含的文件

```bash
ls results/arm-D/bench-2g-*/sample-01/
# 预期: build.log, dmesg.delta, peak-swap.txt, result.txt, time.txt,
#        vmstat.after, vmstat.before, vmstat.delta
```

## 五、ABC 关系检查清单

| 检查项 | 命令 | 预期 |
|--------|------|------|
| 分支干净 | `git status` | 无未跟踪文件 |
| 提交数 | `git log --oneline \| wc -l` | 15 |
| bench 日志 | `ls bench-*.log \| wc -l` | 10 |
| 臂目录 | `ls -d results/arm-* \| wc -l` | 5 |
| 每臂 2g samples | `ls results/arm-A/bench-2g-*/sample-*/ \| wc -l` | 12 |
| 每臂 3g samples | `ls results/arm-A/bench-3g-*/sample-*/ \| wc -l` | 12 |
| exit=0 总数 | `grep -r "build_exit=0" results/ \| wc -l` | 120 |
| oom=0 总数 | `grep -r "oom_kill=0" results/ \| wc -l` | 120 |
| complete 总数 | `grep -l "complete" bench-*.log \| wc -l` | 10 |
| 配置行数 | `wc -l configs/base.config` | 6836 |
| 脚本数 | `ls scripts/ \| wc -l` | 11 |
| 补丁数 | `ls patches-v1/ \| wc -l` | 13 |
| 文档数 | `ls *.md \| wc -l` | 7 |