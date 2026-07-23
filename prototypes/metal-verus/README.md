# Metal Verus CLHash prototype

This is a throwaway feasibility prototype. It does not change the production
miner.

Question: can an exact VerusHash 2.2 hot path on the 8-core Apple M5 GPU
produce enough incremental throughput to justify a full Metal mining backend?

The prototype uses the current CPU implementation as its oracle. A run:

1. compiles the Objective-C++ harness;
2. compiles the Metal source at runtime;
3. compares GPU CLHash results, keyed-Haraka high words, mutation logs, and
   mutated keys with the CPU;
4. runs a five-second GPU-only smoke benchmark if correctness passes.

Run:

```sh
./prototypes/metal-verus/run.sh
```

The benchmark duration is intentionally capped at 10 seconds. Sustained thermal
testing requires explicit approval.

## Prototype verdict

Proceed to a small mining-backend integration.

On the Apple M5, the exact Metal path passed:

- all four hybrid canonical vectors (Metal hot path, CPU full-hash oracle);
- 257 deterministic CPU/GPU differential lanes;
- all eight CLHash cases;
- 14 cases where the two mutable key indices collided;
- primitive checks for carry-less multiply, rounded 16-bit multiply, AES, and
  polynomial reduction.

Short results from July 22, 2026:

| Configuration | Duration | Result |
| --- | ---: | ---: |
| Metal hot path, batch 8,192 | 8.003 s | 2.150 MH/s |
| Locked PGO CPU, 10 threads | 8.011 s | 21.42 MH/s |
| Metal while CPU ran | 10.004 s | 1.648 MH/s |
| CPU while Metal ran | 8.002 s | 22.11 MH/s |
| Provisional concurrent sum | — | 23.76 MH/s |

The concurrent numbers are deliberately short and noisy. They show enough
headroom to continue, not a validated long-run gain.

Throughput is wall-clock, serial command-submission throughput. The harness
advances the nonce range for every dispatch. A production backend should also
measure queued/double-buffered command buffers with synchronized CPU/GPU
windows.

The measured Metal path includes CLHash, the keyed-Haraka high-word filter, and
touched-key restoration. It does not yet scan targets, report winning nonces,
or submit shares. The next integration should add those narrow boundaries and
continue to CPU-verify every GPU candidate before submission.

The old CUDA branch was used only as a structural reference. Its nonce
placement predates the current scanner contract, and its unconditional key
write order is wrong when the two selected key indices alias.

## Carry-less multiply optimization

The first GPU bottleneck pass targeted Metal's lack of a native PMULL/CLMUL
operation. Offline AIR inspection showed that the original 4-bit implementation
materialized a private `[16 x i64]` table for every inlined multiply site; the
complete hot kernel contained 11 such sites.

The retained implementation decomposes each 64×64-bit polynomial multiply
into three 32×32-bit Karatsuba products. It evaluates all three products
together in a `uint4`, uses a branchless 4-bit window, and recombines them into
the exact 128-bit result. This uses the GPU's native-width integer operations,
exposes independent sub-products together, and eliminates every CLMUL table
allocation from AIR.

Same-session 8-second results with batch 8,192:

| Formulation | CLMUL primitive | Complete Metal hot path | Outcome |
| --- | ---: | ---: | --- |
| Original 64-bit private table, paired mean | 0.847 Gop/s | 1.829 MH/s | Baseline |
| Register-only 64-bit 2-bit window | 1.061 Gop/s | 1.446 MH/s | Rejected: doubled 64-bit loop hurt integration |
| Scalar 32-bit Karatsuba, paired mean | 1.283 Gop/s | 1.868 MH/s | Correct, +2.13% whole path |
| Scalar 32-bit 4-bit private table | 1.065 Gop/s | 1.814 MH/s | Rejected: private table returned |
| Vectorized 32-bit Karatsuba, 2-bit mean | 1.110 Gop/s | 1.915 MH/s | Correct, +4.70% whole path |
| **Vectorized 32-bit Karatsuba, 4-bit mean** | **1.349 Gop/s** | **2.119 MH/s** | **Retained: +59.2% primitive, +15.9% whole path** |

The historical 2.150 MH/s prototype result used different desktop conditions.
The percentages above compare baseline and candidates during the same session;
they should not be calculated against that older number.

The harness now includes a two-second chained CLMUL throughput measurement in
addition to complete-path timing. Correctness covers 4,096 primitive inputs
with explicit zero, all-one, high-bit, and alternating-bit cases, plus the
existing canonical, differential, all-case, colliding-index, and reusable-key
restoration checks.
