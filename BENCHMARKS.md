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
| Packed dual-lane CLHash (`-O3`, ThinLTO, jump tables) | 10 | **22.95 MH/s** |

The packed dual-lane result processed 183,910,193 hashes in 8.012 seconds. It is
51.7% faster than the previously recorded 15.13 MH/s portable result. This is
an iteration benchmark, not a sustained thermal result.

The main gain comes from explicitly interleaving two independent CLHash states,
which lets Apple silicon overlap the loop-carried PMULL, AES, vector-multiply,
random-load, and division latency. Each worker owns two mutable 8,832-byte keys
and restores their touched entries from one immutable pristine key. Packing the
two touched indices into one 32-bit log entry removes the old saved-value stores.
Deterministic full-hash vectors, scalar-versus-dual differential tests, and
complete key-restoration checks pass.

Apple clang normally lowers CLHash's random eight-way switch to a tree of three
unpredictable conditional branches. The default build forces AArch64 jump-table
lowering, which measured 7.0% faster in balanced fixed-work dual-kernel tests.
The dual API also exposes real no-alias relationships between both keys,
buffers, restore logs, and output so the compiler can schedule the independent
lanes more aggressively.

On this compiler, `-mcpu=native` resolves the M5 to the newest available
Apple target, `apple-m4`. It did not improve this workload in clean back-to-back
runs, so the portable architecture target remains recommended. Any sustained
thermal comparison should be run only with explicit approval; heat and power
mode can change the best laptop configuration.

The upstream multi-thread nonce-span bug had to be fixed before these numbers
were meaningful. Before the fix, only thread 0 completed a normal batch; later
threads attempted billion-candidate initial scans and aggregate reporting was
zero. Earlier results collected while those stuck workers were still consuming
CPU were discarded.
