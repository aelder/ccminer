#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/verus-kernel-test.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT
output="${scratch_dir}/verus-kernel-test"
haraka_object="${scratch_dir}/verus-kernel-haraka.o"

compile_flags=(-O3)
link_flags=(-O3)
architecture_flags=(-DARM -DVERUS_TESTING -march=armv8-a+crypto)
if [[ "${TEST_ARCH:-arm64}" == "x86_64" ]]; then
  architecture_flags=(-arch x86_64 -maes -mpclmul -mssse3 -msse4.1)
fi
if [[ "${SANITIZE:-0}" == "1" ]]; then
  compile_flags=(-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined)
  link_flags=(-fsanitize=address,undefined)
fi
if [[ "${TEST_ARCH:-arm64}" != "x86_64" &&
      "${FORCE_JUMP_TABLES:-1}" == "1" ]]; then
  compile_flags+=(
    -mllvm -aarch64-min-jump-table-entries=1
  )
fi

clang \
  -std=gnu11 \
  "${compile_flags[@]}" \
  "${architecture_flags[@]}" \
  -I. \
  -c \
  verus/haraka.c \
  -o "$haraka_object"

clang++ \
  -std=c++11 \
  "${compile_flags[@]}" \
  "${architecture_flags[@]}" \
  -I. \
  tests/verus_kernel_test.cpp \
  verus/verus_clhash.cpp \
  "$haraka_object" \
  "${link_flags[@]}" \
  -o "$output"

"$output" "$@"
