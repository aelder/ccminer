# Locked Apple-silicon PGO profile

`apple-m5-verus-20260722.proftext` is the exact LLVM frontend profile used by
the best measured short-run binary in this repository. LLVM's text profile
format is checked in so the data is inspectable and portable through Git.
`build-mac-arm-pgo.sh` reconstructs the original binary `.profdata` before
compilation.

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
short-run improvement. No longer or sustained thermal confirmation was run.

## Profile provenance

- Mining source state: commit `71263b8` (later commits only added this build
  workflow and documentation)
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
