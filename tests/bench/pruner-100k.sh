#!/bin/bash
# Timing of one pruner pass over a synthetic cache of ~100k evictable units
# (50k bun packages, 30k gradle module versions, 20k npm cache files), with a
# budget at 90% of its size so about a tenth gets evicted. Not a test: CI only
# runs tests/*.sh. Needs GNU tools; on macOS:
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tests/bench/pruner-100k.sh [scale-percent]
# Prints the unit count, the time of the collect phase alone, and of a full
# prune_caches pass (collect + sort + evict).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scale="${1:-100}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# shellcheck source=pruner.sh
source "${PRUNER_SH:-$here/pruner.sh}"
RUNNER_DATA_DIR="$work/data"
ACTION_CACHE_DIR="$work/no-action-cache"
CACHE_BUDGET_PCT=100

# mkfiles <name>: read dirs on stdin, create each with a file <name> in it,
# atimes spread over 50 ages.
mkfiles() {
  local file="$1" list="$work/list" k
  cat >"$list"
  xargs -r -a "$list" -n 2000 -P 4 mkdir -p
  for k in $(seq 0 49); do
    awk -v k="$k" -v f="$file" 'NR % 50 == k {print $0 "/" f}' "$list" >"$work/files"
    # shellcheck disable=SC2016  # expands in the child shell
    xargs -r -a "$work/files" -n 2000 sh -c 'for p; do printf "%1024s" x >"$p"; done' _
    xargs -r -a "$work/files" -n 2000 touch -a -d "$((k + 1)) days ago"
  done
}

slot="$RUNNER_DATA_DIR/slots/1"
cache="$slot/cache"
mkdir -p "$cache" "$slot/work"

seq 1 $((50000 * scale / 100)) |
  awk -v d="$cache/bun/install/cache" '{print d "/pkg" $1 "@1.0.0@@@1"}' | mkfiles package.json
seq 1 $((30000 * scale / 100)) |
  awk -v d="$cache/gradle/caches/modules-2/files-2.1" '{print d "/org.g" $1 "/lib/1.0.0/h"}' | mkfiles lib.jar
seq 1 $((20000 * scale / 100)) |
  awk -v d="$cache/npm/_cacache" '{print d "/c" $1}' | mkfiles f
echo "fixture: $(find "$cache" -type f | wc -l) files"

CACHE_BUDGET_BYTES=$(($(dir_bytes "$cache") * 9 / 10))

start=$EPOCHREALTIME
units=$(for s in bun gradle npm; do collect_units "$s" "$cache/$s"; done | tr -cd '\0' | wc -c)
end=$EPOCHREALTIME
echo "units:   $units"
echo "collect: $(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.1f", b - a }') s"

start=$EPOCHREALTIME
prune_caches >"$work/prune.log" 2>&1; rc=$?
end=$EPOCHREALTIME
echo "pass:    $(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.1f", b - a }') s (collect + sort + evict, rc=$rc)"
tail -n 3 "$work/prune.log"
