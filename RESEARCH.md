# Verus mining on Apple silicon: source audit and optimization map

Research date: 2026-07-22. Sources are limited to first-party Verus documentation, the source repositories owned or directly linked by Verus, upstream source projects, and Apple/Arm documentation. Repository links below are pinned to the audited commits where practical.

## Executive conclusion

The best route to a maximally fast, pool-capable Apple-silicon miner is **not** to start from scratch and not to revive the old `nheqminer` build unchanged. It is to:

1. Port the current `monkins1010/ccminer` `Verus2.2` branch to native `arm64-apple-darwin`, retaining its working Stratum/PBaaS protocol layer.
2. Replace or reconcile its copied VerusHash implementation with the newer implementation in the current `VerusCoin/VerusCoin` daemon, which already has a supported Apple-ARM build path, a current `sse2neon`, and a better-structured hot loop.
3. Establish correctness against the daemon before optimizing, then benchmark thread/QoS policy, allocation removal, compiler tuning, and multi-nonce instruction-level parallelism on each target M-series generation.

The implementation ultimately kept CCminer's current protocol and scanner
contract, repaired its Apple/native and benchmark paths, and specialized the
CPU kernel in place. A wholesale daemon-loop replacement was not required to
reach the current fast path; the daemon remains a correctness and design
reference.

