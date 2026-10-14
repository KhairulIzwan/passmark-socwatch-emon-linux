#!/bin/bash
# ============================================================================
# PassMark + SocWatch + EMON Automation (Linux)
#
# PassMark PerformanceTest's Linux build is a plain blocking CLI binary (no
# custom-drawn GUI to automate, unlike Windows), so completion detection is
# trivial: the process returns when all sub-tests are done. Telemetry
# duration is therefore naturally dynamic - start EMON + SocWatch right
# before launching PassMark, stop them the instant PassMark's foreground
# process returns.
#
# Stop semantics intentionally mirror the Windows script's safety notes:
#   - EMON is stopped via the official, documented "emon -stop" command
#     (blocks until the collector flushes and exits cleanly). Never kill -9.
#   - SocWatch is stopped via a graceful SIGINT (the Linux equivalent of the
#     Windows Ctrl-C trick; SocWatch itself prints "Use Ctrl-C to stop
#     collection" and exits cleanly on SIGINT). Never kill -9.
#   - SocWatch is still launched with a generous -t safety-cap timeout in
#     case the SIGINT delivery/detection ever fails - this is a ceiling, not
#     the expected run length.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSMARK_BIN="$SCRIPT_DIR/PerformanceTest_Linux/PerformanceTest/run.sh"
SOCWATCH_DIR="$SCRIPT_DIR/socwatch/socwatch_linux_INTERNAL_v2026.2.2026.2-pre-release_x86_64"
SOCWATCH_ENV="$SOCWATCH_DIR/setup_socwatch_env.sh"
EMON_VARS="/opt/intel/emon/sep_vars.sh"

# ---------------------------------------------------------------------------
# Defaults (mirrors run_combined_test.ps1)
# ---------------------------------------------------------------------------
DURATION="Short"          # Short | Medium | Long | VeryLong
ITERATIONS=1              # 1 to 100
PROCESSES="$(nproc --all)"
SUITE="All"               # CPU | Memory | All
CONFIRM=0                 # 0 = fully automatic, 1 = ask Y/N before running
SOCWATCH_SAFETY_CAP=900   # seconds; hard ceiling only, not the expected run length
POWER_PLAN="HighPerformance"  # AsIs | Balanced | HighPerformance | PowerSaver

EMON_EVENTS="INST_RETIRED.ANY, CPU_CLK_UNHALTED.REF_TSC, LONGEST_LAT_CACHE.MISS"
SOCWATCH_FEATURES=(cpu-wakeup sys-memory cpu-freq uncore-freq cpu-ipc cache \
  os-cpu-pstate hw-cpu-pstate pkg-pwr cpu-pstate gfx-pstate sa-freq pwr-limits cpu-cstate)

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -d, --duration <Short|Medium|Long|VeryLong>   Test duration (default: Short)
  -i, --iterations <1-100>                      Test iterations (default: 1)
  -p, --processes <1-1024>                       Test processes (default: $(nproc --all), all CPU threads)
  -r, --suite <CPU|Memory|All>                  Suite to run (default: All)
  -c, --confirm                                  Ask Y/N before running (default: fully automatic)
  -s, --socwatch-safety-cap <seconds>           SocWatch safety ceiling (default: 900)
  -w, --power-plan <AsIs|Balanced|HighPerformance|PowerSaver>
                                                  Power profile during the benchmark (default: HighPerformance).
                                                  Original profile is always restored afterward, even on error.
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
    -s|--socwatch-safety-cap) SOCWATCH_SAFETY_CAP="$2"; shift 2 ;;
    -w|--power-plan) POWER_PLAN="$2"; shift 2 ;;
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

case "$POWER_PLAN" in
  AsIs|Balanced|HighPerformance|PowerSaver) ;;
  *) echo "Invalid --power-plan: $POWER_PLAN (expected AsIs|Balanced|HighPerformance|PowerSaver)" >&2; exit 1 ;;
esac

if [ ! -x "$PASSMARK_BIN" ]; then
  echo "ERROR: PassMark wrapper not found/executable at $PASSMARK_BIN" >&2; exit 1
