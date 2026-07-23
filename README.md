# ccminer

## Apple silicon

This fork now has a native `arm64` VerusHash 2.2.2 path for Apple silicon.
On an Apple M5 MacBook Air, the current CPU candidate measured **24.10 MH/s**
over 30 seconds with 10 threads, up 59.3% from the initial 15.13 MH/s native
baseline. This is not a sustained thermal result. Live Stratum/PBaaS testing
subsequently produced four accepted shares with zero rejects across two short
LuckPool sessions.

See [README-MAC-ARM.md](README-MAC-ARM.md) for the reproducible build,
correctness tests, benchmark conditions, optimization history, P/E-core
findings, Metal prototype results, and current limitations.

Based on Christian Buchner's &amp; Christian H.'s CUDA project, no more active on github since 2014.

Check the [README.txt](README.txt) for the additions

BTC donation address: 1AJdfCpLWPNoAMDfHF1wD5y8VgKSSTHxPo (tpruvot)

A part of the recent algos were originally written by [djm34](https://github.com/djm34) and [alexis78](https://github.com/alexis78)

This variant was tested and built on Linux (ubuntu server 14.04, 16.04, Fedora 22 to 25)
It is also built for Windows 7 to 10 with VStudio 2013, to stay compatible with Windows 7 and Vista.

Note that the x86 releases are generally faster than x64 ones on Windows, but that tend to change with the recent drivers.

The recommended CUDA Toolkit version was the [6.5.19](http://developer.download.nvidia.com/compute/cuda/6_5/rel/installers/cuda_6.5.19_windows_general_64.exe), but some light algos could be faster with the version 7.5 and 8.0 (like lbry, decred and skein).

About source code dependencies
------------------------------

This project requires some libraries to be built :

- OpenSSL (prebuilt for win)
- Curl (prebuilt for win)
- pthreads (prebuilt for win)

The tree now contains recent prebuilt openssl and curl .lib for both x86 and x64 platforms (windows).

To rebuild them, you need to clone this repository and its submodules :
    git clone https://github.com/peters/curl-for-windows.git compat/curl-for-windows


Compile on Linux
----------------

Please see [INSTALL](https://github.com/tpruvot/ccminer/blob/linux/INSTALL) file or [project Wiki](https://github.com/tpruvot/ccminer/wiki/Compatibility)


Compile on FreeBSD
------------------

Make sure you have `gmake` installed from the ports tree. Use `build-freebsd.sh`


Compile on Apple silicon macOS
--------------------------------

Do not use the legacy `build.sh` for a native Apple-silicon build. Follow
[README-MAC-ARM.md](README-MAC-ARM.md); the short version is:

```sh
xcode-select --install
brew install autoconf automake curl jansson openssl@3
PGO_PROFILE_MODE=candidate ./build-mac-arm-pgo.sh
```

The current fastest source uses the checked-in Apple M5 profile in candidate
mode. Use `./build-mac-arm.sh` instead for a portable, non-PGO Apple-silicon
binary.
