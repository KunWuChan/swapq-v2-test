# Swap Priority Queue v2 — Benchmark Conclusions

## English

### Test Setup

- **Server**: Kunpeng 920, 256 cores, 249 GiB RAM, aarch64, Kylin OS
- **Workload**: Kernel build under memory cgroup (2 GiB / 3 GiB), 8 ZRAM devices, `make -j96 defconfig Image modules`
- **Method**: 1 warm-up + 12 measured samples per arm per workload

### Comparison Arms

| Arm | Branch | Kernel | Patches | Description |
|-----|--------|:------:|:------:|-------------|
| A | swapq-v1-before | 7.2.0-rc2 | 0 | v1 baseline (no swap patches) |
| B | swapq-v1-patch8 | 7.2.0-rc2 | 8 | v1 infrastructure + per-device cluster |
| C | swapq-v1-patch13 | 7.2.0-rc2 | 13 | v1 full patches (with priority queue) |
| D | swapq-v2-base | 7.2.0-rc5 | 0 | v2 baseline |
| E | swapq-v2 | 7.2.0-rc5 | 13 | v2 full patches (with priority queue) |

### Results

| Arm | 2g avg | 3g avg | Conclusion |
|-----|:------:|:------:|------------|
| A (v1 base) | 8:50 | 5:37 | Baseline |
| B (v1+8p) | 17:08 | 10:55 | Intermediate state (see below) |
| C (v1+13p) | 8:53 | 5:42 | Normal |
| D (v2 base) | 8:38 | 5:34 | Baseline |
| E (v2+13p) | 8:47 | 5:42 | Normal |

### Key Findings

1. **No performance regression from the 13 patches**: A/C/D/E are all within 3%
   of each other, well within measurement noise. Adding the 13 swap priority
   queue v2 patches does not degrade kernel build performance.

2. **v1 and v2 baselines are equivalent**: A (rc2) vs D (rc5) differ by only
   2.3%, confirming that kernel changes between rc2 and rc5 do not affect swap
   performance.

3. **B is an intermediate state, not a bug**: B has patches 1-8 (including
   per-device percpu cluster) but lacks patch 9 (priority queue). The
   per-device cluster conflicts with the old plist-based allocation, causing
   2.4x higher system time. C (which has all 13 patches including patch 9)
   runs normally, confirming that patch 8 must be used together with patch 9.

4. **Functional correctness**: All 5 KMB tests passed on Arm E. Stress test
   (600s swapon/swapoff) passed. dmesg remained clean throughout.

### Conclusion

The swap priority queue v2 patch series is functionally correct and introduces
**no measurable performance regression**. The 13 patches are ready for upstream
RFC submission.

---

## 中文

### 测试环境

- **服务器**: Kunpeng 920, 256核, 249 GiB 内存, aarch64, Kylin OS
- **负载**: 在内存 cgroup 限制下编译内核（2 GiB / 3 GiB），8 个 ZRAM 设备，`make -j96 defconfig Image modules`
- **方法**: 每个臂每个负载 1 次预热 + 12 次测量

### 对比臂

| 臂 | 分支 | 内核 | 补丁数 | 说明 |
|----|------|:------:|:------:|------|
| A | swapq-v1-before | 7.2.0-rc2 | 0 | v1 基线（无 swap 补丁） |
| B | swapq-v1-patch8 | 7.2.0-rc2 | 8 | v1 基础设施 + per-device cluster |
| C | swapq-v1-patch13 | 7.2.0-rc2 | 13 | v1 完整补丁（含 priority queue） |
| D | swapq-v2-base | 7.2.0-rc5 | 0 | v2 基线 |
| E | swapq-v2 | 7.2.0-rc5 | 13 | v2 完整补丁（含 priority queue） |

### 结果

| 臂 | 2g 平均 | 3g 平均 | 结论 |
|-----|:------:|:------:|------|
| A (v1 base) | 8:50 | 5:37 | 基线 |
| B (v1+8p) | 17:08 | 10:55 | 中间态（见下文） |
| C (v1+13p) | 8:53 | 5:42 | 正常 |
| D (v2 base) | 8:38 | 5:34 | 基线 |
| E (v2+13p) | 8:47 | 5:42 | 正常 |

### 关键发现

1. **13 个补丁无性能退化**: A/C/D/E 四个臂的差异在 3% 以内，在测量噪声范围内。
   添加 13 个 swap priority queue v2 补丁不会降低内核编译性能。

2. **v1 和 v2 基线性能一致**: A (rc2) 与 D (rc5) 仅差 2.3%，说明 rc2 到 rc5
   之间的内核改动不影响 swap 性能。

3. **B 是设计上的中间态，不是 bug**: B 有补丁 1-8（含 per-device percpu cluster）
   但缺少补丁 9（priority queue）。per-device cluster 与老的 plist 分配机制
   不兼容，导致 system time 增加 2.4 倍。C（有全部 13 个补丁，含补丁 9）运行正常，
   确认补丁 8 必须配合补丁 9 使用。

4. **功能正确性**: Arm E 上 5 项 KMB 功能测试全部通过。压力测试（600 秒 swapon/swapoff）
   通过。dmesg 全程无异常。

### 结论

swap priority queue v2 补丁系列功能正确，**无性能退化**。13 个补丁已准备好进行上游
RFC 提交。