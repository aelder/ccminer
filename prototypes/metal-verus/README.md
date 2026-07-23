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
