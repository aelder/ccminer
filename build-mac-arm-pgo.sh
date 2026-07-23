#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

train_seconds="${PGO_TRAIN_SECONDS:-5}"
train_threads="${PGO_TRAIN_THREADS:-$(sysctl -n hw.logicalcpu)}"

if ! [[ "$train_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "PGO_TRAIN_SECONDS must be a positive integer" >&2
  exit 1
fi
if ! [[ "$train_threads" =~ ^[1-9][0-9]*$ ]]; then
  echo "PGO_TRAIN_THREADS must be a positive integer" >&2
  exit 1
fi
if pgrep -x ccminer >/dev/null; then
  echo "Stop the existing ccminer process before starting PGO training" >&2
  exit 1
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
  -o "${profile_root}/ccminer.profdata" \
  "${profile_inputs[@]}"

use_flags=("-fprofile-instr-use=${profile_root}/ccminer.profdata")
make clean
make -j "$(sysctl -n hw.logicalcpu)" \
  CFLAGS="${cpu_flags} ${use_flags[*]}" \
  CXXFLAGS="${cpu_flags} ${use_flags[*]}"

echo
file ./ccminer
echo "Built PGO-optimized ${project_dir}/ccminer"
