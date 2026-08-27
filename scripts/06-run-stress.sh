#!/bin/bash
# Exercise per-CPU retry state across CPU migration while swap devices are
# concurrently inserted into and removed from the same-priority ring.
# This is a correctness/stability stress test, not a performance benchmark.

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_host

DURATION=${DURATION:-600}
WORKERS=${WORKERS:-4}
WORKER_MIB=${WORKER_MIB:-512}
MEMCG_MAX=${MEMCG_MAX:-1G}
ZRAM_STRESS_SIZE=${ZRAM_STRESS_SIZE:-1G}
[ "${1:-}" = "--quick" ] && DURATION=30

if [ "$(id -u)" -ne 0 ]; then
    error "Stress test must run as root"
    exit 1
fi
[ "$(detect_running_arm)" = E ] || {
    error "Ring-mutation stress is intended for the identified Arm E kernel"
    exit 1
}
for cmd in python3 taskset; do
    command -v "$cmd" >/dev/null || { error "Missing command: $cmd"; exit 1; }
done
if [ ! -f /sys/fs/cgroup/cgroup.controllers ] ||
        ! grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
    error "cgroup v2 memory controller is required"
    exit 1
fi

RUN_DIR="$RESULT_DIR/arm-E/stress-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
ORIG_SWAP_STATE="$RUN_DIR/original-swaps.txt"
snapshot_swap_state "$ORIG_SWAP_STATE"
grep -Eq '^/dev/zram[0-9]+ ' "$ORIG_SWAP_STATE" && {
    error "Pre-existing zram swap is active; refusing to reuse it"
    exit 1
}

CG="/sys/fs/cgroup/swapq-stress-$$"
WORKER_PIDS=()
MIGRATOR_PID=""
CHURN_PID=""
DMESG_LINES=$(dmesg | wc -l)

cleanup() {
    local rc=$? pid
    [ -n "$MIGRATOR_PID" ] && kill "$MIGRATOR_PID" 2>/dev/null || true
    [ -n "$CHURN_PID" ] && kill "$CHURN_PID" 2>/dev/null || true
    for pid in "${WORKER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${WORKER_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    cleanup_zram_devices 5
    [ -d "$CG" ] && rmdir "$CG" 2>/dev/null || true
    restore_swap_state "$ORIG_SWAP_STATE" || rc=1
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

swapoff -a
modprobe -r zram 2>/dev/null || true
modprobe zram num_devices=5 2>/dev/null || true
setup_zram_swap 4 "$ZRAM_STRESS_SIZE"
[ -b /dev/zram4 ] || { error "/dev/zram4 is required for ring churn"; exit 1; }
echo 1 > /sys/block/zram4/reset 2>/dev/null || true
echo "$ZRAM_STRESS_SIZE" > /sys/block/zram4/disksize
mkswap /dev/zram4 >/dev/null

mkdir "$CG"
echo "$MEMCG_MAX" > "$CG/memory.max"
echo max > "$CG/memory.swap.max"
cat /proc/vmstat > "$RUN_DIR/vmstat.before"

for ((i = 0; i < WORKERS; i++)); do
    CG_PATH="$CG" ALLOC_MIB="$WORKER_MIB" python3 - <<'PY' \
            >"$RUN_DIR/worker-$i.log" 2>&1 &
import os, time
with open(os.environ["CG_PATH"] + "/cgroup.procs", "w") as f:
    f.write(str(os.getpid()))
n = int(os.environ["ALLOC_MIB"]) * 1024 * 1024
b = bytearray(n)
page = os.urandom(4096)
for p in range(0, n, 4096):
    b[p:p + 4096] = page[:min(4096, n - p)]
while True:
    for p in range(0, n, 4096 * 64):
        b[p] ^= 1
    time.sleep(0.05)
PY
    WORKER_PIDS+=("$!")
done

(
    cpus=()
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$cpu_dir" ] || continue
        if [ ! -f "$cpu_dir/online" ] || [ "$(cat "$cpu_dir/online")" = 1 ]; then
            cpus+=("${cpu_dir##*cpu}")
        fi
    done
    [ "${#cpus[@]}" -gt 0 ]
    end=$((SECONDS + DURATION))
    moves=0
    while [ "$SECONDS" -lt "$end" ]; do
        for pid in "${WORKER_PIDS[@]}"; do
            kill -0 "$pid"
            cpu=${cpus[$((moves % ${#cpus[@]}))]}
            taskset -pc "$cpu" "$pid" >/dev/null
            moves=$((moves + 1))
        done
        sleep 0.05
    done
    echo "$moves" > "$RUN_DIR/migration-count.txt"
) &
MIGRATOR_PID=$!

(
    end=$((SECONDS + DURATION))
    cycles=0
    while [ "$SECONDS" -lt "$end" ]; do
        swapon -p 10 /dev/zram4
        cat /proc/swaps >/dev/null
        sleep 0.1
        swapoff /dev/zram4
        cycles=$((cycles + 1))
    done
    echo "$cycles" > "$RUN_DIR/ring-mutation-count.txt"
) >"$RUN_DIR/ring-mutation.log" 2>&1 &
CHURN_PID=$!

migrate_rc=0
churn_rc=0
wait "$MIGRATOR_PID" || migrate_rc=$?
MIGRATOR_PID=""
wait "$CHURN_PID" || churn_rc=$?
CHURN_PID=""

worker_bad=0
for pid in "${WORKER_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null || worker_bad=1; done
cat /proc/vmstat > "$RUN_DIR/vmstat.after"
vm_counters_delta "$RUN_DIR/vmstat.before" "$RUN_DIR/vmstat.after" > "$RUN_DIR/vmstat.delta"
cat /proc/swaps > "$RUN_DIR/swaps.final"
dmesg | tail -n "+$((DMESG_LINES + 1))" > "$RUN_DIR/dmesg.delta"

pswpout=$(awk '$1 == "pswpout" { gsub("+", "", $2); print $2 }' "$RUN_DIR/vmstat.delta")
pswpout=${pswpout:-0}
dmesg_bad=0
grep -qEi 'BUG:|WARNING:|Oops:|panic|KASAN:|KCSAN:|UBSAN:|lockup|rcu.*stall|hung task' \
    "$RUN_DIR/dmesg.delta" && dmesg_bad=1
used_devices=$(awk 'NR > 1 && $1 ~ /^\/dev\/zram[0-3]$/ && $4 > 0 { n++ } END { print n+0 }' /proc/swaps)

{
    echo "migrator_exit=$migrate_rc"
    echo "ring_mutator_exit=$churn_rc"
    echo "worker_bad=$worker_bad"
    echo "pswpout_delta=$pswpout"
    echo "used_base_devices=$used_devices"
    echo "dmesg_bad=$dmesg_bad"
    echo "migration_count=$(cat "$RUN_DIR/migration-count.txt" 2>/dev/null || echo 0)"
    echo "ring_mutation_count=$(cat "$RUN_DIR/ring-mutation-count.txt" 2>/dev/null || echo 0)"
} > "$RUN_DIR/result.txt"

if [ "$migrate_rc" -ne 0 ] || [ "$churn_rc" -ne 0 ] || [ "$worker_bad" -ne 0 ] ||
        [ "$pswpout" -le 0 ] || [ "$used_devices" -lt 2 ] || [ "$dmesg_bad" -ne 0 ]; then
    error "Stress test failed one or more validity gates: $RUN_DIR/result.txt"
    exit 1
fi
info "Stress test passed: $RUN_DIR"
