#!/bin/bash
# Job safety: a slot with a fresh `busy` marker is skipped, one with a stale
# marker (> 6 h) is pruned, and a slot whose .prune.lock is held is skipped.
# Needs GNU tools and flock:
#   bash tests/pruner-busy.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

unit() { echo "$RUNNER_DATA_DIR/slots/$1/cache/mise-data/installs/node/20.0.0"; }
for id in 1 2 3 4; do
  mkslot "$id" >/dev/null
  mkunit "$(unit "$id")" 100000 30
done
touch "$RUNNER_DATA_DIR/slots/1/busy"                  # job running
touch -d '7 hours ago' "$RUNNER_DATA_DIR/slots/2/busy" # crashed job's leftover
# slot 3: idle
( flock 8; sleep 60 ) 8>"$RUNNER_DATA_DIR/slots/4/.prune.lock" & # another pruner
holder=$!
sleep 1

CACHE_BUDGET_BYTES=1
out=$(prune_caches)
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

kept "$(unit 1)/data.bin"
gone "$(unit 2)"
gone "$(unit 3)"
kept "$(unit 4)/data.bin"
grep -q 'slot 1: job running' <<<"$out" || fail "no log line for the busy slot"
grep -q 'slot 2: stale busy' <<<"$out" || fail "no log line for the stale busy marker"
grep -q 'slot 4: another prune' <<<"$out" || fail "no log line for the locked slot"
grep -q 'slot 3: took [0-9]*s' <<<"$out" || fail "no elapsed log line"
[ -e "$RUNNER_DATA_DIR/slots/1/busy" ] || fail "busy marker removed by the pruner"

finish "busy slot skipped, stale busy pruned, locked slot skipped"
