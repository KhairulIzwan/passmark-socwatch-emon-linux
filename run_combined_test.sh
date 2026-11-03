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
POWER_PLAN="performance"  # as-is | balanced | performance | power-saver (matches `powerprofilesctl`)
GOVERNOR="as-is"          # as-is | performance | powersave (cpufreq scaling governor)

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
  -w, --power-plan <as-is|balanced|performance|power-saver>
                                                  Power profile during the benchmark (default: performance),
                                                  i.e. the same names shown by \`powerprofilesctl list\`.
                                                  Original profile is always restored afterward, even on error.
  -g, --governor <as-is|performance|powersave>  CPU cpufreq governor during the benchmark (default: as-is),
                                                  applied on all CPUs after the power profile. Independent of
                                                  -w: the profile sets EPP/platform profile, not the governor.
                                                  Original governor is always restored afterward, even on error.
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
    -g|--governor) GOVERNOR="$2"; shift 2 ;;
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
  as-is|balanced|performance|power-saver) ;;
  *) echo "Invalid --power-plan: $POWER_PLAN (expected as-is|balanced|performance|power-saver)" >&2; exit 1 ;;
esac

case "$GOVERNOR" in
  as-is) ;;
  performance|powersave)
    if ! grep -qw "$GOVERNOR" /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null; then
      echo "Governor '$GOVERNOR' is not available on this system" >&2; exit 1
    fi ;;
  *) echo "Invalid --governor: $GOVERNOR (expected as-is|performance|powersave)" >&2; exit 1 ;;
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
# The sep5/pax drivers are not persistent across reboots; without them EMON
# silently writes no emon.csv.
if [ ! -d /sys/module/sep5 ]; then
  echo "ERROR: EMON sep5 driver is not loaded. Load it with:" >&2
  echo "  sudo /opt/intel/emon/sepdk/src/insmod-sep" >&2
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="$SCRIPT_DIR/Results/$TIMESTAMP"
SOC_DIR="$RESULTS_DIR/socwatch"
mkdir -p "$RESULTS_DIR" "$SOC_DIR"

EMON_CSV="$RESULTS_DIR/emon.csv"
SOC_PREFIX="$SOC_DIR/socwatch"
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
echo " CPU governor        : $GOVERNOR"
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
# power-profiles-daemon). "balanced" (the usual Linux default, like Windows)
# throttles for power savings and can make benchmark runs inconsistent
# run-to-run; "performance" removes that throttling. The original profile is
# always restored afterward, even on a mid-run error, via a trap - same
# safety net as the Windows script.
# ---------------------------------------------------------------------------
ORIGINAL_PROFILE="$(powerprofilesctl get 2>/dev/null || true)"
ORIGINAL_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
if [ "$POWER_PLAN" = "as-is" ]; then
  TARGET_PROFILE=""
else
  TARGET_PROFILE="$POWER_PLAN"
fi

restore_power_plan() {
  if [ -n "$ORIGINAL_GOVERNOR" ] && [ "$GOVERNOR" != "as-is" ]; then
    echo "$ORIGINAL_GOVERNOR" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
    echo "  CPU governor restored to: $ORIGINAL_GOVERNOR"
  fi
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
  echo "[1/6] Setting power profile to $TARGET_PROFILE; original was: $ORIGINAL_PROFILE"
  sudo powerprofilesctl set "$TARGET_PROFILE"
else
  echo "[1/6] Power profile left as-is ($ORIGINAL_PROFILE)."
fi

# Governor is applied after the profile so the profile can't override it.
if [ "$GOVERNOR" != "as-is" ]; then
  echo "      Setting CPU governor to $GOVERNOR; original was: $ORIGINAL_GOVERNOR"
  echo "$GOVERNOR" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
  if [ "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" != "$GOVERNOR" ]; then
    echo "ERROR: failed to set governor to $GOVERNOR" >&2; exit 1
  fi
else
  echo "      CPU governor left as-is ($ORIGINAL_GOVERNOR)."
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
  echo ""
  echo "=== CPU power settings (during run) ==="
  echo "Governor requested: $GOVERNOR (original: $ORIGINAL_GOVERNOR)"
  CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq
  echo "Scaling driver: $(cat $CPUFREQ/scaling_driver 2>/dev/null || echo n/a)"
  echo "Governor: $(cat $CPUFREQ/scaling_governor 2>/dev/null || echo n/a)"
  echo "EPP: $(cat $CPUFREQ/energy_performance_preference 2>/dev/null || echo n/a)"
  echo "Platform profile: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo n/a)"
  echo "Max/Min freq (kHz): $(cat $CPUFREQ/scaling_max_freq 2>/dev/null || echo n/a) / $(cat $CPUFREQ/scaling_min_freq 2>/dev/null || echo n/a)"
  echo "Turbo disabled (no_turbo): $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a)"
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
#
# Run it under a real pseudo-terminal via `script`, not a plain pipe/tee.
# PassMark only does its full final curses-style redraw (accurate per-test
# values at fixed on-screen positions) when stdout is a real tty; redirecting
# to a pipe truncates the captured output to the first iteration's snapshot.
# This pty redraw is also unaffected by the PMU contention that otherwise
# breaks PassMark's own results_*.yml write-out while EMON/SocWatch are
# running (see parse_passmark_console.py for the full explanation), which is
# what lets us reliably get real scores even in combined runs.
# ---------------------------------------------------------------------------
echo "[4/6] Running PassMark benchmark (blocking until complete)..."
PASSMARK_START_EPOCH="$(date +%s)"
PASSMARK_RAW="$RESULTS_DIR/passmark_console_raw.log"
script -qefc "'$PASSMARK_BIN' -d $D_FLAG -i $ITERATIONS -p $PROCESSES -r $R_FLAG" "$PASSMARK_RAW" >/dev/null
echo "  Benchmark finished."

# ---------------------------------------------------------------------------
# Step 4: gracefully stop telemetry the instant PassMark returns, BEFORE
# polling for PassMark's results_*.yml below. PassMark's own write-out of that
# file is known to be slightly racy (can land a couple seconds after the
# process returns), and empirically that race is far more likely to fail
# while EMON/SocWatch are still actively sampling all CPUs in the background
# (resource contention with -p == all logical CPUs leaves it no headroom) -
# so free up the CPUs first, then poll for the structured scores.
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

# ---------------------------------------------------------------------------
# Step 6: capture PassMark's structured scores.
#
# Primary source: parse the pty-captured final console redraw
# (passmark_console_raw.log) into results_console_<suite>.yml. This works
# reliably even with EMON/SocWatch active, since it reads values already
# drawn to screen rather than relying on PassMark's own (PMU-contention-
# sensitive) yml writer.
#
# Bonus/fallback: also poll for PassMark's own native results_*.yml (next to
# the binary) for a couple seconds in case it happens to succeed too - its
# filename sorts before results_console_*.yml, so analyze_run.py prefers it
# automatically when both are present.
# ---------------------------------------------------------------------------
SUITE_LOWER="$(echo "$SUITE" | tr '[:upper:]' '[:lower:]')"
CONSOLE_YML="$RESULTS_DIR/results_console_${SUITE_LOWER}.yml"
if python3 "$SCRIPT_DIR/parse_passmark_console.py" "$PASSMARK_RAW" "$CONSOLE_YML"; then
  echo "  PassMark scores parsed from console capture -> $(basename "$CONSOLE_YML")"
else
  echo "  WARNING: Could not parse PassMark scores from console capture." >&2
fi

PASSMARK_DIR="$(dirname "$PASSMARK_BIN")"
shopt -s nullglob
PASSMARK_YML_FOUND=0
for attempt in $(seq 1 3); do
  for yml in "$PASSMARK_DIR"/results_*.yml; do
    if [ "$(stat -c '%Y' "$yml")" -ge "$PASSMARK_START_EPOCH" ]; then
      cp "$yml" "$RESULTS_DIR/"
      PASSMARK_YML_FOUND=1
    fi
  done
  [ "$PASSMARK_YML_FOUND" -eq 1 ] && break
  sleep 1
done
shopt -u nullglob
if [ "$PASSMARK_YML_FOUND" -eq 1 ]; then
  echo "  Bonus: PassMark's own native results_*.yml was also captured."
fi

# EMON/SocWatch ran as root (driver access), so their output files are
# root-owned; hand them back to the invoking user so results are readable
# without sudo.
sudo chown -R "$(id -u):$(id -g)" "$RESULTS_DIR"

echo "[6/6] Done."
echo "============================================================"
echo " Results saved to: $RESULTS_DIR"
echo "   - passmark_console_raw.log (raw pty capture) + results_console_${SUITE_LOWER}.yml (parsed scores)"
echo "   - results_*.yml (PassMark's own native scores, if it also succeeded)"
echo "   - emon.csv"
echo "   - socwatch/ (socwatch*.csv)"
echo "   - system_info.txt"
echo "============================================================"
