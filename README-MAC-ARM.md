# Native Verus mining on Apple silicon

This tree ports the current `monkins1010/ccminer` `Verus2.2` branch to native
`arm64-apple-darwin`. It retains CCminer's Verus Stratum/PBaaS support and uses
ARM hardware AES, PMULL, and NEON through the upstream `sse2neon` layer.

## Performance snapshot

The initial correct 10-thread ARMv8 build measured 15.13 MH/s on an Apple M5
MacBook Air. The current CPU candidate measured **24.10 MH/s** over 30 seconds:
722,953,387 hashes in 30.003 seconds. That is a 59.3% increase over the initial
native baseline.

The 24.10 MH/s run used the exact candidate binary with SHA-256
`c8d7e97fbd3485cc31e7d82281a3291ba1720c9b86359a6891da90e841f3c443`,
10 threads, the locked Apple M5 PGO profile, and a minimized Codex/ChatGPT
window. macOS reported no thermal or performance warning. It was not a
sustained thermal test, and pool-accepted shares still need validation.

| Milestone | 10-thread result | What changed |
|---|---:|---|
| Correct ARMv8 `-O3` baseline | 15.13 MH/s | Native build and honest multi-thread benchmark |
| Host-native compiler target | 14.74 MH/s | `-mcpu=native`; rejected |
| Dual-lane CPU kernel | 22.95 MH/s | Two independent CLHash states, ThinLTO, jump tables |
| Locked-profile PGO | 22.64 MH/s mean | 4.8% over its interleaved 21.62 MH/s non-PGO control |
| Case-4 load staging | 24.155 MH/s short-run mean | 2.18% over its paired 23.640 MH/s locked control |
| Case-4 candidate, quiet desktop | **24.10 MH/s over 30 s** | Same candidate with display/UI contention reduced |

The rows use different comparison designs and system conditions. The paired
percentages are stronger evidence than subtracting adjacent table entries. See
[BENCHMARKS.md](BENCHMARKS.md) for hashes, elapsed times, ordering, rejected
experiments, and caveats.

## Build the current fast path

Install the Xcode command-line tools and Homebrew dependencies:

```sh
xcode-select --install
brew install autoconf automake curl jansson openssl@3
git submodule update --init --recursive
```

On the current `codex/cpu-next-wins` source, build the fastest tested CPU
candidate with:

```sh
PGO_PROFILE_MODE=candidate ./build-mac-arm-pgo.sh
```

This produces `./ccminer` with `-O3 -flto=thin`, the portable ARMv8 crypto
target, forced AArch64 jump-table lowering, the checked-in Apple M5 profile,
and the case-4 load-staging change. Candidate mode verifies the profile and
toolchain but permits the final binary to differ from the older locked
reference binary.

Verify that the expected source and binary are in use:

```sh
git rev-parse --short HEAD
shasum -a 256 ./ccminer
```

For the case-4 source introduced by commit `6c7ce96` (including docs-only
descendants) with Apple clang 21.0.0, the expected binary SHA-256 is:

```text
c8d7e97fbd3485cc31e7d82281a3291ba1720c9b86359a6891da90e841f3c443
```

### Other build modes

| Command | Purpose |
|---|---|
| `./build-mac-arm.sh` | Portable non-PGO build; the safest starting point on another M-series generation |
| `NATIVE=1 ./build-mac-arm.sh` | Host-specific compiler target; slower on the tested M5 |
| `PGO_PROFILE_MODE=candidate ./build-mac-arm-pgo.sh` | Current fastest M5 candidate |
| `PGO_PROFILE_MODE=train ./build-mac-arm-pgo.sh` | Train a fresh profile after source, compiler, or target changes |
| `PGO_PROFILE_MODE=locked ./build-mac-arm-pgo.sh` | Reproduce and checksum the 23.11 MH/s reference on its exact locked source |

The bare `./build-mac-arm-pgo.sh` command defaults to `locked` mode. That mode
is intentionally strict and expects the pre-case-4 source represented by
commit `9d5a195`; it should reject a different final binary. Use `candidate`
mode on the current branch.

Both locked-profile modes require Apple clang 21.0.0
(`clang-2100.1.1.101`). If the installed Xcode tools provide another compiler,
train a fresh profile instead; a binary produced by another compiler should
not be expected to match either checksum above.

To train for a different Apple chip or changed hot loop:

