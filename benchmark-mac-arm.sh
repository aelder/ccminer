#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

if [[ ! -x ./ccminer ]]; then
  echo "Run ./build-mac-arm.sh first." >&2
  exit 1
fi

duration="${DURATION:-20}"
max_threads="$(sysctl -n hw.logicalcpu)"
performance_threads="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)"

thread_counts=(1)
if [[ -n "$performance_threads" && "$performance_threads" != "1" ]]; then
  thread_counts+=("$performance_threads")
fi
if [[ "$max_threads" != "1" && "$max_threads" != "$performance_threads" ]]; then
  thread_counts+=("$max_threads")
fi

for threads in "${thread_counts[@]}"; do
  echo
  echo "VerusHash 2.2.2: ${threads} thread(s), ${duration}s"
  ./ccminer -a verus --benchmark --time-limit="$duration" -t "$threads" -b 0
done
