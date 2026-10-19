#!/bin/bash
# rustup: whole toolchains are evicted, except the default one named in
# settings.toml (which may be given by its short name). Needs GNU tools:
#   bash tests/pruner-rustup.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

# mkrustup <cache dir> <default_toolchain>
mkrustup() {
  local r="$1/rustup"
  mkdir -p "$r"
  printf 'version = "12"\ndefault_toolchain = "%s"\nprofile = "minimal"\n' "$2" >"$r/settings.toml"
  mkunit "$r/toolchains/stable-x86_64-unknown-linux-gnu" 200000 400 # oldest, but the default
  mkunit "$r/toolchains/1.70.0-x86_64-unknown-linux-gnu" 100000 90
  mkunit "$r/toolchains/nightly-2024-01-01-x86_64-unknown-linux-gnu" 100000 80
  mkunit "$r/toolchains/1.80.0-x86_64-unknown-linux-gnu" 100000 1
}

for default in stable-x86_64-unknown-linux-gnu stable; do
  rm -rf "$RUNNER_DATA_DIR/slots"
  c="$(mkslot 1)"
  mkrustup "$c" "$default"
  t="$c/rustup/toolchains"
  CACHE_BUDGET_BYTES=$(budget_without "$c" "$t/1.70.0-x86_64-unknown-linux-gnu" \
    "$t/nightly-2024-01-01-x86_64-unknown-linux-gnu")
  prune_caches >/dev/null
  gone "$t/1.70.0-x86_64-unknown-linux-gnu"
  gone "$t/nightly-2024-01-01-x86_64-unknown-linux-gnu"
  kept "$t/1.80.0-x86_64-unknown-linux-gnu/data.bin"
  kept "$t/stable-x86_64-unknown-linux-gnu/data.bin"

  # No budget at all: everything but the default goes.
  CACHE_BUDGET_BYTES=1
  prune_caches >/dev/null
  gone "$t/1.80.0-x86_64-unknown-linux-gnu"
  kept "$t/stable-x86_64-unknown-linux-gnu/data.bin"
  kept "$c/rustup/settings.toml"
done

finish "rustup default toolchain protected"
