# PassMark + SocWatch + EMON Automation (Linux)

Automated Bash scripts that drive **PassMark PerformanceTest (Linux CLI build)**
end-to-end, with optional **EMON + SoC Watch** telemetry capture that starts and
stops dynamically to match the actual benchmark run time.

Unlike the Windows version of this project (which has to drive PassMark's
custom-drawn GUI via raw Win32 `PostMessage`/`SendMessage` calls, since
PassMark's UI there isn't exposed via standard UI Automation), the Linux
PassMark PerformanceTest build is a plain **blocking CLI binary** - it runs the
selected suite(s) and exits on its own. No window automation or dialog polling
is needed at all; completion detection is simply "the process returned".

Scripts provided:

| Script | Purpose |
|---|---|
| `run_passmark_auto.sh` | Standalone PassMark automation only (no telemetry). |
| `run_combined_test.sh` | PassMark automation **plus** EMON + SocWatch telemetry capture, dynamically started/stopped to match the actual benchmark run time, plus power-plan handling. |
| `parse_passmark_console.py` | Parses PassMark's final on-screen console state (captured via a real pseudo-terminal) into structured scores. Used automatically by both scripts above - see "How PassMark scores are captured" below. |
| `analyze_run.py` | Per-run analysis: parses `emon.csv`/`socwatch.csv`/PassMark scores for one `Results/<timestamp>/` folder and produces plots + a tidy EMON CSV. |
| `cross_run_analysis.py` | Cross-run analysis: aggregates every run under `Results/`, correlates PassMark scores against telemetry metrics, and writes `TELEMETRY_CORRELATION_REPORT.md`. |

## Requirements

- Linux, with `sudo` access (EMON/SoC Watch need driver access).
- **PassMark PerformanceTest (Linux x86-64 CLI build)** extracted to
  `PerformanceTest_Linux/PerformanceTest/` next to these scripts, with a
  `run.sh` wrapper that handles the `libncurses.so.5`/`libtinfo.so.5` compat
  libs the upstream binary needs on modern distros (e.g. Ubuntu 24.04, which
  dropped `libncurses5`) - see `compat_libs/` in this project's local working
  copy, not committed here (see "What's not in this repo" below).
- **Intel EMON / SEP** installed at `/opt/intel/emon` (`sep_vars.sh` must
  exist there).
- **Intel SoC Watch** extracted to
  `socwatch/socwatch_linux_<version>_x86_64/` next to these scripts, with its
  kernel driver already built (`build_drivers.sh -l -k <kernel build dir>`)
  and loaded.
- `power-profiles-daemon` (`powerprofilesctl`) for the power-plan option
  (combined script only). If unavailable, use `-w as-is` to skip it.
- `util-linux`'s `script` command (present by default on virtually every
  distro) and Python 3 with `pyyaml` installed, for PassMark score capture
  (see "How PassMark scores are captured" below).
- For `analyze_run.py`/`cross_run_analysis.py`: Python 3 with `pandas`,
  `matplotlib`, `scipy`, `tabulate`, and `pyyaml`.

### What's not in this repo

**PassMark, SoC Watch, and EMON themselves are intentionally not committed
here** (see `.gitignore`): PassMark is third-party licensed software, and the
SoC Watch/EMON packages used internally are marked **NDA / INTERNAL USE
ONLY** by Intel. Only the orchestration scripts are version-controlled, same
as the Windows counterpart of this project (which likewise assumes PassMark/
EMON/SoC Watch are already installed on the machine at known paths, not
shipped in the repo). You must obtain and install/extract each tool
separately per your own license/NDA terms, in the directory layout described
above.

## Usage

```bash
# PassMark only
./run_passmark_auto.sh -d Short -i 1

# PassMark + EMON + SocWatch telemetry, high-performance power plan
./run_combined_test.sh -d Short -i 1 -w performance
```

