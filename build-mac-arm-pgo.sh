#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

profile_mode="${PGO_PROFILE_MODE:-locked}"
train_seconds="${PGO_TRAIN_SECONDS:-5}"
train_threads="${PGO_TRAIN_THREADS:-$(sysctl -n hw.logicalcpu)}"
locked_profile_text="${project_dir}/profiles/apple-m5-verus-20260722.proftext"
locked_profile_sha256="c7307423156d8aa33cc79920fff28f7a3086fbc2f30b481c2fffafecfb211597"
locked_binary_sha256="4be0d7e1b388184d3d02df8eb57a019869a503a3c37440f428f3ef65a7e6d6f7"

if [[ "$profile_mode" != "locked" && "$profile_mode" != "train" ]]; then
  echo "PGO_PROFILE_MODE must be 'locked' or 'train'" >&2
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
if [[ "$profile_mode" == "locked" ]]; then
  if [[ "${LTO:-1}" != "1" ||
        "${NATIVE:-0}" != "0" ||
        "${FORCE_JUMP_TABLES:-1}" != "1" ||
        -n "${EXTRA_FLAGS:-}" ]]; then
    echo "Locked PGO requires LTO=1, NATIVE=0, FORCE_JUMP_TABLES=1," \
      "and no EXTRA_FLAGS" >&2
    exit 1
  fi
  compiler_version="$(clang --version | head -n 1)"
  if [[ "$compiler_version" != "Apple clang version 21.0.0 (clang-2100.1.1.101)" ]]; then
    echo "Locked PGO requires Apple clang 21.0.0 (clang-2100.1.1.101)" >&2
    exit 1
  fi
  if [[ ! -f "$locked_profile_text" ]]; then
    echo "Missing locked profile: ${locked_profile_text}" >&2
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
if [[ "$profile_mode" == "locked" ]]; then
  echo
  echo "Reconstructing the locked 23.11 MH/s Apple M5 profile"
  xcrun llvm-profdata merge --instr \
    -o "$profile_data" \
    "$locked_profile_text"
  actual_profile_sha256="$(shasum -a 256 "$profile_data" | awk '{print $1}')"
  if [[ "$actual_profile_sha256" != "$locked_profile_sha256" ]]; then
    echo "Locked profile checksum mismatch" >&2
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
if [[ "$profile_mode" == "locked" ]]; then
  actual_binary_sha256="$(shasum -a 256 ./ccminer | awk '{print $1}')"
  if [[ "$actual_binary_sha256" != "$locked_binary_sha256" ]]; then
    echo "Locked PGO binary checksum mismatch:" >&2
    echo "  expected ${locked_binary_sha256}" >&2
    echo "  actual   ${actual_binary_sha256}" >&2
    exit 1
  fi
  echo "Verified locked binary SHA-256 ${actual_binary_sha256}"
fi
echo "Built PGO-optimized ${project_dir}/ccminer"
