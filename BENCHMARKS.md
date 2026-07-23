# Apple-silicon benchmark log

## Apple M5 MacBook Air

Measured 2026-07-22 and 2026-07-23 on macOS 26.5 with Apple clang 21.0.0.
These are short offline VerusHash 2.2.2 runs, not sustained thermal or
accepted-share tests.

| Build | Threads | Result |
|---|---:|---:|
| ARMv8 crypto baseline (`-O3`) | 1 | 2.07 MH/s |
| ARMv8 crypto baseline (`-O3`) | 4 | 7.74 MH/s |
| ARMv8 crypto baseline (`-O3`) | 10 | 15.13 MH/s |
| Host-native (`-O3 -mcpu=native`) | 10 | 14.74 MH/s |
| Packed dual-lane CLHash (`-O3`, ThinLTO, jump tables) | 10 | **22.95 MH/s** |
| Clean frontend PGO (`-O3`, ThinLTO, jump tables) | 10 | **22.64 MH/s mean** |
| Case-4 staged `prandex` load (locked PGO profile) | 10 | **24.16 MH/s mean** |
| Case-4 candidate, minimized GUI (30-second run) | 10 | **24.10 MH/s** |

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
and no macOS thermal or performance warning was recorded. At the time the
profile was locked, no 30–60 second confirmation had been run. Later
baseline/candidate confirmations are recorded below; a sustained thermal test
still requires explicit approval. The exact profile and reference build
checksums are locked under [`profiles/`](profiles/README.md).

## Provisional case-4 load-staging result

The strongest post-lock candidate moves case 4's `prandex` load ahead of its
AES chain and keeps the loaded vector live until the existing store. Both
original late-load instructions were sampled L1D-miss sites. The change adds no
dynamic instruction or memory operation: the PGO dual kernel shrank from 1,214
to 1,212 instructions, retained its 272-byte frame, and gives the two staged
loads roughly 55 and 82 instructions of lead time.

The complete baseline/candidate state oracle passed 4,096 calls, including 514
aliased key-index pairs. A four-round, same-process fixed-work comparison was
positive in every round and measured +1.58% in aggregate. Two clean,
order-reversed 8-second miner pairs then measured 24.21 and 24.10 MH/s for the
candidate versus 23.66 and 23.62 MH/s for the exact locked binary. The pair
means are 24.155 versus 23.640 MH/s, a **2.18%** improvement. The candidate
binary SHA-256 is
`c8d7e97fbd3485cc31e7d82281a3291ba1720c9b86359a6891da90e841f3c443`.

A conservative 30-second confirmation ran the exact locked baseline first and
the candidate second, so any accumulated heat worked against the candidate.
The baseline measured 22.69 MH/s (680,684,701 hashes in 30.003 seconds) and
the candidate measured 22.72 MH/s (681,529,577 hashes in 30.002 seconds), only
a **0.13%** advantage. No macOS thermal or performance warning was recorded.
The candidate therefore remains neutral-to-slightly-positive over a longer
window; the short-run 2.18% gain should not be treated as sustained.

A follow-up candidate-only confirmation isolated a major source of system
contention by minimizing the Codex/ChatGPT window on the external display
before the run. The exact same 10-thread PGO candidate binary (SHA-256 above,
commit `6c7ce96`), built with `-O3 -flto=thin`, the default AArch64 crypto
target, forced jump-table lowering, and the locked profile, measured
**24.10 MH/s** (722,953,387 hashes in 30.003 seconds). This is 6.1% above the
earlier 22.72 MH/s candidate confirmation and closely matches its 24.155 MH/s
short-run mean. No macOS thermal or performance warning was recorded. Because
only the candidate was run under this minimized-window condition, treat the
result as evidence of substantial GUI/display contention, not as a new
baseline-versus-candidate comparison.

## Live pool validation

The exact candidate binary
`c8d7e97fbd3485cc31e7d82281a3291ba1720c9b86359a6891da90e841f3c443`
was tested with 10 threads against LuckPool's North America CPU endpoint,
`na.luckpool.net:3956`, on 2026-07-23.

The first short run enabled protocol dumping. It received successful responses
to `mining.subscribe` and `mining.authorize`, accepted a pool target and live
PBaaS job, submitted one complete solution, and received `result: true`. Its
share difficulty was 4,071,930 against a pool-assigned difficulty of
approximately 3,947,580.

A second short run used ordinary quiet logging and submitted three additional
shares at difficulties 5,440,625, 10,592,650, and 7,863,243. All three were
accepted. The combined live result is therefore **4 accepted and 0 rejected**
across two independent connections and worker names.

The displayed 18.39–18.93 MH/s rates were startup estimates from sessions that
stopped within seconds of finding shares; they are not performance benchmarks.
No macOS thermal or performance warning was recorded.

## Core-type diagnostics

The normal scheduler does use all ten cores. A short four-thread run measured
11.84 MH/s and a ten-thread run measured 22.37 MH/s, so the additional six
workers contributed about 10.53 MH/s. Do not infer normal P/E placement from
the CPU Bottlenecks Instruments mode: that recording forced all ten workers to
time-slice on the four performance cores.

