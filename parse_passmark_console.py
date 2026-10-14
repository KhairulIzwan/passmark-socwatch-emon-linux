#!/usr/bin/env python3
"""
Parse PassMark PerformanceTest's final on-screen console UI (captured via a
real pseudo-terminal, e.g. `script -qefc "<passmark cmd>" raw.log`) and emit a
results_*.yml-compatible scores file.

Why this exists
----------------
PassMark normally writes final scores to results_<suite>.yml in its own
binary directory. That file has no run-id and gets overwritten every run, and
-- more importantly -- when EMON and/or SocWatch are running concurrently
(claiming exclusive hardware PMU counters), PassMark's internal yml-write step
silently fails even though the on-screen values stay correct. Capturing
PassMark under a real pty preserves its full final curses-style redraw
(absolute ANSI cursor-position escape codes), which is unaffected by that PMU
contention. This script extracts those final values and writes them using the
exact same field names PassMark's own yml uses, so downstream analysis
scripts (analyze_run.py / cross_run_analysis.py) work unmodified.
"""
import re
import sys
import yaml
from pathlib import Path

# Map of on-screen sub-test label -> yml field name (matches PassMark's own
# results_*.yml schema).
CPU_FIELD_MAP = {
    "Integer Math": "CPU_INTEGER_MATH",
    "Floating Point Math": "CPU_FLOATINGPOINT_MATH",
    "Prime Numbers": "CPU_PRIME",
    "Sorting": "CPU_SORTING",
    "Encryption": "CPU_ENCRYPTION",
    "Compression": "CPU_COMPRESSION",
    "CPU Single Threaded": "CPU_SINGLETHREAD",
    "Physics": "CPU_PHYSICS",
    "Extended Instructions (SSE)": "CPU_MATRIX_MULT_SSE",
}
MEM_FIELD_MAP = {
    "Database Operations": "ME_ALLOC_S",
    "Memory Read Cached": "ME_READ_S",
    "Memory Read Uncached": "ME_READ_L",
    "Memory Write": "ME_WRITE",
    "Available RAM": "ME_LARGE",
    "Memory Latency": "ME_LATENCY",
    "Memory Threaded": "ME_THREADED",
}

ESC_POS_RE = re.compile(r"\x1b\[(\d+);(\d+)H([^\x1b]*)")
PLACEHOLDERS = {"incomplete", "queued", "running", ""}


def strip_control(s: str) -> str:
    return re.split(r"[\x00-\x1f]", s)[0].strip()


def first_number(s: str):
    m = re.match(r"[-+]?\d*\.?\d+", s)
    return float(m.group(0)) if m else None


def parse_console_capture(raw_bytes: bytes):
    text = raw_bytes.decode("utf-8", errors="replace")

    # 1) Track, per (row, col), both the FIRST and LAST value ever written.
    #    The last write represents the final/completed state; the first write
    #    is always PassMark's initial placeholder ("Incomplete"/"0.0 .../s"
    #    etc). Comparing the two lets us detect sub-tests that were never
    #    actually run (their value never changes from that initial
    #    placeholder) vs. ones that completed.
    first_val = {}
    last_val = {}
    first_row_order = []  # order rows at col 36 are first touched
    for m in ESC_POS_RE.finditer(text):
        row, col = int(m.group(1)), int(m.group(2))
        val = strip_control(m.group(3))
        key = (row, col)
        if key not in first_val:
            first_val[key] = val
            if col == 36:
                first_row_order.append(row)
        last_val[key] = val

    # 2) The sub-test names are printed as plain scrolled text (no per-line
    #    escape codes) right after the "CPU Mark:"/"Memory Mark:" headers, in
    #    on-screen order. Extract them from the plain text so the row->name
    #    mapping is label-driven, not hardcoded.
    plain_text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "\n", text)
    cpu_start = plain_text.find("CPU Mark:")
    mem_start = plain_text.find("Memory Mark:")
    if cpu_start == -1 or mem_start == -1:
        raise ValueError("Could not locate CPU Mark / Memory Mark sections")
    cpu_names = [l.strip() for l in plain_text[cpu_start:mem_start].splitlines() if l.strip() in CPU_FIELD_MAP]
    mem_section = plain_text[mem_start:]
    mem_names = []
    for l in mem_section.splitlines()[1:]:
        name = l.strip()
        if name in MEM_FIELD_MAP:
            mem_names.append(name)
        elif name == "" or name.endswith("Mark:"):
            if mem_names:
                break

    # 3) Determine the actual on-screen ROW for each field. PassMark's own
    #    "CPU Mark:"/"Memory Mark:" header text is not always escape-anchored
    #    (observed to vary between runs), so don't rely on it. Instead use
    #    the order in which col-36 (value column) positions are FIRST
    #    touched in the stream -- that placeholder-initialization pass is
    #    always written top-to-bottom (composite, then each sub-test, in
    #    on-screen order), which is a reliable anchor regardless of header
    #    formatting quirks.
    if len(first_row_order) < 2:
        raise ValueError("Could not locate any PassMark value rows in capture")

    cpu_rows = first_row_order[: 1 + len(cpu_names)]
    remaining_rows = first_row_order[1 + len(cpu_names):]
    mem_rows = remaining_rows[: 1 + len(mem_names)]

    results = {}

    def extract(row, col=36):
        raw = last_val.get((row, col))
        if raw is None:
            return None
        raw = raw.strip()
        if raw.lower() in PLACEHOLDERS:
            return None
        # Sub-test was never actually run if its value never changed from
        # the initial placeholder PassMark wrote at start-up.
        if raw == first_val.get((row, col), "").strip():
            return None
        return first_number(raw)

    if cpu_rows:
        summ_cpu = extract(cpu_rows[0])
        if summ_cpu is not None:
            results["SUMM_CPU"] = summ_cpu
        for row, name in zip(cpu_rows[1:], cpu_names):
            num = extract(row)
            if num is not None:
                results[CPU_FIELD_MAP[name]] = num

    if mem_rows:
        summ_me = extract(mem_rows[0])
        if summ_me is not None:
            results["SUMM_ME"] = summ_me
        for row, name in zip(mem_rows[1:], mem_names):
            num = extract(row)
            if num is not None:
                results[MEM_FIELD_MAP[name]] = num

    incomplete = "SUMM_CPU" not in results and "SUMM_ME" not in results
    return results, incomplete


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <raw_pty_capture_file> <output_yml_path>", file=sys.stderr)
        sys.exit(2)

    raw_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    raw_bytes = raw_path.read_bytes()
    results, incomplete = parse_console_capture(raw_bytes)

    if incomplete or not results:
        print("WARNING: PassMark console capture looks incomplete (no final scores found).", file=sys.stderr)
        sys.exit(1)

    doc = {
        "ResultsSource": "console-pty-capture",
        "Results": results,
    }
    out_path.write_text(yaml.safe_dump(doc, sort_keys=False))
    print(f"Wrote {len(results)} score fields to {out_path}")

    # Also print a short human-readable summary to stdout.
    if "SUMM_CPU" in results:
        print(f"  CPU Mark:    {results['SUMM_CPU']}")
    if "SUMM_ME" in results:
        print(f"  Memory Mark: {results['SUMM_ME']}")


if __name__ == "__main__":
    main()