The official mining page currently lists CCminer v3.8.3a for Windows, Linux, and ARM, but explicitly says the Apple-silicon macOS build is “not (yet) available.” It links Linux/ARM to `Oink70/ccminer-verus` and Windows to `monkins1010/ccminer`; it no longer lists `nheqminer`. The same page describes CPU and ARM mining as highly suitable and says no GPU mining software is available. [Official mining page](https://docs.verus.io/economy/start-mining.html#mining-software)

## Implementation update: 2026-07-23

This section records what happened after the original audit. The detailed
measurements and rejected experiments live in
[`BENCHMARKS.md`](BENCHMARKS.md); the reproducible operator guide is
[`README-MAC-ARM.md`](README-MAC-ARM.md).

| Original workstream | Result |
|---|---|
| Native build | Complete: Homebrew prefix discovery, explicit `aarch64-apple-darwin`, current SDK headers, ARM crypto target, ThinLTO |
| Honest multi-thread benchmark | Complete: nonce-span bug fixed, common start barrier/deadline, bounded batches, exact aggregate hash count |
| Consensus kernel tests | Complete for the offline hot path: deterministic vectors, scalar/dual differential, key mutation/restoration, alias cases, ARM `PMULHRSW` semantics |
| Multi-nonce ILP | Complete for two lanes: the main gain, raising the short 10-thread result from 15.13 to 22.95 MH/s with the compiler changes |
| Compiler tuning | Measured: forced jump tables won; ThinLTO remains; `-mcpu=native` lost; locked-profile PGO gained 4.8% in its paired comparison |
| Cache/load scheduling | One case-4 load-staging candidate survived and reached 24.155 MH/s in short pairs and 24.10 MH/s over a quiet-desktop 30-second run |
| P/E-core policy | Measured: all 10 cores contribute; a 4-normal/6-utility split did not beat the default scheduler |
| GPU feasibility | Exact Metal hot-path prototype passed CPU/GPU differential checks, measured 2.150 MH/s alone and 1.648 MH/s beside the CPU miner, and remains isolated on `codex/metal-verus-prototype` |
| Pool validation | Complete on LuckPool: two short live sessions produced 4 accepted shares and 0 rejects |
| Sustained efficiency | Open: no 10–20 minute thermal/power run has been authorized or performed |
| Packaging/licensing | Open: signing, notarization, dependency pinning, and a complete license/NOTICE inventory remain |

The current 24.10 MH/s result is 59.3% above the first correct 15.13 MH/s
native baseline. It used 10 threads and the case-4 candidate binary with the
Codex/ChatGPT window minimized. A separate diagnosis found that Codex's
Chromium GPU process and WindowServer were continuously compositing on a
6016×3384 backing surface at 120 Hz; GUI/display state is therefore now a
recorded benchmark variable.

## What must be implemented

### Algorithm

The live network algorithm is VerusHash 2.2/2.2.2. The current CCminer banner identifies its implementation as “Verushash v2.2.2,” while the current daemon describes VerusHash as a CPU-optimized 256-bit proof-of-work hash with a Haraka V2 core. [CCminer banner](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/ccminer.cpp#L3448-L3455), [daemon algorithm description](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/src/crypto/verus_hash.cpp#L1-L10)

The mined object is not a simple 80-byte Bitcoin header. CCminer processes a 140-byte header plus a 1,344-byte Verus solution. For PBaaS/merge-mined solution versions it clears non-canonical header and solution fields before hashing, then places a 15-byte mining nonce into solution space. [CCminer scan path](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/verusscan.cpp#L158-L223)

At a high level, one candidate hash does the following:

- Hashes the canonical header/solution in 32-byte chunks through Haraka-512 to obtain the initial 64-byte state.
- Expands that seed by chained Haraka-256 into an 8,832-byte per-thread key (`8192 + 40*16`).
- Runs the Verus CLHash-derived, key-mutating intermediate step. This step is dominated by carry-less polynomial multiplication plus AES/Haraka operations.
- Uses the intermediate value to choose part of the dynamic key and performs a keyed Haraka-512 finalization to a 256-bit result, then restores the temporarily mutated key entries.

The constants, key size, and sequence are visible directly in CCminer. [key generation and finalization](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/verusscan.cpp#L50-L155), [CLHash purpose and license](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/verus_clhash.cpp#L1-L18)

The maintained daemon implements the same primitives but keeps reusable thread-local hash/key state and hoists header serialization/key preparation outside the nonce loop. [daemon thread-local state and ARM dispatch](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/src/crypto/verus_clhash.cpp#L29-L62), [daemon optimized mining loop](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/src/crypto/verus_clhash.cpp#L140-L235)

### Pool protocol

CCminer speaks the newline-delimited JSON Stratum family used by Verus pools. It connects with `stratum+tcp://`, then performs `mining.subscribe` and `mining.authorize`. Its Equihash-derived job protocol is explicitly marked non-standard. A job notification carries job ID, version, previous hash, two 32-byte coinbase/reserved fields, time, compact target, clean-job flag, and the 1,344-byte solution. A share submission sends username, job ID, time, nonce excluding the pool extranonce prefix, and the 1,347-byte encoded solution. [job parsing](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/equi/equi-stratum.cpp#L158-L228), [non-standard protocol note and share submission](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/equi/equi-stratum.cpp#L231-L322), [connection sequence](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/ccminer.cpp#L2554-L2600)

This protocol layer is the main reason to port CCminer rather than use the daemon alone. The daemon has current consensus logic and can CPU-mine locally/solo via `-gen`, `-genproclimit`, and `setgenerate`, but it is a full node rather than the lightweight pool-miner frontend documented on the mining-software page. [daemon mining options](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/src/init.cpp#L541-L542), [setgenerate RPC](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/src/rpc/mining.cpp#L304-L380)

## Candidate codebases

| Codebase | Current role | ARM64/NEON | macOS status | Recommendation |
|---|---|---|---|---|
| [`monkins1010/ccminer`, `Verus2.2`](https://github.com/monkins1010/ccminer/tree/e28e183c39a7751851c0b3a02696ee717bb32a0e) | Current upstream of the miner family; pool-capable; last audited commit 2025-03-08 | Has an AArch64 configure case, defines `ARM`, and consumes `DLTcollab/sse2neon` as a submodule | README claims a Mac build, but the Apple-silicon build is broken as shipped; no Mac ARM release | **Primary port target** because its protocol is current and its ARM path is close |
| [`Oink70/ccminer-verus`, `Verus2.2`](https://github.com/Oink70/ccminer-verus/tree/ac4d85cb4af61273fae12aee1ef2b3db0e87ef89) | Fork linked by the official page for Linux/ARM v3.8.3a; last audited commit 2023-12-19 | Similar ARM code | No Apple-silicon binary; older than Monkins current branch | Useful for matching the officially distributed Linux/ARM baseline, but upstream changes should be based on Monkins |
| [`VerusCoin/nheqminer` v0.8.2](https://github.com/VerusCoin/nheqminer/tree/0b46244021a83a3adba6648e21cc11ad0aa90ee5) | Older Verus-owned standalone Stratum miner; last commit 2020-06-15 | Contains an early custom SSE-to-NEON layer and direct `vaeseq_u8`, `vaesmcq_u8`, and `vmull_p64` calls | Shipped an Intel-era Mac CLI and describes VerusHash 2.2, but its CMake unconditionally applies x86-only `-m64`, AVX, SSE, AES-NI, and PCLMUL flags | **Reference only**; more work and more correctness risk than CCminer |
| [`VerusCoin/VerusCoin`](https://github.com/VerusCoin/VerusCoin/tree/a10e2fb39e42a7c31d4e447c9e152090a562a57f) | Canonical current consensus implementation and full-node solo/merge miner | Current vendored `sse2neon`; hardware AES and polynomial multiply mappings; thread-local hash state | Explicit native Apple-silicon build script using `aarch64-apple-darwin` and `-mcpu=apple-m1` | **Canonical correctness and optimization donor**; also usable now for solo mining |

### Why the stale `M1` branch is not the answer

The Monkins repository has an `M1` branch at commit [`fc1ef17`](https://github.com/monkins1010/ccminer/tree/fc1ef1775eec351ff75b283f4528e1cd8d795b7e), dated 2021-02-25, but it still uses x86 CPUID headers in the Verus path and its Autoconf macOS match is `*86*-apple-darwin*`. It is therefore neither a current PBaaS baseline nor a completed native Apple-ARM port. [M1 configure logic](https://github.com/monkins1010/ccminer/blob/fc1ef1775eec351ff75b283f4528e1cd8d795b7e/configure.ac#L43-L70), [M1 x86-dependent hash header](https://github.com/monkins1010/ccminer/blob/fc1ef1775eec351ff75b283f4528e1cd8d795b7e/verus/verus_clhash.h#L23-L31)

## ARM64 and Apple-silicon capability

The current CCminer branch's intended AArch64 path is fundamentally viable:

- Autoconf recognizes `aarch64-*`, sets `-DARM`, and requests Armv8 FP/SIMD/crypto. [configure logic](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/configure.ac#L43-L61), [ARM flags](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/configure.ac#L104-L114)
- Under `ARM`, both Haraka and CLHash include the pinned `sse2neon` submodule rather than x86 intrinsics directly. [CLHash include](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/verus_clhash.h#L24-L32), [Haraka include](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/haraka.h#L27-L43)
- The pinned `sse2neon` commit maps `_mm_aesenc_si128` to Arm `AESE` + `AESMC` intrinsics when crypto extensions are available, and maps `_mm_clmulepi64_si128` to `vmull_p64`. [AES mapping](https://github.com/DLTcollab/sse2neon/blob/3cbb6e60ee1e7db1c92bcdcc66c07dd825c80350/sse2neon.h#L8605-L8635), [carry-less multiply mapping](https://github.com/DLTcollab/sse2neon/blob/3cbb6e60ee1e7db1c92bcdcc66c07dd825c80350/sse2neon.h#L8648-L8668)

Arm documents `AESE`/`AESMC` as the crypto-extension AES operations exposed by `vaeseq_u8`/`vaesmcq_u8`, and PMULL as polynomial multiply. [Arm accelerated-crypto explanation](https://developer.arm.com/community/arm-community-blogs/b/tools-software-ides-blog/posts/porting-putty-to-windows-on-arm), [Armv8 ISA overview](https://developer.arm.com/-/media/Files/pdf/graphics-and-multimedia/ARMv8_InstructionSetOverview.pdf)

The daemon provides stronger evidence that the approach works on modern Macs: its dedicated script builds the dependency tree for `aarch64-apple-darwin`, targets macOS 13, compiles the hot code with `-mcpu=apple-m1 -O2`, and notes M2/M3/M4 substitutions. [Apple-ARM build script](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/zcutil/build-mac-arm.sh#L43-L57), [official Mac build instructions](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/README-MAC.md)

Apple says custom build systems must add the `arm64` architecture, warns that x86-specific assembly, hardware assumptions, and hand-tuned multithreading require explicit porting, and recommends measuring on actual hardware. [Porting to Apple silicon](https://developer.apple.com/documentation/Apple-Silicon/porting-your-macos-apps-to-apple-silicon)

## Reproduced build blockers on Apple silicon

I reproduced the unmodified `monkins1010/ccminer` build on an ARM64 Mac using Apple clang 21.0.0 and the macOS 26.5 SDK. The failures are deterministic and explain why the existing “ARM” support does not produce a Mac binary.

1. **The submodule is required but a normal shallow clone leaves it empty.** The code includes `verus/sse2neon/sse2neon.h`; cloning must use `--recurse-submodules` or run `git submodule update --init --recursive`. [.gitmodules](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/.gitmodules)
2. **The build script hard-codes Intel Homebrew paths.** It exports `/usr/local/opt/openssl/...`; native Apple Homebrew uses `/opt/homebrew`, so configure first fails with `OpenSSL library required`. [build script](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/build.sh#L1-L19)
3. **The repository's old `config.guess` reports this Mac as `arm-apple-darwin...`, not `aarch64-apple-darwin...`.** That falls through the `arm*` case and emits 32-bit flags `-march=armv7 -mfpu=neon`, which Apple clang rejects for the ARM64 target. Supplying `--host=aarch64-apple-darwin` reaches the intended branch. [architecture pattern and flags](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/configure.ac#L43-L61), [flag selection](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/configure.ac#L104-L114)
4. **The macOS-specific Makefile includes a dead, hard-coded Clang 4 path** (`/usr/local/llvm/lib/clang/4.0.0/include`). It should be removed; the SDK compiler provides its own intrinsic headers. [Makefile](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/Makefile.am#L33-L42)
5. **After correcting host and OpenSSL discovery, current macOS headers collide with CCminer's fallback endian helpers.** `miner.h` redefines `be16dec`, `be16enc`, `le16dec`, and `le16enc`, while configure checks only the 32-bit variants. Add declaration checks/guards for all 16-bit helpers. [incomplete configure checks](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/configure.ac#L21-L38), [fallback helpers](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/miner.h#L191-L259)
6. **The build has no automated VerusHash correctness tests.** A successful compile is insufficient for consensus code. The port must compare known inputs and large nonce ranges against the current daemon's optimized and portable implementations before any pool test.

`nheqminer` has larger blockers. Its CMake assigns x86-only `-m64 -mavx -mpclmul -msse* -maes` flags to every Verus crypto source even inside `if(APPLE)` builds. Its custom ARM `_mm_clmulepi64_si128` ignores the intrinsic's lane-select immediate, despite call sites using both `0x10` and `0x01`, which makes it a correctness risk rather than a drop-in Apple-ARM implementation. [x86-only CMake flags](https://github.com/VerusCoin/nheqminer/blob/0b46244021a83a3adba6648e21cc11ad0aa90ee5/CMakeLists.txt#L36-L51), [ARM intrinsic shim](https://github.com/VerusCoin/nheqminer/blob/0b46244021a83a3adba6648e21cc11ad0aa90ee5/nheqminer/crypto/verus_clhash.cpp#L64-L104), [different lane-selecting call sites](https://github.com/VerusCoin/nheqminer/blob/0b46244021a83a3adba6648e21cc11ad0aa90ee5/nheqminer/crypto/verus_clhash.cpp#L153-L176)

## Licensing

- The canonical `VerusCoin/VerusCoin` distribution is MIT for directly included source, with documented exceptions: its default Berkeley DB dependency is AGPL, and `shuffle_compat.h` used for Apple builds is GPLv3-derived. [daemon COPYING](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/COPYING)
- The CCminer repository does **not** contain the `COPYING`/`LICENSE.txt` file referenced by its source and `Makefile.am`, and GitHub does not detect a repository-level license. Core files state GPL v2-or-later; the Equihash/Verus scanner says GPLv3; Verus CLHash files state Apache-2.0; Haraka files state MIT. Distributing the combined miner should therefore be treated as GPL-covered, preserve all notices and source obligations, and restore a clear top-level license/NOTICE inventory. [core GPL notice](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/ccminer.cpp#L1-L11), [scanner GPLv3 notice](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/verusscan.cpp#L1-L5), [CLHash Apache notice](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/verus_clhash.cpp#L1-L18), [Haraka MIT notice](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/haraka.c#L1-L25)
- `nheqminer` includes MIT license files for its inherited components, while its Verus CLHash files retain Apache-2.0 notices. It needs the same component-level inventory before redistribution. [nheqminer MIT file](https://github.com/VerusCoin/nheqminer/blob/0b46244021a83a3adba6648e21cc11ad0aa90ee5/LICENSE_MIT), [nheqminer Verus CLHash notice](https://github.com/VerusCoin/nheqminer/blob/0b46244021a83a3adba6648e21cc11ad0aa90ee5/nheqminer/crypto/verus_clhash.cpp#L1-L18)

This is a source-license audit, not legal advice.

## Optimization opportunities, in priority order

### P0: correctness and a reproducible native build

1. Update the Autoconf canonicalization files and recognize both `arm64-apple-darwin*` and `aarch64-apple-darwin*`; do not let Apple ARM64 take the Armv7 flag path.
2. Discover dependencies with `pkg-config`/`brew --prefix` rather than `/usr/local`; remove the Clang 4 include.
3. Vendor or pin a current `sse2neon` revision. The daemon's 2024-era copy handles Apple AArch64 explicitly, including a 128-byte Apple cache-line definition and hardware AES/PMULL mappings. [current daemon `sse2neon`](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/src/crypto/sse2neon.h#L240-L288), [PMULL path](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/src/crypto/sse2neon.h#L898-L930)
4. Add deterministic vectors that compare: portable scalar, native NEON, the current daemon, and CCminer job assembly (including PBaaS canonicalization and submit encoding). Run them with sanitizers before throughput tuning.

### P1: use the daemon's maintained hot loop

The current CCminer scanner allocates and frees roughly 9.8 KiB for every `scanhash_verus` invocation, regenerates the 8,832-byte key for every invocation, and calls `load_constants()` while forming the job prefix. Its inner loop then processes exactly one nonce per iteration (`throughput = 1`). [allocation and setup](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/verusscan.cpp#L158-L205), [one-at-a-time loop](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/verusscan.cpp#L205-L247)

In contrast, the daemon owns reusable thread-local key/descriptor state, skips key generation when the seed is unchanged, and serializes/prepares the block outside its nonce loop. This is the clearest source-backed optimization donor. [thread-local storage](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/src/crypto/verus_clhash.cpp#L45-L62), [seed reuse and nonce loop](https://github.com/VerusCoin/VerusCoin/blob/a10e2fb39e42a7c31d4e447c9e152090a562a57f/src/crypto/verus_clhash.cpp#L140-L235)

Recommended design: keep one aligned hash context per mining thread; rebuild its job prefix/key only when the Stratum job/canonical seed changes; reuse scratch/key buffers for the entire worker lifetime; initialize Haraka constants once. First port the daemon loop almost verbatim and adapt only the nonce placement and result handoff needed by CCminer's Stratum work object.

### P2: compiler and code-generation experiments

Build a measurement matrix rather than assuming one flag set wins:

- `-O2` versus `-O3`.
- `-mcpu=apple-m1`, `apple-m2`, `apple-m3`, and `apple-m4` for generation-specific binaries, following the daemon build script; use a conservative baseline for a widely distributed ARM64 binary.
- Link-time optimization (`-flto`) and then profile-guided optimization using a representative benchmark/job corpus.
- Current pinned `sse2neon` versus the daemon's newer copy versus a direct Arm-intrinsic kernel for the actual CLHash/Haraka subset.

Do not expect Accelerate to help: it accelerates high-level math/DSP primitives, not VerusHash's keyed AES-round and polynomial-multiply sequence. Apple describes Accelerate's scope as vector math, DSP, image, and neural-network computation. [Accelerate overview](https://developer.apple.com/documentation/accelerate)

### P3: nonce batching and instruction-level parallelism

CCminer's Haraka source already contains `haraka256_4x`, `haraka512_4x`, and 8-way wrappers, but the Verus scanner never uses them. [4-way Haraka](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/haraka.c#L411-L488), [single-candidate scanner](https://github.com/monkins1010/ccminer/blob/e28e183c39a7751851c0b3a02696ee717bb32a0e/verus/verusscan.cpp#L205-L237)

Prototype 2- and 4-candidate unrolling to expose independent AES/PMULL operations to Apple's out-of-order cores and amortize loop/restart checks. This is not automatically a win: Verus CLHash mutates and restores the dynamic key each candidate, so true multi-candidate batching may require independent per-lane key/scratch state and extra copying. Measure the complete hash, not Haraka alone.

### P4: heterogeneous cores, scheduling, and sustained efficiency

Apple silicon has performance and efficiency cores, and Apple explicitly warns not to assume all cores are equal. QoS influences which core type executes work; Apple recommends QoS rather than manual priority/affinity and recommends dynamic work distribution for heterogeneous cores. [Apple performance tuning](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon/)

For maximum useful mining rather than a short burst:

- Sweep worker counts from 1 through all logical CPUs and record accepted H/s, package power, temperature, and throttling over at least 10–20 minutes.
- Compare default/utility/user-initiated QoS for mining workers. Avoid user-interactive QoS. The best H/s/W setting may intentionally include E cores; the best absolute H/s may require a different policy.
- Give each worker persistent state and large nonce chunks, but poll job cancellation frequently enough to avoid stale shares.
- Report both total H/s and H/s/W. Laptop cooling and power mode can reverse a short-benchmark result over sustained operation.

### P5: packaging

Produce a native `arm64` CLI first. After correctness and performance stabilize, add an `x86_64` slice and combine them as a universal binary if Intel Macs matter. Apple documents `arm64` plus `x86_64` universal binaries and recommends testing both slices separately. [Building a universal macOS binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)

For a distributable miner, also add deterministic dependency pinning, code signing, hardened runtime where compatible, notarization, SHA-256 checksums, and a source archive/offer satisfying the combined GPL obligations.

## Remaining implementation sequence

The native build, deterministic hot-path tests, reliable offline benchmark,
two-lane CPU kernel, compiler/LTO/PGO comparisons, and first P/E-core
experiments are complete. The remaining gates are:

1. Cross-check complete PBaaS job assembly and submitted nonces against the
   daemon, not only the isolated hashing kernel.
2. Repeat accepted-share validation on any additional pool intended for
   production use and confirm worker accounting on the pool dashboard.
3. Continue CPU optimization with the existing 8–10 second iteration loop,
   correctness oracle, order-reversed pairs, and 30–60 second confirmations.
4. Train and compare fresh PGO profiles on each target M-series generation
   rather than assuming the checked-in M5 profile transfers.
5. Revisit Metal only if queued/double-buffered dispatch can beat its current
   1.648 MH/s concurrent result after CPU, memory-bandwidth, and package-power
   contention.
6. With explicit approval, run 10–20 minute thread-count, power, temperature,
   and H/s/W comparisons.
7. Restore a complete license/NOTICE inventory, pin dependencies, sign and
   notarize binaries, and publish per-build checksums and source.

The current native ARM64 candidate has now received four accepted PBaaS shares
with zero rejects. The next correctness milestone is a byte-for-byte
full-job/submit cross-check against the daemon, followed by broader pool and
release validation before binary distribution or sustained performance claims.
