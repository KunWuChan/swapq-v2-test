# Swap Queue v2 测试计划（基于独立构建版本 116fbf0+）

> 本计划覆盖从源码就绪到出结果的完整测试流程，所有命令在 kp-server 上执行。

## 0. 背景与对比矩阵

Swap Queue v2 由 13 个补丁构成，覆盖 v1 全部功能并新增 per-CPU ring / 优先级队列。
为排除 base 差异干扰，采用 **A–E 五臂矩阵**：

| 臂 | 分支 | 内容 | 身份校验 |
|----|------|------|----------|
| A | `swapq-v1-before` | v1 补丁的父提交（v1 base） | 精确 commit `bdc38bfc1262` + tree |
| B | `swapq-v1-patch8` | v1 前 8 个补丁 | 精确 tree（`git am` committer 不同，commit id 可变） |
| C | `swapq-v1-patch13` | v1 完整 13 补丁 | 精确 tree |
| D | `swapq-v2-base` | v2 base（精确 `94f9b3980dd4`） | 精确 commit + tree |
| E | `swapq-v2` | v2 base + 13 补丁 | 精确 tree |

> B/C/E 的 commit id 因 `git am` committer date 与截图不同是正常现象，脚本按 **tree hash** 校验。
> D 是精确的 `94f9b3980dd4`。

**对比规则（重要）**：A/C 与 D/E 的 base 历史不同（v1 base vs v2 base），
**不可把 A/C→D/E 当作纯补丁性能差异**。有效的对比是：
- v1 家族内部：A vs B vs C（同一 v1 历史）
- v2 家族内部：D vs E（同一 v2 历史，纯 13 补丁归因）

## 1. 环境与前置准备（当前已完成 ✅）

| 步骤 | 状态 |
|------|------|
| 拉取独立构建版本（HEAD `192df64`，含 `116fbf0`） | ✅ |
| `sha256sum -c ARTIFACTS.sha256`（27 个产物） | ✅ |
| `99-verify-env.sh` 全 PASS | ✅ |
| `00-apply-patches.sh` 建立 A–E 五分支 | ✅（A `bdc38bfc`、B `5d5c0f6c`、C `9854da38`、D `94f9b398`、E `aa162bca`） |
| `configs/base.config`（来自 `/proc/config.gz`） | ✅ 6836 行，SWAP/MEMCG/THP=y，ZRAM=m |

> 说明：`/boot` 下无 `config-7.1.0-rc5-mm-new-damon+`，运行内核 config 取自
> `zcat /proc/config.gz > configs/base.config`。

## 2. 构建（顺序执行，不可并行）

> **重要**：每个 Arm 使用**独立输出目录** `/home/chentao/swapq-build/arm-{A..E}`，
> 不复用中间产物；同一源码树 `/home/chentao/mm` 只能串行 checkout。

```bash
cd /home/chentao/swapq-v2-test
mkdir -p configs results
KERNEL_SRC=/home/chentao/mm bash scripts/99-verify-env.sh

for arm in D E A B C; do
    KERNEL_SRC=/home/chentao/mm \
    bash scripts/01-build-arm.sh "$arm" || break
done
```

- 顺序 `D E A B C`：先构建 v2 家族，尽早开始 Arm E 冒烟。
- 每个臂输出：`/home/chentao/swapq-build/arm-<ARM>/`（.config、Image、模块）。
- 构建后自动执行 `make install` 到 `/boot` + `grub2-mkconfig`。
- 产物落盘：`results/build-arm-<ARM>-meta.txt`、`results/build-arm-<ARM>-*.log`。

**/boot 空间约束**：`/boot` 目前 958M / 577M 可用，脚本要求 ≥1024 MiB
（`MIN_BOOT_FREE_MIB`）才会放行。如果空间不足：
1. `ls /boot/vmlinuz-* /boot/initramfs-*` 清理旧内核（保留当前运行内核）；
2. 或设置 `MIN_BOOT_FREE_MIB=0 MIN_BUILD_FREE_GIB=0` 跳过检查
   （`/boot` 至少需容纳一个 vmlinuz + initramfs，约 100–200 MiB）。

**aarch64 注意**：kp-server 是 `aarch64`，内核镜像目标是 `Image`
（`/boot/vmlinuz-<kver>` 由 install 步骤自动处理），构建流程无需改动。

