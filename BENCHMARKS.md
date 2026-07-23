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
| Clean frontend PGO (`-O3`, ThinLTO, jump tables) | 10 | **22.64 MH/s mean** |

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

## Profile-guided build

A clean frontend-instrumentation comparison used Apple clang 21.0.0,
`-O3 -flto=thin`, the default AArch64 crypto target, and forced jump-table
lowering. Profile generation added
`-fprofile-instr-generate -fprofile-update=atomic`; the profile-use build added
`-fprofile-instr-use`. Training used 10 threads and a nominal 5-second offline
Verus benchmark. Atomic instrumentation completed 639,999 hashes in 15.745
seconds and produced a miner-only 231-function profile.

Two 8-second PGO runs measured 23.11 and 22.17 MH/s, averaging **22.64 MH/s**.
Two interleaved exact-default runs measured 21.43 and 21.80 MH/s, averaging
**21.62 MH/s**. The short-run mean improvement was 4.8%. Kernel vectors passed,
and no macOS thermal or performance warning was recorded. A 30–60 second
confirmation and sustained thermal test have not been run; either requires
explicit approval. The exact profile and reference build checksums are locked
under [`profiles/`](profiles/README.md).

## Rejected short experiments

All kernel experiments below used the same default `-O3 -flto=thin` ARMv8
crypto build with forced jump-table lowering and 10 threads:

- A 4-normal/6-utility macOS QoS split activated every core, but worker
  migration erased the E-core gain. Normal workers spent 77.5% of sampled
  cycles on P cores and utility workers spent 70.0% on E cores. Its 8-second
  results did not beat the unsplit scheduler reliably, so the code was removed.
- Combining both random lane switches into one 64-way pair dispatcher reduced
  two indirect branches to one, but expanded the dual kernel to 20,676 bytes
  and fell to 18.38 MH/s.
- Passing the accumulator in SSA form removed dead stack stores, but repeated
  8-second results fell to 21.17 and 21.21 MH/s.
- Hoisting common key and buffer loads before dispatch fell to 21.00 MH/s.
- Manually unrolling only the variable 1–8-round inner cases fell to
  20.01 MH/s.

The upstream multi-thread nonce-span bug had to be fixed before these numbers
were meaningful. Before the fix, only thread 0 completed a normal batch; later
threads attempted billion-candidate initial scans and aggregate reporting was
zero. Earlier results collected while those stuck workers were still consuming
CPU were discarded.
