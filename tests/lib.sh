#!/bin/bash
# Fixtures for tests/pruner-*.sh: pruner.sh sourced against a throwaway
# RUNNER_DATA_DIR, on top of tests/harness.sh. Sourced, not run. Needs GNU
# coreutils, find, flock (Linux, or
# `docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tests/<t>.sh`).

# shellcheck source=tests/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

# shellcheck source=pruner.sh
source "$root/pruner.sh"
RUNNER_DATA_DIR="$work/data"
ACTION_CACHE_DIR="$work/no-action-cache"
CACHE_BUDGET_PCT=100 # the byte budget decides, whatever the test fs is

# mkslot <id>: create slot <id> and print its cache dir.
mkslot() {
  mkdir -p "$RUNNER_DATA_DIR/slots/$1/cache" "$RUNNER_DATA_DIR/slots/$1/work"
  touch "$RUNNER_DATA_DIR/slots/$1/.lock"
  echo "$RUNNER_DATA_DIR/slots/$1/cache"
}

sz() { du -sb "$1" | awk '{printf "%.0f\n", $1}'; }

# stores_bytes <cache dir>: what the pruner counts for a slot.
stores_bytes() {
  local d total=0
  for d in "$1"/*/; do total=$((total + $(sz "$d"))); done
  echo "$total"
}

# mkfile <path> <bytes> <atime age in days>
mkfile() {
  mkdir -p "$(dirname "$1")"
  head -c "$2" /dev/urandom >"$1"
  touch -a -d "$3 days ago" "$1"
}

# mkunit <dir> <bytes> <age in days>: a unit with one file of that age.
mkunit() {
  mkfile "$1/data.bin" "$2" "$3"
}

# budget_without <cache dir> <unit>...: a budget that makes exactly <unit>s
# (the oldest ones) go and nothing more: now minus them, plus slack that is far
# below any unit's size.
budget_without() {
  local cache="$1" total u
  shift
  total=$(stores_bytes "$cache")
  for u in "$@"; do total=$((total - $(sz "$u"))); done
  echo $((total + 20000))
}
