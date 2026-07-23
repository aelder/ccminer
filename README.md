# ccminer Verus for Apple silicon

This fork is now deliberately narrow: a native `arm64` VerusHash 2.2.2 CPU
miner for Apple-silicon macOS. The Windows, CUDA, x86, FreeBSD, bundled
dependency, generic Equihash solver, and unused portable Verus source bundles
have been removed from the primary branch.

On an Apple M5 MacBook Air, the current CPU candidate measured **24.10 MH/s**
over 30 seconds with 10 threads, up 59.3% from the first correct 15.13 MH/s
native baseline. This was not a sustained thermal test. Two short LuckPool
sessions subsequently produced four accepted shares and zero rejects.

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