## 3. 切换内核与启动

构建完成后需手动选择内核并重启。GRUB2 风格：

```bash
# 查看可用 menu entry（确认 swapq-<ARM> 条目存在）
grep -E 'menuentry |submenu ' /boot/grub2/grub.cfg | grep -i swapq

# 一次性启动到指定臂（grub2-reboot 设置下次启动项）
GRUB_ENTRY='<submenu_id>>entry_id>' \
bash scripts/02-switch-kernel.sh E
bash scripts/02-switch-kernel.sh E --reboot   # 确认条目后加 --reboot
```

> `GRUB_ENTRY` 必须是 grub.cfg 中精确的 entry id（如 `Advanced>...>xxx`），脚本拒绝猜测。
> 重启后确认：`uname -r` 应包含 `-swapq-E-`。
> 若 `02-switch-kernel.sh` 匹配不到，可手动编辑 `/boot/grub2/grub.cfg` 或
> 用自己熟悉的安装/切换流程（注意保留 `CONFIG_LOCALVERSION="-swapq-<ARM>"` 的区分）。

## 4. 测试顺序（建议）

### 4.1 第一步：Arm E 冒烟（functional + stress + quick bench）

切到 **E** 内核后：

```bash
cd /home/chentao/swapq-v2-test

# 功能测试（需运行内核为 E；含同优先级分发/并发/proc 读/swapon 风暴/dmesg 检查）
bash scripts/03-run-functional.sh --quick      # 快速版
bash scripts/03-run-functional.sh              # 完整版

# ring 变更 + CPU 迁移压力（默认 600s，--quick=30s）
DURATION=600 bash scripts/06-run-stress.sh
# DURATION=30 bash scripts/06-run-stress.sh --quick

# 2g 快速冒烟（只跑 warmup，不测重复样本）
bash scripts/04-run-benchmark.sh 2g --quick
```

> `03-run-functional.sh` 与 `06-run-stress.sh` 都强制要求运行内核为 **Arm E**，
> 其他臂会被拒绝（避免误判）。

### 4.2 第二步：D/E 完整性能对照（v2 归因）

先切到 D 跑完整基准，再切到 E 跑完整基准：

```bash
GRUB_ENTRY='<...>' bash scripts/02-switch-kernel.sh D --reboot
# 重启后：
bash scripts/04-run-benchmark.sh 2g
bash scripts/04-run-benchmark.sh 3g
bash scripts/04-run-benchmark.sh brd   # 需 usemem，见 §5

GRUB_ENTRY='<...>' bash scripts/02-switch-kernel.sh E --reboot
# 重启后：
bash scripts/04-run-benchmark.sh 2g
bash scripts/04-run-benchmark.sh 3g
bash scripts/04-run-benchmark.sh brd
```

- `2g`：kernel build，memcg 2GiB，8 个同优先级 ZRAM，`make -j96`。
- `3g`：同上，memcg 3GiB。
- `brd`：12 个 brd 设备，usemem 32 线程压 swap（单样本）。

**04-run-benchmark.sh 前置条件（必须准备）**：

```bash
# 1) 固定内核源码归档（benchmark 用它作为编译负载；解压到 /tmp/swapq-build-src-*）
cp -r /home/chentao/mm /tmp/_src && tar -C /tmp/_src \
    --transform='s,^\./,,' -cJf /root/linux.tar.xz .   # 或按 KERNEL_SRC_ARCHIVE 指定路径
export KERNEL_SRC_ARCHIVE=/root/linux.tar.xz
export KERNEL_ARCHIVE_STRIP_COMPONENTS=1

# 2) usemem（brd workload 必需；无则 brd 跳过）
command -v usemem   # 若缺失：安装/放置到 PATH，见 §5
```

### 4.3 第三步：A/B/C（复现 v1 报告与阶段性差异）

按 A、B、C 依次切换并跑**完整基准**（`2g`/`3g`/`brd`），复现 v1 各阶段结论：

```bash
for arm in A B C; do
    GRUB_ENTRY='<...>' bash scripts/02-switch-kernel.sh $arm --reboot
    # 重启后依次执行：
    #   bash scripts/04-run-benchmark.sh 2g
    #   bash scripts/04-run-benchmark.sh 3g
    #   bash scripts/04-run-benchmark.sh brd
done
```

