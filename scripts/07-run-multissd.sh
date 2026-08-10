#!/bin/bash
# Real multi-SSD swap validation.  This script writes swap signatures to the
# explicitly listed targets; it never guesses devices.
#
# Example:
#   SWAP_DEVICES='/dev/nvme1n1p1 /dev/nvme2n1p1' \
#   bash scripts/07-run-multissd.sh --workload-script /root/run-pressure.sh \
#        --confirm-destructive

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_host

WORKLOAD_SCRIPT=""
CONFIRM=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --workload-script)
            WORKLOAD_SCRIPT=${2:-}
            shift 2
            ;;
        --confirm-destructive)
            CONFIRM=1
            shift
            ;;
        *)
            error "Unknown argument: $1"
            exit 2
            ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { error "Multi-SSD test must run as root"; exit 1; }
[ "$CONFIRM" -eq 1 ] || {
    error "Refusing to write device signatures without --confirm-destructive"
    exit 2
}
[[ "$WORKLOAD_SCRIPT" = /* ]] && [ -f "$WORKLOAD_SCRIPT" ] && [ -x "$WORKLOAD_SCRIPT" ] || {
    error "--workload-script must name an absolute executable file"
    exit 2
}
read -r -a REQUESTED <<< "${SWAP_DEVICES:-}"
[ "${#REQUESTED[@]}" -ge 2 ] || {
    error "SWAP_DEVICES must contain at least two explicit block devices"
    exit 2
}

RUN_ARM=$(detect_running_arm)
[[ "$RUN_ARM" =~ ^[A-E]$ ]] || {
    error "Running kernel is not an identified Arm A-E kernel"
    exit 1
}
RUN_DIR="$RESULT_DIR/arm-$RUN_ARM/multissd-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
ORIG_SWAP_STATE="$RUN_DIR/original-swaps.txt"
snapshot_swap_state "$ORIG_SWAP_STATE"

ROOT_SOURCE=$(findmnt -rn -o SOURCE /)
ROOT_SOURCE=$(readlink -f "$ROOT_SOURCE")
ROOT_ANCESTORS=$(lsblk -srno NAME "$ROOT_SOURCE" 2>/dev/null || basename "$ROOT_SOURCE")
DEVICES=()
PARENTS=()
PHYSICAL_IDS=()

for requested in "${REQUESTED[@]}"; do
    dev=$(readlink -f "$requested")
    [ -b "$dev" ] || { error "Not a block device: $requested"; exit 1; }
    case " ${DEVICES[*]} " in *" $dev "*) error "Duplicate device: $dev"; exit 1;; esac
    awk -v target="$dev" 'NR > 1 && $1 == target { found=1 } END { exit !found }' /proc/swaps && {
        error "$dev is already active swap"
        exit 1
    }
    if lsblk -nrpo MOUNTPOINT "$dev" | grep -qv '^$'; then
        error "$dev or one of its children is mounted"
        exit 1
    fi
    parent=$(lsblk -ndo PKNAME "$dev" 2>/dev/null || true)
    [ -n "$parent" ] || parent=$(basename "$dev")
    if [ "$dev" = "$ROOT_SOURCE" ] ||
            printf '%s\n' "$ROOT_ANCESTORS" | grep -Fxq "$(basename "$dev")" ||
            printf '%s\n' "$ROOT_ANCESTORS" | grep -Fxq "$parent"; then
        error "Refusing root filesystem device or parent: $dev"
        exit 1
    fi
    serial=$(lsblk -ndo SERIAL "/dev/$parent" 2>/dev/null | awk 'NF { print; exit }')
    if [ -n "$serial" ]; then
        physical_id="serial:$serial"
    else
        physical_id="sysfs:$(readlink -f "/sys/class/block/$parent/device" 2>/dev/null || true)"
    fi
    [ "$physical_id" != "sysfs:" ] || {
        error "Cannot establish a physical-device identity for $dev"
        exit 1
    }
    DEVICES+=("$dev")
    PARENTS+=("$parent")
    PHYSICAL_IDS+=("$physical_id")
done

distinct_parents=$(printf '%s\n' "${PARENTS[@]}" | sort -u | wc -l | tr -d ' ')
[ "$distinct_parents" -ge 2 ] || {
    error "Targets do not span at least two distinct parent disks"
    exit 1
}
distinct_physical=$(printf '%s\n' "${PHYSICAL_IDS[@]}" | sort -u | wc -l | tr -d ' ')
[ "$distinct_physical" -eq "${#DEVICES[@]}" ] || {
    error "Targets do not have distinct physical identities (serial/sysfs)"
    exit 1
}

ACTIVE_TARGETS=()
cleanup() {
    local rc=$? dev
    for dev in "${ACTIVE_TARGETS[@]}"; do swapoff "$dev" 2>/dev/null || rc=1; done
    restore_swap_state "$ORIG_SWAP_STATE" || rc=1
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

{
    echo "arm=$RUN_ARM"
    echo "kernel=$(uname -r)"
    echo "root_source=$ROOT_SOURCE"
    for i in "${!DEVICES[@]}"; do
        dev=${DEVICES[$i]}
        echo "device=$dev parent=${PARENTS[$i]} physical_id=${PHYSICAL_IDS[$i]}"
        lsblk -ndo NAME,TYPE,SIZE,MODEL,SERIAL,ROTA,DISC-GRAN,DISC-MAX "$dev"
    done
} > "$RUN_DIR/topology.txt"

swapoff -a
for dev in "${DEVICES[@]}"; do
    mkswap -f "$dev" > "$RUN_DIR/mkswap-$(basename "$dev").txt"
    swapon -p 10 "$dev"
    ACTIVE_TARGETS+=("$dev")
done
cat /proc/swaps > "$RUN_DIR/swaps.before"
cat /proc/diskstats > "$RUN_DIR/diskstats.before"
cat /proc/vmstat > "$RUN_DIR/vmstat.before"
dmesg_lines=$(dmesg | wc -l)

workload_rc=0
/usr/bin/time -v -o "$RUN_DIR/time.txt" "$WORKLOAD_SCRIPT" \
    > "$RUN_DIR/workload.stdout" 2> "$RUN_DIR/workload.stderr" || workload_rc=$?

cat /proc/swaps > "$RUN_DIR/swaps.after"
cat /proc/diskstats > "$RUN_DIR/diskstats.after"
cat /proc/vmstat > "$RUN_DIR/vmstat.after"
vm_counters_delta "$RUN_DIR/vmstat.before" "$RUN_DIR/vmstat.after" > "$RUN_DIR/vmstat.delta"
dmesg | tail -n "+$((dmesg_lines + 1))" > "$RUN_DIR/dmesg.delta"

pswpout=$(awk '$1 == "pswpout" { gsub("+", "", $2); print $2 }' "$RUN_DIR/vmstat.delta")
pswpout=${pswpout:-0}
dmesg_bad=0
grep -qEi 'BUG:|WARNING:|Oops:|panic|KASAN:|KCSAN:|UBSAN:|lockup|rcu.*stall|hung task|I/O error' \
    "$RUN_DIR/dmesg.delta" && dmesg_bad=1
used_targets=0
for dev in "${DEVICES[@]}"; do
    used=$(awk -v target="$dev" 'NR > 1 && $1 == target { print $4 }' "$RUN_DIR/swaps.after")
    [ "${used:-0}" -gt 0 ] && used_targets=$((used_targets + 1))
done

{
    echo "workload_exit=$workload_rc"
    echo "pswpout_delta=$pswpout"
    echo "used_targets=$used_targets"
    echo "target_count=${#DEVICES[@]}"
    echo "distinct_parents=$distinct_parents"
    echo "distinct_physical=$distinct_physical"
    echo "dmesg_bad=$dmesg_bad"
} > "$RUN_DIR/result.txt"

if [ "$workload_rc" -ne 0 ] || [ "$pswpout" -le 0 ] ||
        [ "$used_targets" -ne "${#DEVICES[@]}" ] || [ "$dmesg_bad" -ne 0 ]; then
    error "Multi-SSD run failed one or more validity gates: $RUN_DIR/result.txt"
    exit 1
fi
info "Multi-SSD run passed: $RUN_DIR"
warn "The target devices now contain swap signatures; prior signatures were not restorable."
