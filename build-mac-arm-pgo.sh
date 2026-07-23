#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

profile_mode="${PGO_PROFILE_MODE:-candidate}"
train_seconds="${PGO_TRAIN_SECONDS:-5}"
train_threads="${PGO_TRAIN_THREADS:-$(sysctl -n hw.logicalcpu)}"
reference_profile_text="${project_dir}/profiles/apple-m5-verus-20260722.proftext"
reference_profile_sha256="c7307423156d8aa33cc79920fff28f7a3086fbc2f30b481c2fffafecfb211597"

if [[ "$profile_mode" != "candidate" &&
      "$profile_mode" != "train" ]]; then
  echo "PGO_PROFILE_MODE must be 'candidate' or 'train'" >&2
  exit 1
fi
if ! [[ "$train_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "PGO_TRAIN_SECONDS must be a positive integer" >&2
  exit 1
fi
if ! [[ "$train_threads" =~ ^[1-9][0-9]*$ ]]; then
  echo "PGO_TRAIN_THREADS must be a positive integer" >&2
  exit 1
fi
if pgrep -x ccminer >/dev/null; then
  echo "Stop the existing ccminer process before building the PGO miner" >&2
  exit 1
fi
if [[ "$profile_mode" == "candidate" ]]; then
  if [[ "${LTO:-1}" != "1" ||
        "${NATIVE:-0}" != "0" ||
        "${FORCE_JUMP_TABLES:-1}" != "1" ||
        -n "${EXTRA_FLAGS:-}" ]]; then
    echo "The checked-in candidate profile requires LTO=1, NATIVE=0," \
      "FORCE_JUMP_TABLES=1," \
      "and no EXTRA_FLAGS" >&2
    exit 1
  fi
  compiler_version="$(clang --version | head -n 1)"
  if [[ "$compiler_version" != "Apple clang version 21.0.0 (clang-2100.1.1.101)" ]]; then
    echo "The checked-in candidate profile requires Apple clang 21.0.0" \
      "(clang-2100.1.1.101)" >&2
    exit 1
  fi
  if [[ ! -f "$reference_profile_text" ]]; then
    echo "Missing candidate profile: ${reference_profile_text}" >&2
    exit 1
  fi
fi

profile_root="$(mktemp -d "${TMPDIR:-/tmp}/verus-pgo.XXXXXX")"
raw_dir="${profile_root}/raw"
mkdir "$raw_dir"

cleanup() {
  if [[ -d "$profile_root" ]]; then
    rm -r "$profile_root"
  fi
}
trap cleanup EXIT

# Configure a normal build first so architecture, dependency, jump-table, and
# linker settings exactly match the generation and profile-use phases.
./build-mac-arm.sh

cpu_flags="-O3"
if [[ "${LTO:-1}" == "1" ]]; then
  cpu_flags="${cpu_flags} -flto=thin"
fi
if [[ "${NATIVE:-0}" == "1" ]]; then
  cpu_flags="${cpu_flags} -mcpu=native"
fi
if [[ -n "${EXTRA_FLAGS:-}" ]]; then
  cpu_flags="${cpu_flags} ${EXTRA_FLAGS}"
fi

profile_data="${profile_root}/ccminer.profdata"
if [[ "$profile_mode" == "candidate" ]]; then
  echo
  echo "Reconstructing the Apple M5 profile for the candidate build"
  xcrun llvm-profdata merge --instr \
    -o "$profile_data" \
    "$reference_profile_text"
  actual_profile_sha256="$(shasum -a 256 "$profile_data" | awk '{print $1}')"
  if [[ "$actual_profile_sha256" != "$reference_profile_sha256" ]]; then
    echo "Candidate profile checksum mismatch" >&2
    exit 1
  fi
else
  generate_flags=(
    "-fprofile-instr-generate=${profile_root}/default-%p.profraw"
    "-fprofile-update=atomic"
  )

  make clean
  make -j "$(sysctl -n hw.logicalcpu)" \
    CFLAGS="${cpu_flags} ${generate_flags[*]}" \
    CXXFLAGS="${cpu_flags} ${generate_flags[*]}"
  cp ./ccminer "${profile_root}/ccminer-instrumented"

  echo
  echo "Training the instrumented Verus miner (${train_threads} threads," \
    "${train_seconds}s nominal time limit)"
  LLVM_PROFILE_FILE="${raw_dir}/ccminer-%p-%m.profraw" \
    "${profile_root}/ccminer-instrumented" \
    -a verus --benchmark --time-limit="$train_seconds" \
    -t "$train_threads" -b 0 -q

  profile_inputs=("${raw_dir}"/ccminer-*.profraw)
  if [[ ! -e "${profile_inputs[0]}" ]]; then
    echo "PGO training did not produce a raw profile" >&2
    exit 1
  fi

  xcrun llvm-profdata merge --instr --failure-mode=any \
    -o "$profile_data" \
    "${profile_inputs[@]}"
fi

use_flags=("-fprofile-instr-use=${profile_data}")
make clean
make -j "$(sysctl -n hw.logicalcpu)" \
  CFLAGS="${cpu_flags} ${use_flags[*]}" \
  CXXFLAGS="${cpu_flags} ${use_flags[*]}"

echo
file ./ccminer
echo "Built PGO-optimized ${project_dir}/ccminer"