### 4.4 第四步：真实多 SSD（最后单独执行）

> 必须使用**专用测试分区**（不挂载、非根盘、≥2 个不同物理盘），
> 脚本会写入 swap 签名（破坏性操作）。

```bash
SWAP_DEVICES='/dev/nvme1n1p1 /dev/nvme2n1p1' \
bash scripts/07-run-multissd.sh \
    --workload-script /root/run-pressure.sh \
    --confirm-destructive
```

前置要求（脚本会逐一校验）：
- ≥2 个显式块设备、父盘互不相同、物理身份（serial/sysfs）各不相同；
- 设备未被挂载、不是根文件系统设备/其父盘；
- `--workload-script` 必须是绝对路径的可执行文件（如 `/root/run-pressure.sh`）。

## 5. 工具与归档准备清单

| 项目 | 说明 | 状态 |
|------|------|------|
| `configs/base.config` | `/proc/config.gz` 解压而来 | ✅ |
| `results/` | 测试结果目录 | ✅ 已创建 |
| `/root/linux.tar.xz` | 04-benchmark 的编译负载源码归档 | ❌ 需手动创建（见 §4.2） |
| `usemem` | brd workload 工具（`usemem --init-time -O -y -x -n 32`） | ❌ 需安装 |
| `run-pressure.sh` | 07-multissd 的 workload 脚本 | ❌ 需编写（如 usemem 压测） |
| `/boot` 空间 | ≥1024 MiB 可用（脚本硬门槛） | ⚠️ 577M 可用，需清理或降门槛 |

## 6. 结果收集与比对

```bash
cd /home/chentao/swapq-v2-test
bash scripts/05-collect-results.sh              # 列出各臂 bench/functional 摘要
bash scripts/05-collect-results.sh --compare    # 分组对比（v1: A/B/C；v2: D/E）
```

结果目录结构：

```
results/
├── build-arm-<ARM>-meta.txt / *.log      # 构建元数据与日志
├── functional-<ts>/                      # 03 功能测试（arm E）
├── arm-<ARM>/
│   ├── bench-2g-<ts>/sample-01..12/      # 04 基准（warmup + 12 样本）
│   ├── bench-3g-<ts>/…
│   ├── bench-brd-<ts>/brd-001/           # brd 样本
│   └── multissd-<ts>/                    # 07 多 SSD（含 topology/diskstats）
└── arm-E/stress-<ts>/                    # 06 压力测试（含迁移/ring 变更计数）
```

每样本输出：`build_exit`、`oom_kill`、`pswpout_delta`、`dmesg_bad`、
`peak_used_kib zramN=…`、`System time`、`Elapsed`（`/usr/bin/time -v`）。

有效性门控（任一不满足则样本作废，不混入统计）：
`build_exit=0 && oom_kill=0 && pswpout_delta>0 && dmesg_bad=0`。

## 7. 完成标准

1. **正确性**：E 上 functional 全 PASS + stress（含 CPU 迁移、ring 增删）通过 + dmesg 干净。
2. **性能归因**：D vs E 在 2g/3g/brd 上的差异可归因于 13 个补丁；A/B/C 复现 v1 阶段性结论。
3. **多 SSD**：≥2 物理盘真实 swap 压测通过（无 I/O error、pswpout>0、全部目标盘被使用）。
4. **报告**：`05-collect-results.sh --compare` 输出 A/B/C 与 D/E 两组对比表。

## 8. 常见问题

- **`01-build-arm.sh` 报 hostname 非 kp**：kp-server hostname 是 `localhost.localdomain`，
  需 `ALLOW_NON_KP_HOST=1`（所有脚本的 `check_host` 均需此变量）。
- **`make bzImage` 在 aarch64 不可用**：04 脚本内部用 `defconfig bzImage modules`，
  aarch64 上该目标不存在会失败——**需将脚本中的 `bzImage` 改为 `Image`** 后再跑
  （见 §4.2 的注意）。
- **`git diff --quiet` 失败**：构建前源码树必须干净（00 已 checkout 各分支，不要残留改动）。
- **benchmark 拒绝已存在的 zram/brd swap**：确保测试前 `swapoff -a` 且无遗留设备。
- **切核后 `uname -r` 不含 `-swapq-<ARM>`**：检查 grub 条目是否指向正确内核，
  或手动修改 `/boot/grub2/grub.cfg`。
