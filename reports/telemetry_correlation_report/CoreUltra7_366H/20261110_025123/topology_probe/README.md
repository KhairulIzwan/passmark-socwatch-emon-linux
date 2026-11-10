# PassMark CPU Topology Probe

Separate diagnostic run from the one-iteration CPU+Memory pilot. The command
used the available Linux PerformanceTest binary with the CPU suite, Short
duration, one iteration and 16 processes:

```bash
PerformanceTest_Linux_x86-64 -r 1 -d 1 -i 1 -p 16 -debug
```

`PerformancetestDebug.log` reports 16 logical CPUs, one thread per core, four
logical P-cores and 12 logical E-cores, but sets `logical_per_pcore=2` and
`logical_per_ecore=1`. The console consequently labels the processor as 14
cores. The debug log also shows most CPU tests using 16 threads, while
`Primes Cross Platform` uses 14. This records the observed detector/test
behavior; it does not establish why PassMark chooses that topology heuristic.

A separate successful `strace -f -e trace=openat` run recorded reads of
`/proc/cpuinfo`, `/sys/devices/system/cpu/online`, and per-CPU sibling topology
files for CPUs 0-15. It confirms the test process queries all 16 OS CPU entries,
but does not reveal the reason for the displayed 14-core count.