```sh
PGO_PROFILE_MODE=train \
  PGO_TRAIN_SECONDS=5 \
  PGO_TRAIN_THREADS="$(sysctl -n hw.logicalcpu)" \
  ./build-mac-arm-pgo.sh
```

The instrumented training binary is much slower than the optimized miner and
can finish its current work batch after the nominal time limit. A PGO profile
is tied to the source control-flow shape, compiler, and architecture flags.
Retrain after changing any of those. The offline training corpus does not cover
pool networking or share submission.

For compiler diagnosis only:

```sh
LTO=0 ./build-mac-arm.sh
FORCE_JUMP_TABLES=0 ./build-mac-arm.sh
```

Do not redistribute a `NATIVE=1` binary as a general Apple-silicon build;
compiler-selected instructions can be generation-specific. See
[profiles/README.md](profiles/README.md) for the locked profile's exact
toolchain, source provenance, and checksums.

## How the CPU path became fast

### 0. Produce a real native ARM64 binary

The upstream project had most of the required ARM intrinsics but its macOS
build path was not usable on Apple silicon. The native port:

- discovers Homebrew, curl, and OpenSSL through `brew --prefix` instead of
  hard-coded Intel `/usr/local` paths;
- configures explicitly for `aarch64-apple-darwin`, preventing the old
  `config.guess` result from selecting 32-bit Armv7 flags;
- removes a dead hard-coded Clang 4 intrinsic-header path;
- detects the 16-bit endian helpers already supplied by current macOS headers;
- initializes the required `sse2neon` submodule; and
- builds and links every mining source as a native `arm64` executable.

Use `file ./ccminer` after a build to confirm the result is Mach-O `arm64`,
not an Intel binary running through Rosetta.

### 1. Make the benchmark truthful

The upstream scanner passed each worker's absolute outer nonce endpoint into a
scanner that expected a batch length. Thread 0 returned; later threads tried to
scan one to several billion candidates before returning. Those workers
continued consuming CPU, aggregate hashrate stayed at zero, and early
measurements were invalid.

The Apple path now passes a bounded nonce span, starts every worker behind a
barrier, keeps benchmark batches responsive, counts hashes per worker, stops
all workers from a monotonic shared deadline, and reports total hashes divided
by the actual common window. This was a measurement fix, but it was essential:
optimization against the old numbers would have been meaningless.

### 2. Preserve consensus behavior while using ARM hardware

The native build reaches Apple silicon's AES and polynomial-multiply
instructions through `sse2neon`. The hot path uses NEON vectors, hardware AES,
and PMULL rather than emulating the x86 operations scalarly.

One semantic trap required an explicit correction: Arm's rounded,
saturating 16-bit multiply differs from x86 `PMULHRSW` for the
`-32768 * -32768` corner. The wrapper corrects that lane after
`vqrdmulhq_s16`, and 10,000 deterministic vector rounds explicitly test the
behavior against the x86-compatible intrinsic.

The scanner also computes only the keyed-Haraka high word used by the common
target prefilter. It materializes the full 256-bit hash only for a rare
candidate that passes that filter.

### 3. Interleave two independent CLHash lanes

This was the largest gain. A single Verus CLHash state has long dependency
chains through PMULL, AES, vector multiply, random key loads, and signed
division. Apple cores cannot issue around those dependencies if only one hash
is available.

Each ARM worker now prepares two nonce inputs and owns two independent mutable
8,832-byte keys. `verusclhashv2_2_dual` alternates one complete CLHash step from
each lane, exposing independent instructions while one lane waits on latency.
The two-lane API marks its keys, inputs, logs, and outputs `restrict`, and the
hot function avoids stack-protector overhead so Apple clang has room to keep
state live.

CLHash mutates two random key entries per step. Instead of saving both old
128-bit values, the ARM path packs their two 16-bit indices into one 32-bit log
entry. After finalization it restores both mutable keys from one pristine key.
The restoration order is deliberately alias-safe when both selectors identify
the same entry.

Together with the compiler changes below, the packed dual path raised the
10-thread result from 15.13 to 22.95 MH/s, a 51.7% increase.

### 4. Force the branch shape the hardware preferred

Apple clang normally lowered CLHash's random eight-way switch into three
unpredictable conditional branches. Passing
`-mllvm -aarch64-min-jump-table-entries=1` at compile and ThinLTO link time
forces a jump table. It was 7.0% faster in balanced fixed-work dual-kernel
tests.

