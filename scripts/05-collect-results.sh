#!/bin/bash
# Collect and summarize benchmark results
# Usage: bash 05-collect-results.sh [--compare] [result-dir]

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

COMPARE_MODE=0
RESULT_BASE="${1:-$RESULT_DIR}"
if [ "$RESULT_BASE" == "--compare" ]; then
    COMPARE_MODE=1
    RESULT_BASE="${2:-$RESULT_DIR}"
fi

info "=========================================="
info "Collecting results from: $RESULT_BASE"
info "=========================================="

# ── Extract build sample results ───────────────────────────
extract_build_samples() {
    local bench_dir=$1
    info "Extracting from: $bench_dir"

    echo ""
    echo "===== Build Samples ====="
    printf "%-15s %-10s %-10s %-20s %-20s %-10s\n" \
        "Sample" "Exit" "OOM" "Elapsed" "System Time" "Peak ZRAM(KiB)"
    printf "%s\n" "$(printf '%.0s-' {1..100})"

    for sample_dir in "$bench_dir"/sample-* "$bench_dir"/warmup; do
        [ -d "$sample_dir" ] || continue
        local name
        name=$(basename "$sample_dir")
        local result_file="$sample_dir/result.txt"
        local time_file="$sample_dir/time.txt"

        if [ -f "$result_file" ]; then
            local exit_code oom elapsed sys_time peak
            exit_code=$(grep 'build_exit=' "$result_file" | cut -d= -f2)
            oom=$(grep 'oom_kill=' "$result_file" | cut -d= -f2)
            elapsed=$(grep 'Elapsed' "$time_file" 2>/dev/null | awk '{print $NF}' || echo "N/A")
            sys_time=$(grep 'System time' "$time_file" 2>/dev/null | awk '{print $NF}' || echo "N/A")
            peak=$(grep 'peak_used_kib' "$result_file" 2>/dev/null | sed 's/peak_used_kib//' | xargs || echo "N/A")

            printf "%-15s %-10s %-10s %-20s %-20s %-10s\n" \
                "$name" "${exit_code:-?}" "${oom:-?}" "$elapsed" "$sys_time" "${peak:0:50}..."
        fi
    done
}

# ── Extract BRD results ────────────────────────────────────
extract_brd_samples() {
    local bench_dir=$1
    info "Extracting from: $bench_dir"

    echo ""
    echo "===== BRD Samples ====="
    for sample_dir in "$bench_dir"/brd-*; do
        [ -d "$sample_dir" ] || continue
        echo "--- $(basename "$sample_dir") ---"
        if [ -f "$sample_dir/time.txt" ]; then
            grep -E 'Elapsed|System time|User time|Maximum resident' "$sample_dir/time.txt"
        fi
        if [ -f "$sample_dir/throughput.txt" ]; then
            cat "$sample_dir/throughput.txt"
        fi
        if [ -f "$sample_dir/vmstat.delta" ]; then
            echo "Top VM counter deltas:"
            head -20 "$sample_dir/vmstat.delta"
        fi
        echo ""
    done
}

# ── Compare D vs E ─────────────────────────────────────────
compare_arms() {
    info "Comparing Arm D vs Arm E..."

    local dir_d="$RESULT_BASE/arm-D"
    local dir_e="$RESULT_BASE/arm-E"

    for workload in 2g 3g brd; do
        echo ""
        echo "===== $workload ====="

        # Find latest bench dirs
        local bench_d=$(ls -td "$dir_d"/bench-${workload}-* 2>/dev/null | head -1)
        local bench_e=$(ls -td "$dir_e"/bench-${workload}-* 2>/dev/null | head -1)

        if [ -z "$bench_d" ] || [ -z "$bench_e" ]; then
            echo "  Missing data: D=${bench_d:-none} E=${bench_e:-none}"
            continue
        fi

        # Collect measured sample times
        echo "  Arm D (base):"
        for f in "$bench_d"/sample-*/time.txt; do
            [ -f "$f" ] || continue
            echo "    $(grep 'System time\|Elapsed' "$f" 2>/dev/null | paste -sd ';')"
        done

        echo "  Arm E (v2):"
        for f in "$bench_e"/sample-*/time.txt; do
            [ -f "$f" ] || continue
            echo "    $(grep 'System time\|Elapsed' "$f" 2>/dev/null | paste -sd ';')"
        done

        # Compute averages
        echo ""
        echo "  Average elapsed (D):"
        grep -h 'Elapsed' "$bench_d"/sample-*/time.txt 2>/dev/null | \
            awk '{split($NF,a,":"); sum+=a[1]*60+a[2]} END{printf "%.2f min\n", sum/NR/60}'
        echo "  Average elapsed (E):"
        grep -h 'Elapsed' "$bench_e"/sample-*/time.txt 2>/dev/null | \
            awk '{split($NF,a,":"); sum+=a[1]*60+a[2]} END{printf "%.2f min\n", sum/NR/60}'
    done
}

# ── Main ────────────────────────────────────────────────────
# Scan for bench directories
echo ""
echo "Benchmark directories found:"
find "$RESULT_BASE" -maxdepth 3 -name "bench-*" -type d 2>/dev/null | sort | while read -r d; do
    echo "  $d ($(find "$d" -name 'result.txt' | wc -l) samples)"
done

# Extract results
for bench_dir in $(find "$RESULT_BASE" -maxdepth 3 -name "bench-2g*" -o -name "bench-3g*" -type d 2>/dev/null | sort); do
    extract_build_samples "$bench_dir"
done

for bench_dir in $(find "$RESULT_BASE" -maxdepth 3 -name "bench-brd*" -type d 2>/dev/null | sort); do
    extract_brd_samples "$bench_dir"
done

# Compare if requested
if [ "$COMPARE_MODE" -eq 1 ]; then
    compare_arms
fi

# ── Functional test results ────────────────────────────────
echo ""
echo "===== Functional Test Results ====="
find "$RESULT_BASE" -name "functional-*" -type d 2>/dev/null | sort | while read -r d; do
    echo "--- $(basename "$d") ---"
    for log in "$d"/*.txt; do
        [ -f "$log" ] || continue
        echo "  $(basename "$log"): $(wc -l < "$log") lines"
    done
done

info "Done. Run with --compare for D vs E comparison."
