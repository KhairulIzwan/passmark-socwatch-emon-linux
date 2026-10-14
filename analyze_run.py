"""
analyze_run.py
Parses PassMark + SoCWatch + EMON results from a Results/<timestamp> run folder
(Linux build) and produces telemetry plots.

Adapted from the Windows reference repo's analyze_run.py. Differences:
  - PassMark scores come from the structured results_*.yml PassMark writes
    (PassMark_PerfRes.txt is just the raw live console UI text and has no
    clean final score lines on Linux).
  - Core count / base frequency are read from socwatch.csv's own header
    instead of being hardcoded, since this repo may run on different SKUs.

Usage:
    python3 analyze_run.py Results/20261014_100231
"""
import sys
import re
from pathlib import Path

import yaml
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def detect_system_params(socwatch_path: Path):
    """Pull base frequency (GHz) and logical CPU count straight out of socwatch.csv's header."""
    base_freq_ghz = 3.4
    n_cores = 8
    if socwatch_path.exists():
        text = socwatch_path.read_text(encoding="utf-8", errors="ignore")
        m = re.search(r"CPU Base Operating Frequency \(MHz\):\s*(\d+)", text)
        if m:
            base_freq_ghz = float(m.group(1)) / 1000.0
        m = re.search(r"Total # of logical processors:\s*(\d+)", text)
        if m:
            n_cores = int(m.group(1))
    return base_freq_ghz, n_cores