ThinLTO stays enabled by default. `-mcpu=native` did not help: Apple clang
resolved the M5 to its newest known `apple-m4` target, and the result fell from
15.13 to 14.74 MH/s in the original comparison. The portable ARMv8 crypto
target remains the default.

### 5. Train the whole miner with PGO

Frontend instrumentation recorded a representative 10-thread offline Verus
run, then Apple clang rebuilt the miner with `-fprofile-instr-use`. Two PGO
runs averaged 22.64 MH/s against 21.62 MH/s for interleaved non-PGO controls,
a 4.8% gain. The exact 231-function profile is stored as inspectable LLVM text
under [`profiles/`](profiles/README.md).

### 6. Hide one random-load miss behind case 4's AES chain

Instruments identified both late case-4 `prandex` loads as L1D-miss sites. The
current candidate issues that load before the AES chain and keeps it live until
the existing store. It adds no dynamic operation, shrinks the PGO dual kernel
from 1,214 to 1,212 instructions, preserves the 272-byte frame, and gives the
two staged lane loads about 55 and 82 instructions of latency cover.

The complete state oracle passed 4,096 calls, including 514 aliased-index
cases. Clean order-reversed 8-second pairs measured a 2.18% candidate gain.
The minimized-window 30-second run then reached 24.10 MH/s.

## Performance-core and efficiency-core findings

The normal scheduler uses all 10 cores. A four-thread run measured 11.84 MH/s;
a ten-thread run measured 22.37 MH/s in the same diagnostic series, so the
additional six workers contributed about 10.53 MH/s. Removing the E cores
would leave substantial throughput behind.

L1D Miss Sampling observed work on both core types. Normalized by CPU
residency, E cores produced about 1.50 times as many L1D load/store miss
samples per CPU-second, while their L1D TLB miss rate was only about 1.12 times
higher. The hot misses were random CLHash key traffic and keyed-Haraka loads.

A 4-normal/6-utility QoS split did not reliably improve throughput. macOS kept
migrating workers: normal workers spent 77.5% of sampled cycles on P cores and
utility workers spent 70.0% on E cores. The unsplit scheduler remains the
fastest supported policy.

CPU Bottlenecks mode in Instruments is not suitable for inferring normal P/E
placement here; that recording forced all ten workers to time-slice on the four
performance cores.

## GPU/Metal experiment

