#!/bin/bash
# Shared helpers for tests/pruner-*.sh. Sourced, not run. Needs GNU coreutils,
# find, flock (Linux, or `docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tests/<t>.sh`).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# shellcheck source=pruner.sh
source "$here/../pruner.sh"
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

# mkdirfile <dir> <bytes> <age in days>: a unit with one file of that age.
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

gone() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$1 should be evicted"; }
kept() { [ -e "$1" ] || [ -L "$1" ] || fail "$1 should survive"; }

finish() {
  if [ "$fails" -gt 0 ]; then
    echo "$fails check(s) failed"
    exit 1
  fi
  echo "PASS: $1"
}