fi
if [ ! -f "$SOCWATCH_ENV" ]; then
  echo "ERROR: SocWatch env script not found at $SOCWATCH_ENV" >&2; exit 1
fi
if [ ! -f "$EMON_VARS" ]; then
  echo "ERROR: EMON sep_vars.sh not found at $EMON_VARS (is EMON installed at /opt/intel/emon?)" >&2; exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="$SCRIPT_DIR/Results/$TIMESTAMP"
SOC_DIR="$RESULTS_DIR/socwatch"
mkdir -p "$RESULTS_DIR" "$SOC_DIR"

EMON_CSV="$RESULTS_DIR/emon.csv"
SOC_PREFIX="$SOC_DIR/socwatch"
PASSMARK_OUT="$RESULTS_DIR/PassMark_PerfRes.txt"
SYSTEM_INFO="$RESULTS_DIR/system_info.txt"

echo "============================================================"
echo " PassMark + EMON + SocWatch combined run (Linux)"
echo "============================================================"
echo " Duration            : $DURATION (-d $D_FLAG)"
echo " Iterations          : $ITERATIONS"
echo " Processes           : $PROCESSES"
echo " Suite               : $SUITE (-r $R_FLAG)"
echo " SocWatch safety cap : ${SOCWATCH_SAFETY_CAP}s"
echo " Power plan          : $POWER_PLAN"
echo " Results             : $RESULTS_DIR"
echo "============================================================"

if [ "$CONFIRM" -eq 1 ]; then
  read -r -p "Proceed with the combined benchmark + telemetry run? (Y/N) " answer
  case "$answer" in
    [Yy]*) ;;
    *) echo "Aborted - nothing was run."; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Power plan handling (Linux equivalent of the Windows -PowerPlan option, via
# power-profiles-daemon). "Balanced" (the usual Linux default, like Windows)
# throttles for power savings and can make benchmark runs inconsistent
# run-to-run; "HighPerformance" (-> "performance") removes that throttling.
# The original profile is always restored afterward, even on a mid-run error,
# via a trap - same safety net as the Windows script.
# ---------------------------------------------------------------------------
ORIGINAL_PROFILE="$(powerprofilesctl get 2>/dev/null || true)"
case "$POWER_PLAN" in
  AsIs) TARGET_PROFILE="" ;;
  Balanced) TARGET_PROFILE="balanced" ;;
  HighPerformance) TARGET_PROFILE="performance" ;;
  PowerSaver) TARGET_PROFILE="power-saver" ;;
esac

restore_power_plan() {
  if [ -n "$TARGET_PROFILE" ] && [ -n "$ORIGINAL_PROFILE" ]; then
    current="$(powerprofilesctl get 2>/dev/null || true)"
    if [ "$current" != "$ORIGINAL_PROFILE" ]; then
      sudo powerprofilesctl set "$ORIGINAL_PROFILE" 2>/dev/null
      echo "  Power profile restored to: $ORIGINAL_PROFILE"
    fi
  fi
}
trap restore_power_plan EXIT

if [ -n "$TARGET_PROFILE" ]; then
  echo "[1/6] Setting power profile to $POWER_PLAN ($TARGET_PROFILE); original was: $ORIGINAL_PROFILE"
  sudo powerprofilesctl set "$TARGET_PROFILE"
else
  echo "[1/6] Power profile left as-is ($ORIGINAL_PROFILE)."
fi

# ---------------------------------------------------------------------------
# Step: capture test-bed configuration snapshot (same intent as Windows'
# system_info.txt: CPU, RAM, BIOS, OS, GPU, power-plan-equivalent context).
# ---------------------------------------------------------------------------
echo "[2/6] Capturing system_info.txt..."
{
  echo "=== CPU ==="
  lscpu
  echo ""
  echo "=== Memory ==="
  free -h
  sudo dmidecode -t memory 2>/dev/null | grep -E "Size:|Speed:|Manufacturer:|Locator:" 
  echo ""
  echo "=== BIOS ==="
  sudo dmidecode -t bios 2>/dev/null | grep -E "Vendor:|Version:|Release Date:"
  echo ""
  echo "=== OS ==="
  uname -a
  lsb_release -a 2>/dev/null
  echo ""
  echo "=== GPU ==="
  lspci | grep -iE "vga|3d|display"
  echo ""
  echo "=== Power plan ==="
  echo "Original: $ORIGINAL_PROFILE | During run: ${TARGET_PROFILE:-$ORIGINAL_PROFILE (AsIs)}"
} > "$SYSTEM_INFO" 2>&1

