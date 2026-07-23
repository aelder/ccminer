# Native Verus mining on Apple silicon

This tree ports the current `monkins1010/ccminer` `Verus2.2` branch to native
`arm64-apple-darwin`. It retains CCminer's Verus Stratum/PBaaS support and uses
ARM hardware AES, PMULL, and NEON through the upstream `sse2neon` layer.

## Build

Install [Homebrew](https://brew.sh), then:

```sh
brew install autoconf automake curl jansson openssl@3
./build-mac-arm.sh
```

The default binary uses an ARMv8 crypto baseline suitable for Apple silicon,
ThinLTO, and an Apple-clang jump-table lowering that avoids three unpredictable
conditional branches in each CLHash round.
For a machine-local binary tuned to the host CPU:

```sh
NATIVE=1 ./build-mac-arm.sh
```

Do not redistribute a native-tuned binary as a general Apple-silicon build;
newer instructions selected by the compiler may not run on older M-series Macs.
On the tested M5, native tuning did not beat the portable build, so the default
is currently recommended.

For a machine- and workload-trained build, run:

```sh
./build-mac-arm-pgo.sh
```

By default this uses the locked Apple M5 profile that produced the best
measured short run, **23.11 MH/s**, and verifies the resulting binary checksum.
It leaves the profile-guided binary at `./ccminer`. The normal portable build
remains available through `./build-mac-arm.sh`.

To train a fresh profile after changing mining code or the compiler, run:

```sh
PGO_PROFILE_MODE=train \
  PGO_TRAIN_SECONDS=5 \
  PGO_TRAIN_THREADS=10 \
  ./build-mac-arm-pgo.sh
```

For a source candidate whose control-flow profile is still compatible with the
locked profile, use:

```sh
PGO_PROFILE_MODE=candidate ./build-mac-arm-pgo.sh
```

Candidate mode uses the exact locked profile and toolchain checks but does not
require the final binary to match the locked checksum. Apple clang ignores
per-function profile data when a candidate changes that function's control
flow; use `PGO_PROFILE_MODE=train` for those experiments.

The current development candidate stages case 4's late `prandex` load across
its AES chain without adding work. Build it with candidate mode. Two clean
order-reversed 8-second pairs averaged 24.155 MH/s versus 23.640 MH/s for the
exact locked binary, a provisional 2.18% gain. It has not yet had a longer
sustained thermal test, so the default locked checksum still refers to the
23.11 MH/s reference build. A conservative 30-second baseline-first comparison
measured 22.69 MH/s for the locked binary and 22.72 MH/s for the candidate, a
neutral-to-slightly-positive 0.13% difference.

Instrumentation makes the training binary much slower than a normal miner, so
it can finish its current work batch after the nominal time limit. PGO profiles
are specific to the source, compiler, and architecture flags; rerun the script
after any of those change. The offline training workload does not exercise pool
networking or share submission, so PGO remains opt-in until accepted-share
testing covers the resulting binary. See [profiles/README.md](profiles/README.md)
for the locked profile's provenance, checksums, and exact toolchain.

For compiler troubleshooting, `LTO=0` disables ThinLTO and
`FORCE_JUMP_TABLES=0` disables the LLVM jump-table override.

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

The default is one 8-second run using all logical CPUs so optimization work can
iterate quickly. Override the duration or test an explicit comma-separated set
of thread counts when needed:

```sh
DURATION=10 THREADS=4,10 ./benchmark-mac-arm.sh
```

Five-second runs are smoke tests only. Reserve 30–60 second confirmations for
promising candidates. Sustained thermal testing can change the best laptop
configuration and should only be run deliberately, not as part of the normal
iteration loop.

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
- Offline VerusHash 2.2.2 benchmark: working for multiple threads.
- Multi-thread nonce-span bug: fixed; upstream otherwise gave workers 1–N
  billion-candidate initial batches and never produced useful aggregate rates.
- Benchmark time-limit shutdown and aggregate reporting: fixed.
- Deterministic full-hash vectors, native/scalar differential checks, and
  dynamic-key restoration checks: working.
- Accepted-share pool validation: still the next correctness gate before
  distributing binaries.

See [RESEARCH.md](RESEARCH.md) for the source audit, licensing notes, and the
optimization roadmap.