def parse_emon(emon_path: Path, n_cores: int) -> pd.DataFrame:
    """Parse emon.csv block-sampled counters into a tidy per-sample, per-core DataFrame."""
    with open(emon_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    blocks = []
    current = {}
    for line in lines:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        if line.startswith("=========="):
            if current:
                blocks.append(current)
            current = {}
            continue
        if line.startswith("Version Info"):
            continue
        parts = [p.strip().replace(",", "") for p in line.split("\t") if p.strip() != ""]
        if len(parts) < 2:
            continue
        name = parts[0]
        try:
            vals = [float(v) for v in parts[1:]]
        except ValueError:
            continue
        current[name] = vals

    if current:
        blocks.append(current)

    records = []
    for i, block in enumerate(blocks):
        inst = block.get("INST_RETIRED.ANY")
        reftsc = block.get("CPU_CLK_UNHALTED.REF_TSC")
        miss = block.get("LONGEST_LAT_CACHE.MISS")
        if not inst or not reftsc:
            continue
        interval_ref = inst[0]  # column 0 = interval TSC marker (same for all rows)
        for core in range(n_cores):
            col = core + 1
            if col >= len(inst):
                break
            inst_v = inst[col]
            ref_v = reftsc[col]
            miss_v = miss[col] if miss and col < len(miss) else float("nan")
            records.append({
                "sample": i,
                "core": core,
                "inst_retired": inst_v,
                "ref_tsc": ref_v,
                "cache_miss": miss_v,
                "ipc": inst_v / ref_v if ref_v else float("nan"),
                "cache_miss_per_kinst": (miss_v / inst_v * 1000) if inst_v else float("nan"),
            })
    df = pd.DataFrame(records)
    return df


def add_freq_column(df: pd.DataFrame, base_freq_ghz: float) -> pd.DataFrame:
    if df.empty:
        return df
    interval_by_sample = df.groupby("sample")["ref_tsc"].transform("max")
    df = df.copy()
    df["freq_ghz"] = (df["ref_tsc"] / interval_by_sample) * base_freq_ghz
    return df


def parse_socwatch_table(lines, header_idx):
    """Parse a simple 'C-State, col1, col2, ...' table starting at header_idx."""
    header = [h.strip() for h in lines[header_idx].split(",")]
    data = []
    i = header_idx + 1
    while i < len(lines) and lines[i].strip() and "," in lines[i]:
        parts = [p.strip() for p in lines[i].split(",")]
        if len(parts) == len(header):
            data.append(parts)
        i += 1
    df = pd.DataFrame(data, columns=header)
    for c in df.columns[1:]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def parse_socwatch_summaries(socwatch_path: Path):
    with open(socwatch_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    lines = [l.rstrip("\n") for l in lines]

    tables = {}
    for idx, line in enumerate(lines):
        if line.startswith("C-State, CPU/Package_0 Residency"):
            title = next((lines[j] for j in range(idx - 1, max(idx - 6, 0), -1) if "Summary" in lines[j]),
                         f"table_{idx}")
            tables[title] = parse_socwatch_table(lines, idx)
    return tables


def parse_passmark_yaml(run_dir: Path):
    """Find whichever results_*.yml PassMark wrote (results_all/cpu/memory.yml) and return its scores."""
    yml_files = sorted(run_dir.glob("results_*.yml"))
    if not yml_files:
        return {}
    with open(yml_files[0], "r", encoding="utf-8", errors="ignore") as f:
        data = yaml.safe_load(f)
    return (data or {}).get("Results", {})


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 analyze_run.py <run_folder>")
        sys.exit(1)

    run_dir = Path(sys.argv[1])
    out_dir = run_dir / "analysis"
    out_dir.mkdir(exist_ok=True)

    emon_path = run_dir / "emon.csv"
    socwatch_path = run_dir / "socwatch" / "socwatch.csv"

    base_freq_ghz, n_cores = detect_system_params(socwatch_path)
    print(f"Detected: base_freq={base_freq_ghz}GHz, logical_cpus={n_cores}")

    print(f"Parsing emon.csv from {emon_path} ...")
    emon_df = parse_emon(emon_path, n_cores)
    emon_df = add_freq_column(emon_df, base_freq_ghz)
    emon_df.to_csv(out_dir / "emon_timeseries_tidy.csv", index=False)
    print(f"  -> {len(emon_df)} rows, {emon_df['sample'].nunique() if not emon_df.empty else 0} samples")

    print("Parsing socwatch.csv summaries ...")
    soc_tables = parse_socwatch_summaries(socwatch_path)
    for name, df in soc_tables.items():
        print(f"  Found table: {name} ({df.shape[0]} rows)")

    print("Parsing PassMark scores (results_*.yml) ...")
    scores = parse_passmark_yaml(run_dir)
    for k, v in scores.items():
        print(f"  {k}: {v}")

    if emon_df.empty:
        print("WARNING: no emon samples parsed; skipping EMON-based plots.")
    else:
        avg_freq = emon_df.groupby("sample")["freq_ghz"].mean()
        avg_ipc = emon_df.groupby("sample")["ipc"].mean()
        avg_miss = emon_df.groupby("sample")["cache_miss_per_kinst"].mean()

        fig, axes = plt.subplots(3, 1, figsize=(12, 10), sharex=True)
        axes[0].plot(avg_freq.index, avg_freq.values, color="tab:blue")
        axes[0].set_ylabel("Avg Freq (GHz)")
        axes[0].set_title(f"Average CPU Frequency Across {n_cores} Logical CPUs Over Time")
        axes[0].grid(True, alpha=0.3)

        axes[1].plot(avg_ipc.index, avg_ipc.values, color="tab:green")
        axes[1].set_ylabel("Avg IPC")
        axes[1].set_title("Average IPC (Instructions per Cycle) Over Time")
        axes[1].grid(True, alpha=0.3)

        axes[2].plot(avg_miss.index, avg_miss.values, color="tab:red")
        axes[2].set_ylabel("LLC Misses / 1k Instr")
        axes[2].set_xlabel("Sample # (~1 sample/sec)")
        axes[2].set_title("Average Last-Level Cache Miss Rate Over Time")
        axes[2].grid(True, alpha=0.3)

        fig.tight_layout()
        fig.savefig(out_dir / "01_timeseries_overview.png", dpi=150)
        plt.close(fig)

        pivot = emon_df.pivot(index="core", columns="sample", values="freq_ghz")
        fig, ax = plt.subplots(figsize=(14, 5))
        im = ax.imshow(pivot.values, aspect="auto", cmap="viridis",
                        extent=[0, pivot.shape[1], n_cores, 0])
        ax.set_xlabel("Sample # (~1 sample/sec)")
        ax.set_ylabel("Logical CPU")
        ax.set_title("Per-Core Frequency Heatmap (GHz)")
        fig.colorbar(im, ax=ax, label="GHz")
        fig.tight_layout()
        fig.savefig(out_dir / "02_per_core_freq_heatmap.png", dpi=150)
        plt.close(fig)

    n_tables = len(soc_tables)
    if n_tables:
        fig, axes = plt.subplots(n_tables, 1, figsize=(10, 4 * n_tables))
        if n_tables == 1:
            axes = [axes]
        for ax, (name, df) in zip(axes, soc_tables.items()):
            pct_cols = [c for c in df.columns if "(%)" in c]
            if not pct_cols or df.empty:
                continue
            df.set_index(df.columns[0])[pct_cols].plot(kind="bar", ax=ax)
            ax.set_title(name)
            ax.set_ylabel("Residency (%)")
            ax.tick_params(axis="x", rotation=0)
        fig.tight_layout()
        fig.savefig(out_dir / "03_cstate_residency.png", dpi=150)
        plt.close(fig)

    if scores:
        numeric_scores = {k: v for k, v in scores.items() if isinstance(v, (int, float)) and k != "Results Complete"}
        if numeric_scores:
            names = list(numeric_scores.keys())
            vals = list(numeric_scores.values())
            fig, ax = plt.subplots(figsize=(10, 8))
            ax.barh(names, vals, color="tab:purple")
            ax.set_xlabel("Score")
            ax.set_title("PassMark Sub-Test Scores")
            ax.invert_yaxis()
            fig.tight_layout()
            fig.savefig(out_dir / "04_passmark_scores.png", dpi=150)
            plt.close(fig)

    print(f"\nDone. Plots and tidy CSV written to: {out_dir}")


if __name__ == "__main__":
    main()
