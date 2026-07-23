# Apple-silicon benchmark log

## Apple M5 MacBook Air

Measured 2026-07-22 on macOS 26.5 with Apple clang 21.0.0. These are short
offline VerusHash 2.2.2 runs, not sustained thermal or accepted-share tests.

| Build | Threads | Result |
|---|---:|---:|
| ARMv8 crypto baseline (`-O3`) | 1 | 2.07 MH/s |
| ARMv8 crypto baseline (`-O3`) | 4 | 7.74 MH/s |
| ARMv8 crypto baseline (`-O3`) | 10 | 15.13 MH/s |
| Host-native (`-O3 -mcpu=native`) | 10 | 14.74 MH/s |

On this compiler, `-mcpu=native` resolves the M5 to the newest available
Apple target, `apple-m4`. It did not improve this workload in clean back-to-back
runs, so the portable baseline remains the recommended build. Re-test over
10–20 minutes before choosing a sustained laptop configuration; thermal
throttling can change the ranking.

The upstream multi-thread nonce-span bug had to be fixed before these numbers
were meaningful. Before the fix, only thread 0 completed a normal batch; later
threads attempted billion-candidate initial scans and aggregate reporting was
zero. Earlier results collected while those stuck workers were still consuming
CPU were discarded.
