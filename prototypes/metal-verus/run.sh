#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
prototype_dir="$project_dir/prototypes/metal-verus"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/verus-metal.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT

if pgrep -x ccminer >/dev/null 2>&1; then
  echo "Refusing to benchmark while another ccminer process is running." >&2
  exit 1
fi
if pgrep -f '[v]erus-metal-prototype' >/dev/null 2>&1; then
  echo "Refusing to benchmark while another Metal prototype is running." >&2
  exit 1
fi

duration="${DURATION:-5}"
batch="${BATCH:-8192}"
if ! [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
   ! awk -v value="$duration" 'BEGIN { exit !(value > 0 && value <= 10) }'; then
  echo "DURATION must be greater than 0 and no more than 10 seconds." >&2
  exit 1
fi
if ! [[ "$batch" =~ ^[0-9]+$ ]] || (( batch == 0 || batch > 8192 )); then
  echo "BATCH must be an integer from 1 through 8192." >&2
  exit 1
fi

haraka_object="$scratch_dir/haraka.o"
host_binary="$scratch_dir/verus-metal-prototype"

xcrun --sdk macosx clang \
  -std=gnu11 \
  -O3 \
  -DARM \
  -DVERUS_TESTING \
  -march=armv8-a+crypto \
  -I"$project_dir" \
  -c "$project_dir/verus/haraka.c" \
  -o "$haraka_object"

xcrun --sdk macosx clang++ \
  -std=c++11 \
  -O3 \
  -DARM \
  -DVERUS_TESTING \
  -march=armv8-a+crypto \
  -I"$project_dir" \
  -fobjc-arc \
  "$prototype_dir/main.mm" \
  "$project_dir/verus/verus_clhash.cpp" \
  "$haraka_object" \
  -framework Foundation \
  -framework Metal \
  -o "$host_binary"

"$host_binary" \
  "$prototype_dir/verus_clhash.metal" \
  "$duration" \
  "$batch"
