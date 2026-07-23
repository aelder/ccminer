#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh" >&2
  exit 1
fi

required_formulae=(autoconf automake curl jansson openssl@3)
missing_formulae=()
for formula in "${required_formulae[@]}"; do
  if ! brew list --versions "$formula" >/dev/null 2>&1; then
    missing_formulae+=("$formula")
  fi
done

if ((${#missing_formulae[@]})); then
  echo "Install missing dependencies with:" >&2
  echo "  brew install ${missing_formulae[*]}" >&2
  exit 1
fi

brew_prefix="$(brew --prefix)"
curl_prefix="$(brew --prefix curl)"
openssl_prefix="$(brew --prefix openssl@3)"

export CPPFLAGS="-I${brew_prefix}/include -I${curl_prefix}/include -I${openssl_prefix}/include ${CPPFLAGS:-}"
export LDFLAGS="-L${brew_prefix}/lib -L${curl_prefix}/lib -L${openssl_prefix}/lib ${LDFLAGS:-}"

cpu_flags="-O3"
if [[ "${NATIVE:-0}" == "1" ]]; then
  cpu_flags="${cpu_flags} -mcpu=native"
fi

if [[ -f Makefile ]]; then
  make clean
fi

./autogen.sh
./configure --host=aarch64-apple-darwin CFLAGS="$cpu_flags" CXXFLAGS="$cpu_flags"
make -j "$(sysctl -n hw.logicalcpu)"

echo
file ./ccminer
echo "Built ${project_dir}/ccminer"