# ---------------------------------------------------------------------------
# Step: start telemetry right before the real workload begins. EMON loops
# forever (-t1 -l0, 1-second samples, matching the Windows reference args)
# until stopped via "emon -stop"; SocWatch runs under a safety-cap timeout
# until stopped via SIGINT.
# ---------------------------------------------------------------------------
echo "[3/6] Starting EMON + SocWatch telemetry..."

sudo bash -c "source '$EMON_VARS' && emon -C '$EMON_EVENTS' -t1 -l0 -f '$EMON_CSV'" \
  > "$RESULTS_DIR/emon_stdout.log" 2>&1 &
EMON_WRAPPER_PID=$!
sleep 2

SOC_FEATURE_ARGS=()
for feat in "${SOCWATCH_FEATURES[@]}"; do SOC_FEATURE_ARGS+=(-f "$feat"); done
sudo bash -c "source '$SOCWATCH_ENV' && exec socwatch ${SOC_FEATURE_ARGS[*]} -o '$SOC_PREFIX' -t $SOCWATCH_SAFETY_CAP" \
  > "$RESULTS_DIR/socwatch_stdout.log" 2>&1 &
SOC_WRAPPER_PID=$!
sleep 2
echo "  EMON wrapper PID=$EMON_WRAPPER_PID  SocWatch wrapper PID=$SOC_WRAPPER_PID"

# ---------------------------------------------------------------------------
# Step 3: run PassMark in the foreground - this IS the completion signal;
# no dialog polling needed since the Linux binary just blocks until done.
# ---------------------------------------------------------------------------
echo "[4/6] Running PassMark benchmark (blocking until complete)..."
"$PASSMARK_BIN" -d "$D_FLAG" -i "$ITERATIONS" -p "$PROCESSES" -r "$R_FLAG" \
  | tee "$PASSMARK_OUT"
echo "  Benchmark finished."

# ---------------------------------------------------------------------------
# Step 4: gracefully stop telemetry the instant PassMark returns.
# Never force-kill either tool (see Windows README safety notes - a forced
# SocWatch kill has previously been correlated with a CRITICAL_PROCESS_DIED
# BSOD on Windows; the same discipline is kept here out of caution).
# ---------------------------------------------------------------------------
echo "[5/6] Stopping telemetry (EMON: official -stop, SocWatch: graceful SIGINT)..."
sudo bash -c "source '$EMON_VARS' && emon -stop" > "$RESULTS_DIR/emon_stop.log" 2>&1
echo "  EMON stop issued."

if kill -0 "$SOC_WRAPPER_PID" 2>/dev/null; then
  sudo kill -INT "$SOC_WRAPPER_PID"
  echo "  SocWatch SIGINT sent (wrapper PID $SOC_WRAPPER_PID; sudo forwards it to the real socwatch process)."
else
  echo "  SocWatch already exited on its own."
fi

echo "  Waiting for EMON/SocWatch to finish flushing output..."
wait "$EMON_WRAPPER_PID" 2>/dev/null
wait "$SOC_WRAPPER_PID" 2>/dev/null

# EMON/SocWatch ran as root (driver access), so their output files are
# root-owned; hand them back to the invoking user so results are readable
# without sudo.
sudo chown -R "$(id -u):$(id -g)" "$RESULTS_DIR"

echo "[6/6] Done."
echo "============================================================"
echo " Results saved to: $RESULTS_DIR"
echo "   - PassMark_PerfRes.txt"
echo "   - emon.csv"
echo "   - socwatch/ (socwatch*.csv)"
echo "   - system_info.txt"
echo "============================================================"
