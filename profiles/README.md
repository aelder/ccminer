# Locked Apple-silicon PGO profile

`apple-m5-verus-20260722.proftext` is the exact LLVM frontend profile
originally locked for the 23.11 MH/s reference binary and now reused by the
24.10 MH/s case-4 candidate. LLVM's text profile format is checked in so the
data is inspectable and portable through Git. `build-mac-arm-pgo.sh`
reconstructs the original binary `.profdata` before compilation.

## Reference result

- Hardware: Apple M5 MacBook Air, 4 performance and 6 efficiency cores
- OS: macOS 26.5.2 (25F84)
- Toolchain: Xcode 26.6 (17F113), Apple clang 21.0.0
  (`clang-2100.1.1.101`)
- Target: `arm64-apple-darwin25.5.0`
- Build: `-O3 -flto=thin`, ARMv8 crypto, forced AArch64 jump tables
- Threads: 10
- Duration: 8.017 seconds
- Work: 185,306,967 hashes
- Result: **23.11 MH/s** (23,113,765 H/s)
- Thermal/performance warnings: none recorded

The second 8-second profile-guided run measured 22.17 MH/s. Their mean was
22.64 MH/s versus 21.62 MH/s for two interleaved default builds, a 4.8%
short-run improvement. This locked reference itself did not receive a
standalone sustained thermal run. Later baseline/candidate comparisons are
recorded in [`../BENCHMARKS.md`](../BENCHMARKS.md).

## Profile provenance

- Profile-training source state: commit `71263b8`
- Training: 10-thread offline Verus benchmark, nominal 5-second time limit
- Instrumentation: `-fprofile-instr-generate -fprofile-update=atomic`
- Instrumented result: 639,999 hashes in 15.745 seconds
- Functions: 231
- Profile text SHA-256:
  `8c584c0d62e3c9d7740952e66d141445947a1c14dcbd5e21179db494638954ef`
- Reconstructed `.profdata` SHA-256:
  `c7307423156d8aa33cc79920fff28f7a3086fbc2f30b481c2fffafecfb211597`
- Reference `ccminer` SHA-256:
  `4be0d7e1b388184d3d02df8eb57a019869a503a3c37440f428f3ef65a7e6d6f7`

The locked build rejects different optimization, native-target, jump-table, or
extra compiler flags and verifies both the reconstructed profile and resulting
binary checksums. Use `PGO_PROFILE_MODE=train ./build-mac-arm-pgo.sh` to create
a fresh profile after changing mining code or the compiler.

## Current compatible candidate

Commit `6c7ce96` changes the case-4 instruction schedule without changing the
hot function's profiled control-flow shape, so it can reuse this profile with:

```sh
PGO_PROFILE_MODE=candidate ./build-mac-arm-pgo.sh
```

With the exact toolchain above, that source produces candidate binary SHA-256
`c8d7e97fbd3485cc31e7d82281a3291ba1720c9b86359a6891da90e841f3c443`.
Two order-reversed 8-second pairs averaged 24.155 MH/s versus 23.640 MH/s for
the exact locked binary. A candidate-only 30-second run with the GUI minimized
measured **24.10 MH/s** (722,953,387 hashes in 30.003 seconds).
Two subsequent short LuckPool sessions submitted four live PBaaS shares with
zero rejects, validating the candidate's subscribe, authorize, job, target,
solution, and share-submission path on that pool.

Locked mode remains a reproducibility check for the older reference source and
must match its binary checksum. Candidate mode verifies the same profile and
toolchain but intentionally permits a different final binary checksum.
