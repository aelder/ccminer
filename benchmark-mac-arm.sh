#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

if [[ ! -x ./ccminer ]]; then
  echo "Run ./build-mac-arm.sh first." >&2
  exit 1
fi

duration="${DURATION:-8}"
max_threads="$(sysctl -n hw.logicalcpu)"

if [[ -n "${THREADS:-}" ]]; then
  IFS=',' read -r -a thread_counts <<< "$THREADS"
else
  thread_counts=("$max_threads")
fi

for threads in "${thread_counts[@]}"; do
  echo
  echo "VerusHash 2.2.2: ${threads} thread(s), ${duration}s"
  ./ccminer -a verus --benchmark --time-limit="$duration" \
    -t "$threads" -b 0 -q
done
