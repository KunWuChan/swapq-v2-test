# Swap Queue v2 测试流程（手动构建 + 脚本测试）

> 编译、安装、切换内核全部手动操作。功能/性能/压力测试用脚本执行。

---

## 一、五臂矩阵

| 臂 | 分支 | worktree 路径 | tree hash |
|----|------|---------------|-----------|
| A | `swapq-v1-before` | `/home/chentao/swapq-A/src` | `57ee9934fd53` |
| B | `swapq-v1-patch8` | `/home/chentao/swapq-B/src` | `8597824ce792` |
| C | `swapq-v1-patch13` | `/home/chentao/swapq-C/src` | `d03738f4dbd6` |
| D | `swapq-v2-base` | `/home/chentao/swapq-D/src` | `0dd2a1e02d48` |
| E | `swapq-v2` | `/home/chentao/swapq-E/src` | `e41508faa11f` |

对比规则：A→C 是 v1 补丁归因；D→E 是 v2 补丁归因。B 是中间态验证。A 和 D 不同内核版本，非补丁归因对比。

---

## 二、前置准备

### 2.1 创建 worktree

```bash
cd /home/chentao/mm
git worktree add /home/chentao/swapq-A/src swapq-v1-before
git worktree add /home/chentao/swapq-B/src swapq-v1-patch8
git worktree add /home/chentao/swapq-C/src swapq-v1-patch13
git worktree add /home/chentao/swapq-D/src swapq-v2-base
git worktree add /home/chentao/swapq-E/src swapq-v2
git worktree list
```

### 2.2 修复测试脚本 aarch64 兼容性

```bash
cd /home/chentao/swapq-v2-test
sed -i 's/defconfig bzImage modules/defconfig Image modules/' scripts/04-run-benchmark.sh
```

### 2.3 创建 benchmark 编译负载归档

```bash
cd /home/chentao/mm
git archive --format=tar --prefix=linux/ mm-stable-2026-06-23-08-55 | xz -T0 > /root/linux.tar.xz
```

> 04-benchmark 解压 `/root/linux.tar.xz` 到 `/tmp` 后 `make -j96` 消耗内存触发 swap。
> 如不跑 benchmark 可跳过。

---

## 三、手动构建（每个臂重复以下步骤）

> 以 Arm E 为例，其余臂替换 `E` 和分支路径即可。

```bash
# 1. 进入 worktree
cd /home/chentao/swapq-E/src

# 2. 配置
cp /home/chentao/swapq-v2-test/configs/base.config .config
scripts/config --file .config --set-str LOCALVERSION "-swapq-E"
scripts/config --file .config --enable LOCALVERSION_AUTO
make olddefconfig

# 3. 编译（256 核）
make -j256

# 4. 安装模块（装到 /lib/modules，根分区空间充足）
make modules_install

# 5. 记录 KVER
KVER=$(make -s kernelrelease)
echo $KVER    # 如 7.1.0-rc5-swapq-E-gaa162bca0b4

# 6. 安装到 /boot（手动控制）
cp arch/arm64/boot/Image /boot/vmlinuz-$KVER
cp System.map /boot/System.map-$KVER
dracut /boot/initramfs-$KVER.img $KVER
grub2-mkconfig -o /boot/grub2/grub.cfg

# 7. 切换
grub2-reboot '<entry>'
reboot

# 8. 重启后确认
uname -r    # 应含 -swapq-E-
```

> **关键**：`LOCALVERSION="-swapq-<ARM>"` 必须设置，测试脚本靠 `uname -r` 中的 `-swapq-<ARM>` 识别当前臂。
> 编译产物保留在各自 worktree 目录，不互相覆盖。
> /boot 每次只放一个内核，测完删掉再装下一个。

---

## 四、测试脚本使用

> 所有脚本需 `ALLOW_NON_KP_HOST=1`（hostname 非 kp）。
> 每次重启后先 `dmesg -C` 清理。
> 脚本目录：`/home/chentao/swapq-v2-test/scripts/`

### 4.1 功能测试（03-run-functional.sh）

> **必须在 Arm E 上运行**（脚本从 `uname -r` 强制校验）。

```bash
cd /home/chentao/swapq-v2-test
dmesg -C

# 快速版（跳过压力部分）
ALLOW_NON_KP_HOST=1 bash scripts/03-run-functional.sh --quick

# 完整版（6 项测试：同优先级分发 / 并发 swapon / full-refill / large-folio / dmesg）
ALLOW_NON_KP_HOST=1 bash scripts/03-run-functional.sh
```

### 4.2 压力测试（06-run-stress.sh）

> **必须在 Arm E 上运行**。ring 变更 + CPU 迁移压力，非性能测试。

```bash
dmesg -C

# 快速 30s
DURATION=30 ALLOW_NON_KP_HOST=1 bash scripts/06-run-stress.sh --quick

# 完整 600s
DURATION=600 ALLOW_NON_KP_HOST=1 bash scripts/06-run-stress.sh
```

### 4.3 性能基准（04-run-benchmark.sh）

> 可在任意 A–E 内核上运行（从 `uname -r` 识别臂）。