The exact CLHash hot path was also ported to Metal on branch
[`codex/metal-verus-prototype`](https://github.com/aelder/ccminer/tree/codex/metal-verus-prototype/prototypes/metal-verus)
at commit `45d5b74`. It is a correctness and throughput prototype, not part of
the production miner.

It passed four hybrid canonical vectors, 257 CPU/GPU differential lanes, all
eight CLHash cases, 14 colliding-key-index cases, and primitive tests for
carry-less multiply, rounded 16-bit multiply, AES, and reduction.

| Metal prototype condition | Result |
|---|---:|
| GPU hot path alone, batch 8,192 | 2.150 MH/s |
| GPU while the CPU miner ran | 1.648 MH/s |
| CPU while Metal ran | 22.11 MH/s |
| Provisional concurrent sum | 23.76 MH/s |

Unified memory avoids an explicit PCIe copy, but it does not give the GPU the
CPU's hardware PMULL/AES instruction mix or remove Verus's random,
key-mutating control flow. The prototype implements carry-less multiply and
AES through GPU-friendly software/table operations and needs a separate
8,832-byte mutable key per lane. It also stops before production target
scanning, winning-nonce reporting, and share submission.

The GPU path therefore had modest additive headroom but a much lower return
than further CPU work. It also competes for memory bandwidth, power, and the
same integrated GPU used by WindowServer. It remains isolated on its prototype
branch until a queued/double-buffered backend can prove a whole-miner gain.

## Experiments that did not survive

These changes were implemented, correctness-tested where applicable,
benchmarked, and removed:

- `-mcpu=native`: 14.74 MH/s versus the 15.13 MH/s portable baseline.
- P/E-core QoS splitting: migration erased the intended specialization.
- One combined 64-way dual-lane dispatcher: grew the kernel to 20,676 bytes
  and fell to 18.38 MH/s.
- Passing the accumulator in SSA form: 21.17 and 21.21 MH/s.
- Hoisting common key/buffer loads: 21.00 MH/s.
- Manual unrolling of variable 1–8-round cases: 20.01 MH/s.
- Prefetching both lanes' next random keys: 10.14% slower.
- A narrower case-4 prefetch after accepted load staging: 0.31% slower.
- Reciprocal-based repeated case-6 remainder: grew the kernel from 1,214 to
  1,610 instructions and lost 1.09%.
- Dual keyed-Haraka high-word execution: the primitive gained about 6.5%, but
  whole-miner throughput lost 1.9% because Haraka was only about 2.3% of time
  and the integration disturbed the PGO shape.
- Staging pristine restore loads: 0.75% slower at whole-miner scale.
- Interleaving both lanes' restore operations: the focused helper gained
  3.58%, but the miner lost about 0.38%.
- Case-3 load staging across signed divide: 0.82% slower.
- A specialized keyed-Haraka filter with fewer stores: 0.89% slower despite
  passing 100,010 equivalence cases.

The lesson was consistent: isolated instruction-count or microbenchmark wins
often lost after code size, register pressure, cache behavior, and PGO layout
were included. [BENCHMARKS.md](BENCHMARKS.md) retains the exact comparison
details so these paths are not accidentally repeated.

## Correctness tests

```sh
./test-verus-kernel.sh
SANITIZE=1 ./test-verus-kernel.sh
TEST_ARCH=x86_64 ./test-verus-kernel.sh
VERUS_BASELINE_REV=HEAD ./test-verus-kernel.sh --differential-dual
```

The suite checks deterministic full-hash vectors, filtered-versus-full Haraka
output, scalar-versus-dual CLHash results, complete dynamic-key restoration,
and the exact Apple NEON implementation of x86 `PMULHRSW` semantics. The
`x86_64` mode runs through Rosetta on Apple silicon when Rosetta is installed.
The baseline differential additionally compares both intermediate results,
both touched-index logs, every mutated key byte, final hashes, complete key
restoration, repeated calls, and aliased key-index cases against a Git
revision compiled into the same test process.

## Benchmark

```sh
./benchmark-mac-arm.sh
```

The default is one 8-second run using all logical CPUs. A normal optimization
iteration should stay around 8–10 seconds and test only the relevant
configuration:

```sh
DURATION=10 THREADS=4,10 ./benchmark-mac-arm.sh
```

Before recording a result:

1. Confirm that no older miner is consuming CPU with `pgrep -x ccminer`.
2. Keep power mode, thread count, compiler, flags, and binary checksum fixed.
3. Minimize or close animated Chromium/Electron windows and other GPU-heavy
   applications. Record external-display resolution and refresh rate.
4. Run baseline and candidate in both orders when the expected difference is
   small.
5. Record total hashes and elapsed time from the final `Benchmark:` line, not a
   transient displayed rate.
6. Check `pmset -g therm` before and after a confirmation.

This machine was driving an external LG display through a 6016×3384 backing
surface at 120 Hz. Codex's Chromium GPU process and WindowServer were the
recurring GPU submitters, and the same candidate measured 22.72 MH/s in the
earlier busy-display run versus 24.10 MH/s with Codex minimized. That
candidate-only comparison is not a controlled baseline pair, but the 6.1%
difference is large enough that GUI/display state must be treated as a
benchmark variable.

Five-second runs are smoke tests only. Use 30–60 seconds to confirm a promising
candidate. A 10–20 minute power/temperature run is a sustained thermal test;
do not run one without explicit approval.

## Pool mining

```sh
./ccminer -a verus \
  -o stratum+tcp://POOL_HOST:PORT \
  -u WALLET_ADDRESS.worker \
  -p x \
  -t "$(sysctl -n hw.logicalcpu)"
```

Use a wallet you control, not an exchange deposit address. Pool host, port,
difficulty-password syntax, fees, and merge-mining support are pool-specific.

## Current status

- Native ARM64 build: working.
- Current M5 CPU candidate: 24.10 MH/s over 30 seconds with a quiet desktop.
- Offline VerusHash 2.2.2 benchmark: working for multiple threads.
- Multi-thread nonce-span bug: fixed; upstream otherwise gave workers 1–N
  billion-candidate initial batches and never produced useful aggregate rates.
- Benchmark time-limit shutdown and aggregate reporting: fixed.
- Deterministic full-hash vectors, native/scalar differential checks, and
  dynamic-key restoration checks: working.
- Metal hot-path prototype: correct and measured, isolated on its own branch;
  not integrated with target scanning or share submission.
- Sustained thermal/power validation: not run.
- Accepted-share pool validation: still the next correctness gate before
  distributing binaries.

See [RESEARCH.md](RESEARCH.md) for the source audit, licensing notes, and the
optimization roadmap.