Common parameters:
- `-d, --duration <Short|Medium|Long|VeryLong>`: PassMark test duration preference
  (maps to PassMark's `-d 1..4`).
- `-i, --iterations <1-100>`: number of repeats per sub-test (PassMark `-i`).
- `-p, --processes <1-1024>`: number of PassMark test processes (default: all
  CPU threads via `nproc --all`, matching `run.sh`'s own smart default).
- `-r, --suite <CPU|Memory|All>`: which PassMark suite to run (PassMark `-r 1/2/3`).
- `-c, --confirm`: ask Y/N before starting (default is fully automatic).
- `-s, --socwatch-safety-cap <seconds>` (combined script only, default 900): a
  hard safety ceiling for SocWatch only - **not** the expected run length. In
  normal operation SocWatch is stopped the moment the benchmark finishes via a
  graceful SIGINT; this cap only protects against a stuck/undetected PassMark
  process.
- `-w, --power-plan <as-is|balanced|performance|power-saver>` (combined
  script only, default `performance`): power profile to use **during** the
  benchmark, via `power-profiles-daemon` - the exact same names shown by
  `powerprofilesctl list` on this machine, so there's no Windows-style
  renaming to translate in your head. The original profile is always
  restored afterward (even on a mid-run error, via a `trap` safety net).
  `balanced` (the usual Linux default) throttles for power savings and can
  make benchmark runs inconsistent run-to-run; `performance` removes that
  throttling.

Results are written to a timestamped folder inside the project itself, e.g.
`Results/<yyyyMMdd_HHmmss>/` (next to the script), containing
`passmark_console_raw.log` (raw pty capture), `results_console_<suite>.yml`
(parsed PassMark scores - see below), `emon.csv`, `socwatch/socwatch.csv`/
`.sw2`, and `system_info.txt` (combined script only). `Results/` is
git-ignored, so run output is never committed/pushed - only the
scripts/docs are version-controlled.

### Test-bed configuration snapshot (`system_info.txt`, combined script only)
Every run of `run_combined_test.sh` captures a `system_info.txt` into the
results folder with the CPU model/cores/threads, installed RAM
(size/speed/manufacturer per module via `dmidecode`), BIOS version/date, OS
build, GPU model, and which power plan was active originally vs. during the
run - the baseline hardware/software configuration info needed to make sense
of (and reproduce) a given benchmark's numbers.

## How it works

### Completion detection
PassMark's Linux CLI build is a blocking process: `run_combined_test.sh` runs
it in the foreground and simply waits for it to return - that return **is**
the completion signal, no dialog/window polling required.

### How PassMark scores are captured

PassMark normally writes its final structured scores to a `results_<suite>.yml`
file next to its own binary. In practice this turned out to be unreliable for
this project's purposes:

- That file has **no run-id and is overwritten every invocation** - it must be
  copied out immediately, and both scripts still try to do so (as a bonus; see
  below).
- Piping PassMark's output through a plain pipe/redirect (`| tee foo.txt`)
  **truncates the captured console text to the first iteration's snapshot**
  - PassMark only does its full final redraw when stdout is a real TTY.
- More importantly, **when EMON and/or SocWatch are running concurrently**,
  they claim exclusive hardware PMU (performance-monitor-counter) registers
  via their kernel drivers. PassMark appears to read those same counters
  internally, and under that contention its `results_*.yml` **write step
  silently fails** - even though the on-screen values stay correct throughout.
  This was confirmed by extensive isolated testing (reduced EMON event sets,
  SocWatch alone, reordering telemetry-stop timing, etc. all still broke the
  yml write whenever either tool was active).

**The fix:** both scripts run PassMark under a real pseudo-terminal via
`script -qefc "<passmark cmd>" passmark_console_raw.log`. PassMark then does a
full, accurate final screen redraw using absolute ANSI cursor-position escape
codes (`\x1b[<row>;<col>H<value>`) - and this redraw is **unaffected by
EMON/SocWatch PMU contention** (confirmed with both tools running
concurrently, across multiple iteration counts). `parse_passmark_console.py`
extracts those final on-screen values - matching them to PassMark's own field
names (`SUMM_CPU`, `CPU_INTEGER_MATH`, etc.) by using the order sub-test
value positions are first touched in the stream, not by hardcoding row
numbers - and writes them to `results_console_<suite>.yml` in the run's
results folder, in the exact same schema as PassMark's native yml. A
sub-test whose displayed value never changes from its startup placeholder
(e.g. Memory Latency/Threaded tests PassMark sometimes skips for shorter
durations) is correctly omitted rather than reported as a false zero.

Both scripts also still poll briefly for PassMark's own native
`results_<suite>.yml` as a bonus/fallback (its filename sorts alphabetically
before `results_console_*.yml`, so `analyze_run.py` prefers it automatically
on the rare occasion it succeeds) - but the console-parsed file is the
reliable, primary source of scores for combined runs.

### Telemetry start/stop
Telemetry duration is **dynamic, not a fixed/guessed timer**, same intent as
the Windows script:
1. EMON (`emon -C "..." -t1 -l0 -f emon.csv`) and SocWatch (`socwatch -f ...
   -o socwatch -t <SafetyCap>`) are started right before PassMark is launched.
2. EMON loops forever (`-l0`, 1-second samples) until stopped; SocWatch
   collects the same 14 telemetry channels as the Windows reference profile
   (`cpu-wakeup`, `sys-memory`, `cpu-freq`, `uncore-freq`, `cpu-ipc`, `cache`,
   `os-cpu-pstate`, `hw-cpu-pstate`, `pkg-pwr`, `cpu-pstate`, `gfx-pstate`,
   `sa-freq`, `pwr-limits`, `cpu-cstate`) under a generous safety-cap timeout;
   neither is expected to hit its own natural stopping point.
3. The instant PassMark's process returns:
   - **EMON** is stopped via the official, documented `emon -stop` command
     (blocks until the collector flushes and exits cleanly).
   - **SocWatch** is stopped via a graceful **SIGINT** (the Linux equivalent
     of the Windows Ctrl-C trick; SocWatch itself prints "Use Ctrl-C to stop
     collection" and exits cleanly on SIGINT). The signal is sent to the
     backgrounded `sudo` wrapper PID - `sudo` forwards it to the real
     `socwatch` child, confirmed to produce a clean "Data written" exit.
   - Neither tool is ever force-killed.
4. EMON/SocWatch run under `sudo` for driver access, so their output files
   are root-owned; the script `chown`s the whole results folder back to the
   invoking user at the end so results are readable without `sudo`.

## Analysis scripts

After one or more runs exist under `Results/`:

```bash
# Per-run deep-dive: plots + tidy telemetry CSV for one run
python3 analyze_run.py Results/<timestamp>/

# Cross-run correlation report across every run under Results/
python3 cross_run_analysis.py Results/
```

`analyze_run.py` parses `emon.csv` (auto-detecting core count/base frequency
from `socwatch.csv`'s header), `socwatch.csv`'s summary tables, and PassMark
scores (preferring a native `results_*.yml` if present, otherwise
`results_console_*.yml`), writing 4 plots and `emon_timeseries_tidy.csv` to
`<run>/analysis/`.

`cross_run_analysis.py` aggregates every run folder into one table, computes
Pearson correlations between PassMark scores and telemetry metrics (treating
each run as one observation), and writes `Results/TELEMETRY_CORRELATION_REPORT.md`
plus supporting plots/CSVs under `Results/cross_run_analysis/`. With only a
handful of runs this is **exploratory/descriptive**, not a statistically
robust regression - treat it as a starting point for repeat-testing, not a
final conclusion.

## Safety notes (read before modifying)

- **Never force-kill SocWatch or EMON mid-collection.** Always use the
  documented graceful stop (`emon -stop` for EMON, SIGINT for SocWatch) -
  same discipline as the Windows script's safety notes, which correlate a
  forced SocWatch kill with a `CRITICAL_PROCESS_DIED` BSOD on Windows.
- **Never run SocWatch interactively/exploratorily just to "check" something**
  without a plan - treat it like any other kernel-driver-backed collection
  tool; only invoke it via the confirmed-safe start/stop patterns in these
  scripts.
- **Don't edit a script file while it's actively executing in another shell.**
  Bash reads script files incrementally from disk; concurrent writes to a
  running script have been observed to corrupt its in-flight read and cause
  spurious syntax errors. Always let a run finish (or stop it) before editing.
- EMON/SocWatch access requires either `sudo` (used by default in these
  scripts) or membership in the driver access group (`vtune` for EMON by
  default) - group changes require a new login session to take effect.

## Known limitations / open items

- SocWatch can take a little while **after** receiving SIGINT to finish
  flushing large collection files before its process actually exits; the
  combined script `wait`s on it rather than proceeding immediately, so this
  does not affect correctness, just total script wall-clock time.
- `dmidecode`-based RAM/BIOS details in `system_info.txt` require `sudo` and
  may be empty/partial on systems where SMBIOS data isn't exposed (e.g. some
  VMs).
