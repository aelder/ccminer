#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/verus-kernel-test.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT
output="${scratch_dir}/verus-kernel-test"
haraka_object="${scratch_dir}/verus-kernel-haraka.o"
baseline_object="${scratch_dir}/verus-kernel-baseline.o"

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

test_defines=(-DVERUS_TESTING)
extra_objects=("$haraka_object")
baseline_revision="${VERUS_BASELINE_REV:-}"
if [[ -n "$baseline_revision" ]]; then
  case "${1:-}" in
    --differential-dual|--compare-dual|--bench-dual|--bench-dual-baseline) ;;
    *)
      echo "VERUS_BASELINE_REV supports --differential-dual," \
        "--compare-dual, and dual benchmark modes" >&2
      exit 1
      ;;
  esac
  test_defines+=(-DVERUS_HAVE_BASELINE)
  git show "${baseline_revision}:verus/verus_clhash.cpp" |
    clang++ \
      -x c++ \
      -std=c++11 \
      "${compile_flags[@]}" \
      "${architecture_flags[@]}" \
      -I. \
      -Iverus \
      -Dverusclhashv2_2=baseline_verusclhashv2_2 \
      -Dverusclhashv2_2_dual=baseline_verusclhashv2_2_dual \
      -D__verusclmulwithoutreduction64alignedrepeatv2_2=baseline___verusclmulwithoutreduction64alignedrepeatv2_2 \
      -DprecompReduction64=baseline_precompReduction64 \
      -DprecompReduction64_si128=baseline_precompReduction64_si128 \
      -DlazyLengthHash=baseline_lazyLengthHash \
      -Dverus_test_mulhrs_epi16=baseline_verus_test_mulhrs_epi16 \
      -D__cpuverusoptimized=baseline___cpuverusoptimized \
      -c \
      -o "$baseline_object" \
      -
  extra_objects+=("$baseline_object")
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
  "${test_defines[@]}" \
  -I. \
  tests/verus_kernel_test.cpp \
  verus/verus_clhash.cpp \
  "${extra_objects[@]}" \
  "${link_flags[@]}" \
  -o "$output"

"$output" "$@"
