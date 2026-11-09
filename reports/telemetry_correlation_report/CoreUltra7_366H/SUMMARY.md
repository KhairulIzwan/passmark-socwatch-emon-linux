# Test Summary

Quick overview of the platform, silicon and results. Details, plots and
correlations: [TELEMETRY_CORRELATION_REPORT.md](TELEMETRY_CORRELATION_REPORT.md).

## Platform

Metric correction: the column previously labeled IPC is instructions per
unhalted reference cycle (`INST_RETIRED.ANY / CPU_CLK_UNHALTED.REF_TSC`),
not instructions per actual core cycle. Values are unchanged. The archived
EMON captures lack actual-cycle counters, so conventional IPC is unavailable.
Derived CSVs now use `instructions_per_ref_cycle` and
`avg_instructions_per_ref_cycle`; run averages equally weight valid
core/sample ratios and exclude zero-reference samples.

| Item | Value |
|---|---|
| Platform | Panther Lake Client Platform (PTL-UH DDR5 Embedded CRB) |
| CPU (Si) | Intel Core Ultra 7 366H, 16 cores / 16 threads (1 thread per core), 1 socket |
| CPU frequency range | 400 MHz - 4900 MHz (4800 MHz max in cpufreq) |
| Memory | 64 GB: 2 x 32 GB DDR5 SK Hynix @ 6400 MT/s (6 slots empty) |
| BIOS | PTLPFWI1.R00.3515.D56.2601280733 (01/28/2026) |
| GPU | Intel Corporation Device b0a0 (00:02.0) |
| OS / kernel | Ubuntu 24.04.5 LTS, Linux 6.18-intel |
| CPU frequency driver | `intel_pstate` |
| Tools | PassMark PerformanceTest (Linux CLI), EMON V11.61, SoC Watch v2026.2 pre-release |

## Test setup

All runs: `./run_combined_test.sh -d Short -i 3 -r All` (PassMark All suite,
Short duration, 3 iterations, all 16 processes) with EMON + SoC Watch running.
Date: 2026-11-04. `-w` is the `powerprofilesctl` profile; `-g` is the CPU
governor (`as-is` = left at `powersave`).

## Results

| Run | `-w` profile | Governor | CPU Mark | Memory Mark | Avg pkg power | Avg active freq | instructions/ref cycle |
|---|---|---|---|---|---|---|---|
| 20261104_073216 | performance | powersave * | 30803 | 3769 | 21.6 W | 2950 MHz | 1.64 |
| 20261104_080450 | performance | powersave | 30714 | 3790 | 21.5 W | 2947 MHz | 1.63 |
| 20261104_081815 | performance | powersave | 30678 | 3757 | 21.6 W | 2943 MHz | 1.62 |
| 20261104_075827 | performance | performance | 29904 | 3755 | 21.6 W | 2928 MHz | 1.57 |
| 20261104_081132 | performance | performance | 29867 | 3775 | 21.7 W | 2933 MHz | 1.58 |
| 20261104_082458 | performance | performance | 29903 | 3758 | 21.7 W | 2935 MHz | 1.58 |
| 20261104_073659 | power-saver | powersave * | 14610 | 1512 | 5.6 W | 1234 MHz | 0.70 |

\* Governor was not recorded for these two runs (made before the script
captured it); it was `powersave`, confirmed by switching the profiles
afterwards (the profile does not change the governor).

### Averages

| Config | n | CPU Mark | Memory Mark |
|---|---|---|---|
| `-w performance`, governor `powersave` | 3 | 30732 | 3772 |
| `-w performance -g performance` | 3 | 29891 | 3763 |
| `-w power-saver`, governor `powersave` | 1 | 14610 | 1512 |

## Key findings

- **Power profile matters a lot.** `power-saver` scored about 52% lower on CPU
  Mark and 60% lower on Memory Mark than `performance`, at about 26% of the
  package power (5.6 W vs 21.6 W).
- **The profile sets EPP and ACPI platform profile, not the governor.**
  `performance` = EPP `performance` / platform `performance`; `power-saver` =
  EPP `power` / platform `low-power`. Governor stays `powersave`.
- **Forcing the `performance` governor did not help**: about 2.7% lower CPU
  Mark (30732 vs 29891) with the same package power and about the same
  frequency; the gap lines up with about 2.5% lower instructions/ref cycle. Memory Mark unchanged.
  The cause of the instructions/ref cycle drop was not investigated.
- Repeat runs of the same config agree within about 0.4%, so the
  governor difference is real; `power-saver` has only one run.

## Updating this summary

Re-run `cross_run_analysis.py Results/`, copy the new report/plots and backing
data into `reports/telemetry_correlation_report/CoreUltra7_366H/` (see the
project README), then update the tables above. Each run
includes raw `emon.csv` and `socwatch/socwatch.csv`, parsed PassMark scores in
`results_console_all.yml`, `system_info.txt`, and the tidy EMON CSV under
`analysis/`. Cross-run CSVs live alongside the plots in `cross_run_analysis/`.
Binary `.sw2` traces and tool logs remain local.
