#!/bin/bash
# ============================================================================
# PassMark PerformanceTest automation (Linux) - standalone, no telemetry.
#
# Unlike the Windows version (which has to drive PassMark's custom-drawn GUI
# via raw Win32 PostMessage/SendMessage calls against menu/dialog control IDs,
# since there's no standard UI Automation surface), the Linux PassMark
# PerformanceTest build is a plain blocking CLI binary - it runs the selected
# suite(s) and exits on its own, so no window automation/dialog polling is
# needed at all. This script just wraps that CLI with sane defaults and
# captures its output into a timestamped results folder, mirroring the
# Windows script's -TestDuration/-TestIterations options and output layout.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSMARK_BIN="$SCRIPT_DIR/PerformanceTest_Linux/PerformanceTest/run.sh"

# ---------------------------------------------------------------------------
# Defaults (mirrors run_passmark_auto.ps1 -TestDuration/-TestIterations)
# ---------------------------------------------------------------------------
DURATION="Short"        # Short | Medium | Long | VeryLong
ITERATIONS=1            # 1 to 100
PROCESSES="$(nproc --all)"
SUITE="All"             # CPU | Memory | All
CONFIRM=0               # 0 = fully automatic, 1 = ask Y/N before running

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -d, --duration <Short|Medium|Long|VeryLong>   Test duration (default: Short)
  -i, --iterations <1-100>                      Test iterations (default: 1)
  -p, --processes <1-1024>                       Test processes (default: $(nproc --all), all CPU threads)
  -r, --suite <CPU|Memory|All>                  Suite to run (default: All)
  -c, --confirm                                  Ask Y/N before running (default: fully automatic)
  -h, --help                                    Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--duration) DURATION="$2"; shift 2 ;;
    -i|--iterations) ITERATIONS="$2"; shift 2 ;;
    -p|--processes) PROCESSES="$2"; shift 2 ;;
    -r|--suite) SUITE="$2"; shift 2 ;;
    -c|--confirm) CONFIRM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

case "$DURATION" in
  Short) D_FLAG=1 ;;
  Medium) D_FLAG=2 ;;
  Long) D_FLAG=3 ;;
  VeryLong) D_FLAG=4 ;;
  *) echo "Invalid --duration: $DURATION (expected Short|Medium|Long|VeryLong)" >&2; exit 1 ;;
esac

case "$SUITE" in
  CPU) R_FLAG=1 ;;
  Memory) R_FLAG=2 ;;
  All) R_FLAG=3 ;;
  *) echo "Invalid --suite: $SUITE (expected CPU|Memory|All)" >&2; exit 1 ;;
esac

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="$SCRIPT_DIR/Results/$TIMESTAMP"
mkdir -p "$RESULTS_DIR"

echo "============================================================"
echo " PassMark PerformanceTest (Linux) - standalone run"
echo "============================================================"
echo " Duration   : $DURATION (-d $D_FLAG)"
echo " Iterations : $ITERATIONS"
echo " Processes  : $PROCESSES"
echo " Suite      : $SUITE (-r $R_FLAG)"
echo " Results    : $RESULTS_DIR"
echo "============================================================"

if [ "$CONFIRM" -eq 1 ]; then
  read -r -p "Proceed with the benchmark run? (Y/N) " answer
  case "$answer" in
    [Yy]*) ;;
    *) echo "Aborted - nothing was run."; exit 0 ;;
  esac
fi

echo "Starting PassMark benchmark..."
"$PASSMARK_BIN" -d "$D_FLAG" -i "$ITERATIONS" -p "$PROCESSES" -r "$R_FLAG" \
  | tee "$RESULTS_DIR/PassMark_PerfRes.txt"

echo ""
echo "Benchmark complete. Results saved to: $RESULTS_DIR/PassMark_PerfRes.txt"
