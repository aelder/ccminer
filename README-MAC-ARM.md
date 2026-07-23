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

The default binary uses an ARMv8 crypto baseline suitable for Apple silicon.
For a machine-local binary tuned to the host CPU:

```sh
NATIVE=1 ./build-mac-arm.sh
```

Do not redistribute a native-tuned binary as a general Apple-silicon build;
newer instructions selected by the compiler may not run on older M-series Macs.
On the tested M5, native tuning did not beat the portable build, so the default
is currently recommended.

## Benchmark

```sh
./benchmark-mac-arm.sh
```

Set `DURATION=60` or longer for more stable results. The script measures one
thread, the reported performance-core count, and all logical CPUs. Sustained
laptop performance should be tested for at least 10–20 minutes because heat and
power mode can change the best thread count.

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
- Daemon-equivalent test vectors and accepted-share pool validation: still the
  next correctness gate before distributing binaries.

See [RESEARCH.md](RESEARCH.md) for the source audit, licensing notes, and the
optimization roadmap.