A separate L1D Miss Sampling trace did record work on both core types. It
captured 13.533 performance-core CPU-seconds and 23.929 efficiency-core
CPU-seconds. After normalizing sampled events by CPU residency, efficiency
cores produced about 1.50 times as many L1D load and store miss samples per
CPU-second; their L1D TLB miss rate was only about 1.12 times higher. The hot
miss sites were random CLHash key loads/stores and keyed Haraka loads. These
are diagnostic ratios, not hashrate measurements; repeat the trace under an
otherwise idle system before using small differences to make a release
decision.

## Metal feasibility prototype

The isolated
[`codex/metal-verus-prototype`](https://github.com/aelder/ccminer/tree/codex/metal-verus-prototype/prototypes/metal-verus)
branch at commit `45d5b74` ports the exact Verus CLHash hot path, keyed-Haraka
high-word filter, mutation log, and key restoration to Metal. It does not
change this branch's production miner.

The GPU implementation passed four hybrid canonical vectors, 257 deterministic
CPU/GPU differential lanes, all eight CLHash cases, 14 colliding-index cases,
and primitive checks for carry-less multiplication, rounded 16-bit
multiplication, AES, and polynomial reduction.

| Configuration | Duration | Result |
|---|---:|---:|
| Metal hot path, batch 8,192 | 8.003 s | 2.150 MH/s |
| Locked PGO CPU, 10 threads | 8.011 s | 21.42 MH/s |
| Metal while CPU ran | 10.004 s | 1.648 MH/s |
| CPU while Metal ran | 8.002 s | 22.11 MH/s |
| Provisional concurrent sum | — | 23.76 MH/s |

The Metal rate is wall-clock serial command-submission throughput. The
concurrent results are short and noisy, and the prototype does not yet scan
targets, return winning nonces, or submit shares. A production attempt would
need queued/double-buffered command buffers, synchronized CPU/GPU measurement,
and CPU verification of every candidate before submission. Unified memory
removes an explicit PCIe transfer but not the algorithm's random per-lane key
mutation, software GPU carry-less multiplication/AES work, or contention for
memory bandwidth and package power.

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
- Prefetching both random key locations for each lane's next CLHash step was
  correct but lost 10.14% in a clean, same-process four-round comparison.
- Prefetching only case 4's late `rc[10..11]` line after the accepted staged
  `prandex` load also lost. It passed the state oracle but added two prefetches
  plus a selector reload; a four-round same-process comparison was negative in
  three rounds and measured 0.31% slower in aggregate.
- Replacing repeated case-6 signed remainders with a precomputed reciprocal
  only when the divisor was reused at least three times passed full
  baseline/candidate state and hash checks. It expanded the hot dual kernel
  from 1,214 to 1,610 instructions. Two order-reversed 8-second pairs averaged
  22.665 MH/s for the candidate versus 22.915 MH/s for the locked binary, a
  1.09% loss, so the hardware `sdiv`/`msub` path remains locked.
- A true dual keyed-Haraka high-word primitive beat two scalar calls by about
  6.5% after warm-up, but Haraka is only about 2.3% of worker time. Integrating
  it into the scanner changed the PGO shape and lost at whole-miner scale:
  two order-reversed 8-second pairs averaged 21.95 MH/s for the candidate
  versus 22.38 MH/s for the exact locked binary, a 1.9% loss.
- Staging both pristine-key restore loads before either store retained the
  scanner's instruction count and produced the intended two-load/two-store
  assembly. Its order-reversed 8-second pairs disagreed, and the pair means
  were 22.605 MH/s versus 22.775 MH/s for case-4 staging alone, a 0.75% loss,
  so the restore path remains unchanged.
- Interleaving both lanes' restore work produced four independent pristine
  loads before four disjoint stores while preserving the scanner's PGO
  profile, instruction counts, frame, and spills. A focused restore benchmark
  improved 3.58%, but whole-miner orders disagreed; the pair means were about
  0.38% slower than case-4-only, so it was also removed.
- Staging case 3's `prandex` load across its signed divide removed four static
  instructions and targeted E-heavy sampled misses, but its two miner orders
  disagreed. The pair means were 22.35 MH/s for case 3 plus case 4 versus
  22.535 MH/s for case 4 alone, a 0.82% loss, so only case 4 is retained.
- A specialized keyed-Haraka filter constructed the intermediate-derived
  suffix in registers and materialized it only on the rare full-hash branch.
  It passed 100,010 equivalence cases, removed 17 common-path store bytes, and
  netted one fewer dynamic instruction per hash, but a four-round standalone
  comparison was consistently negative and measured 0.89% slower.

The upstream multi-thread nonce-span bug had to be fixed before these numbers
were meaningful. Before the fix, only thread 0 completed a normal batch; later
threads attempted billion-candidate initial scans and aggregate reporting was
zero. Earlier results collected while those stuck workers were still consuming
CPU were discarded.
