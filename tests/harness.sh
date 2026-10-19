#!/bin/bash
# Test harness shared by tests/*.sh. Sourced, not run. Gives a scratch dir
# ($work, removed on exit), check bookkeeping (fail / gone / kept / finish) and
# at_exit for extra cleanup. Knows nothing about what is under test; the pruner
# fixtures live in tests/lib.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # tests/
# shellcheck disable=SC2034  # used by the tests that source this
root="$(cd "$here/.." && pwd)"                      # repo root
work="$(mktemp -d "${TMPDIR:-/tmp}/test.XXXXXX")"

cleanups=()
# at_exit <command...>: run it when the test ends, before $work is removed.
at_exit() { cleanups+=("$*"); }
run_cleanups() {
  local c
  for c in "${cleanups[@]}"; do eval "$c" || true; done
  rm -rf "$work"
}
trap run_cleanups EXIT

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

gone() { if [ -e "$1" ] || [ -L "$1" ]; then fail "$1 should be evicted"; fi; }
kept() { [ -e "$1" ] || [ -L "$1" ] || fail "$1 should survive"; }

# finish <what passed>: end of a test; fails the run when a check failed.
finish() {
  if [ "$fails" -gt 0 ]; then
    echo "$fails check(s) failed"
    exit 1
  fi
  echo "PASS: $1"
}
