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
    printf "%-15s %-8s %-8s %-10s %-8s %-20s %-20s\n" \
        "Sample" "Exit" "OOM" "pswpout" "dmesg" "Elapsed" "System Time"
    printf "%s\n" "$(printf '%.0s-' {1..100})"

    for sample_dir in "$bench_dir"/sample-* "$bench_dir"/warmup; do
        [ -d "$sample_dir" ] || continue
        local name
        name=$(basename "$sample_dir")
        local result_file="$sample_dir/result.txt"
        local time_file="$sample_dir/time.txt"

        if [ -f "$result_file" ]; then
            local exit_code oom pswpout dmesg_bad elapsed sys_time
            exit_code=$(grep 'build_exit=' "$result_file" | cut -d= -f2)
            oom=$(grep 'oom_kill=' "$result_file" | cut -d= -f2)
            pswpout=$(grep 'pswpout_delta=' "$result_file" | cut -d= -f2)
            dmesg_bad=$(grep 'dmesg_bad=' "$result_file" | cut -d= -f2)
            elapsed=$(grep 'Elapsed' "$time_file" 2>/dev/null | awk '{print $NF}' || echo "N/A")
            sys_time=$(grep 'System time' "$time_file" 2>/dev/null | awk '{print $NF}' || echo "N/A")

            printf "%-15s %-8s %-8s %-10s %-8s %-20s %-20s\n" \
                "$name" "${exit_code:-?}" "${oom:-?}" "${pswpout:-?}" \
                "${dmesg_bad:-?}" "$elapsed" "$sys_time"
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

# ── Compare v1 and v2 families without conflating their bases ───────────────
compare_group() {
    local label=$1
    shift
    local arms=("$@") workload arm bench

    echo ""
    echo "######## $label ########"
    for workload in 2g 3g brd; do
        echo ""
        echo "===== $workload ====="
        for arm in "${arms[@]}"; do
            bench=$(ls -td "$RESULT_BASE/arm-$arm"/bench-${workload}-* 2>/dev/null | head -1 || true)
            printf "  Arm %s (%s): " "$arm" "$(arm_desc "$arm")"
            if [ -z "$bench" ]; then
                echo "MISSING"
                continue
            fi
            valid_elapsed_seconds "$bench" | awk '
                { sum += $1; n++ }
                END { if (n) printf "%.2f min (%d valid)\n", sum/n/60, n;
                      else print "INVALID (0 valid)" }'
        done
    done
}

compare_arms() {
    info "Comparing v1 A/B/C and v2 D/E as separate families..."
    compare_group "v1 progression (same v1 history)" A B C
    compare_group "v2 attribution (exact v2 base versus v2 patches)" D E
    echo ""
    echo "Do not treat A/C versus D/E as a patch-only performance delta: the base histories differ."
}

valid_elapsed_seconds() {
    local bench=$1 result time_value
    for result in "$bench"/sample-*/result.txt "$bench"/brd-*/result.txt; do
        [ -f "$result" ] || continue
        grep -qx 'build_exit=0' "$result" || continue
        grep -qx 'oom_kill=0' "$result" || continue
        grep -qx 'dmesg_bad=0' "$result" || continue
        awk -F= '$1 == "pswpout_delta" && $2 > 0 { ok=1 } END { exit !ok }' "$result" || continue
        time_value=$(grep 'Elapsed' "${result%/result.txt}/time.txt" | awk '{print $NF}')
        awk -F: '
            NF == 3 { print $1 * 3600 + $2 * 60 + $3 }
            NF == 2 { print $1 * 60 + $2 }
            NF == 1 { print $1 }
        ' <<< "$time_value"
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
for bench_dir in $(find "$RESULT_BASE" -maxdepth 3 -type d \
        \( -name "bench-2g*" -o -name "bench-3g*" \) 2>/dev/null | sort); do
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

info "Done. Run with --compare for separate A/B/C and D/E comparisons."