```bash
dmesg -C

# 2g：memcg 2GiB，8× ZRAM(8G)，kernel build -j96，1 warmup + 12 measured
ALLOW_NON_KP_HOST=1 bash scripts/04-run-benchmark.sh 2g

# 3g：memcg 3GiB，同上
ALLOW_NON_KP_HOST=1 bash scripts/04-run-benchmark.sh 3g

# 快速版（只 warmup，不测样本）
ALLOW_NON_KP_HOST=1 bash scripts/04-run-benchmark.sh 2g --quick

# brd：12× brd，usemem 32 线程（需 usemem，当前缺失，暂跳过）
# BRD_DEVICE_SIZE_MIB=2048 BRD_PER_THREAD_MIB=1536 \
# ALLOW_NON_KP_HOST=1 bash scripts/04-run-benchmark.sh brd
```

### 4.4 结果收集（05-collect-results.sh）

```bash
ALLOW_NON_KP_HOST=1 bash scripts/05-collect-results.sh --compare
```

### 4.5 多 SSD（07-run-multissd.sh）

> 破坏性，专用分区，≥2 不同物理盘，最后单独跑。

```bash
SWAP_DEVICES='/dev/nvme1n1p1 /dev/nvme2n1p1' \
ALLOW_NON_KP_HOST=1 \
bash scripts/07-run-multissd.sh \
    --workload-script /root/run-pressure.sh \
    --confirm-destructive
```

---

## 五、测试执行记录

| 步骤 | 臂 | 内容 | 状态 | 日期 |
|------|:--:|------|:----:|------|
| 1 | E | functional (5/5) + stress (600s) + 2g quick | ✅ | 8/26 |
| 2 | D | 2g + 3g (12 samples each) | ✅ | 8/25-26 |
| 3 | E | 2g + 3g (12 samples each) | ✅ | 8/26 |
| 4 | A | 2g + 3g (12 samples each) | ✅ | 8/26 |
| 5 | B | 2g + 3g (12 samples each) | ✅ | 8/27 |
| 6 | C | 2g + 3g (12 samples each) | ✅ | 8/27 |
| 7 | — | 结果收集 | ✅ | 本分支 |
| 8 | — | 多 SSD | ⏳ 跳过 | — |

### 最终结果

| 臂 | 2g avg | 3g avg | 结论 |
|----|:------:|:------:|------|
| A (v1 base) | 8:50 | 5:37 | 基线 |
| B (v1+8p) | ~~17:08~~ | ~~10:55~~ | ⚠️ 中间态（见说明） |
| C (v1+13p) | 8:53 | 5:42 | 正常 |
| D (v2 base) | 8:38 | 5:34 | 基线 |
| E (v2+13p) | 8:47 | 5:42 | 正常 |

**结论**：A/C/D/E 差异 <3%，13 个补丁无性能退化。B 的 2x 慢是**设计上的中间态**：patch 8（per-device cluster）与老 plist 分配不兼容，需要 patch 9（priority queue）配合。C 有全部 13 个补丁且正常，验证了这一点。

---

## 六、与 Lian 原始设计的对比

Lian 邮件中指定的 commit：

| 臂 | Lian 指定 commit | 实际 commit | 分支 | 差异原因 |
|----|-----------------|------------|------|----------|
| A | bdc38bfc1262 | bdc38bfc126 | swapq-v1-before | 同一 commit |
| B | 4a7d8bd1b664 | 5d5c0f6c4e6 | swapq-v1-patch8 | 补丁应用到不同 base |
| C | a438694aa41a | 9854da38189 | swapq-v1-patch13 | 补丁应用到不同 base |
| D | 94f9b3980dd4 | 94f9b3980dd | swapq-v2-base | 同一 commit |
| E | d5c8964cf19f | aa162bca0b4 | swapq-v2 | 补丁应用到不同 base |

Lian 的 A 基于 rc2，D 基于 rc5。实际分支也保持了这一结构：
- A/B/C: 7.2.0-rc2 (v1 家族)
- D/E: 7.2.0-rc5 (v2 家族)

Commit 差异是因为补丁提取后应用到不同 tree 上，导致 hash 不同，但**补丁内容一致**。

## 七、脚本改动说明

| 脚本 | 改动 | 原因 |
|------|------|------|
| lib-common.sh | detect_running_arm 正则 `(-\|$)` | 适配 `-g<commit>` 后缀 |
| lib-common.sh | modprobe zram num_devices=$count | 需指定设备数量 |
| 01-build-arm.sh | 添加 NO_INSTALL=1 | 用户手动构建安装 |
| 03-run-functional.sh | Test 3/4 memcg/zram/THP 参数调整 | 适配 256核 aarch64 |
| 03-run-functional.sh | Test 4 检查条件放宽 | per-CPU ring 不轮转 |
| 04-run-benchmark.sh | bzImage→Image | aarch64 镜像名 |
| 04-run-benchmark.sh | modprobe zram num_devices | 同上 |
| 06-run-stress.sh | 添加 modprobe -r zram; modprobe zram num_devices=5 | 确保设备存在 |

## 八、注意事项

- 全程 `ALLOW_NON_KP_HOST=1`。
- 每次重启后 `dmesg -C`。
- `LOCALVERSION="-swapq-<ARM>"` 必须设对，否则测试脚本无法识别臂。
- 04 脚本的 `bzImage` 必须改成 `Image`（aarch64）。
- 04 需要 `/root/linux.tar.xz`（benchmark 编译负载）。
- benchmark 拒绝已存在的 zram/brd swap——测试前确保 `swapoff -a`。
- 编译产物保留在 `/home/chentao/swapq-<ARM>/src/`，不随 /boot 清理丢失。
