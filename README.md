# ccminer Verus for Apple silicon

This fork is now deliberately narrow: a native `arm64` VerusHash 2.2.2 CPU
miner for Apple-silicon macOS. The Windows, CUDA, x86, FreeBSD, bundled
dependency, generic Equihash solver, and unused portable Verus source bundles
have been removed from the primary branch.

On an Apple M5 MacBook Air, the current CPU candidate measured **24.10 MH/s**
over 30 seconds with 10 threads, up 59.3% from the first correct 15.13 MH/s
native baseline. This was not a sustained thermal test. Two short LuckPool
sessions subsequently produced four accepted shares and zero rejects.

## What produced the performance gains

- Built a real native `arm64` binary and used Apple silicon's hardware AES,
  PMULL, and NEON instructions through `sse2neon`.
- Fixed the multi-thread benchmark's nonce-span, synchronization, deadline,
  and accounting bugs so optimization decisions used real aggregate hashrate.
- Interleaved two independent CLHash lanes per worker to hide PMULL, AES,
  division, and random-load latency. Together with packed mutation logs,
  ThinLTO, and jump-table lowering, this moved the 10-thread result from
  15.13 to 22.95 MH/s.
- Packed both mutated-key indices into one log entry and restored from a
  pristine key with alias-safe ordering, reducing hot-path state traffic.
- Forced Apple clang to lower the random eight-way CLHash switch as a jump
  table; this beat its conditional-branch lowering by 7.0% in the focused
  comparison.
- Trained the whole miner with profile-guided optimization. Interleaved tests
  measured a 4.8% gain over the equivalent non-PGO build.
- Staged case 4's late random load ahead of its AES dependency chain, giving
  it roughly 55–82 instructions of latency cover. Clean short pairs measured
  a 2.18% gain.
- Kept the normal macOS scheduler and all 10 cores active. The six additional
  workers beyond the four performance cores contributed substantial
  throughput.
- Controlled GUI/display contention for the confirmation run; minimizing the
  Chromium-based UI raised the same candidate from 22.72 to 24.10 MH/s.

## What we tried that did not help

- `-mcpu=native`: 14.74 MH/s versus the 15.13 MH/s portable ARMv8 baseline.
- A 4-normal/6-utility P/E-core QoS split: worker migration erased the intended
  specialization and did not reliably beat the default scheduler.
- Combining both lane switches into one 64-way dispatcher: increased code
  size and fell to 18.38 MH/s.
- Passing the accumulator in SSA form, hoisting common key/buffer loads, and
  manually unrolling variable-round cases: all reduced whole-miner throughput.
- Prefetching future random-key locations: the broad version lost 10.14%; a
  narrower case-4 prefetch was still 0.31% slower.
- Replacing repeated signed remainders with reciprocal arithmetic: enlarged
  the hot kernel and lost 1.09%.
- A dual keyed-Haraka primitive: the isolated primitive gained about 6.5%,
  but integration lost 1.9% because Haraka was only about 2.3% of worker time
  and the change disturbed the whole-miner PGO layout.
- Staging or interleaving pristine-key restores: focused assembly or helper
  results improved, but complete-miner comparisons lost 0.38–0.75%.
- Staging case 3's random load across signed division: 0.82% slower.
- A specialized keyed-Haraka filter with fewer stores: 0.89% slower despite
  passing 100,010 equivalence cases.
- A correct Metal GPU prototype: only 2.150 MH/s alone and 1.648 MH/s beside
  the CPU miner, before production target scanning and share submission.

The detailed measurements, ordering, and caveats are in
[BENCHMARKS.md](BENCHMARKS.md). Failed experiments remain documented so they
are not accidentally repeated.

Build the checked-in M5-profile candidate:

```sh
xcode-select --install
brew install autoconf automake curl jansson openssl@3
git submodule update --init --recursive
./build-mac-arm-pgo.sh
```

Use `./build-mac-arm.sh` for a portable, non-PGO Apple-silicon binary. See
[README-MAC-ARM.md](README-MAC-ARM.md) for the reproducible build, correctness
tests, benchmark conditions, optimization history, P/E-core findings, Metal
prototype results, pool-mining syntax, and current limitations.
