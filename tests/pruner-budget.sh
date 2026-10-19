#!/bin/bash
# Budget: min(CACHE_BUDGET_BYTES, CACHE_BUDGET_PCT% of the filesystem) split
# evenly over the slots, each slot ranked on its own (not one LRU across slots).
# Needs GNU tools:
#   bash tests/pruner-budget.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

# slot_budget arithmetic.
mkdir -p "$RUNNER_DATA_DIR"
CACHE_BUDGET_BYTES=1000 CACHE_BUDGET_PCT=100
[ "$(slot_budget 2)" = 500 ] || fail "1000B over 2 slots: $(slot_budget 2)"
fs=$(df -B1 --output=size "$RUNNER_DATA_DIR" | awk 'NR == 2 {print $1}')
CACHE_BUDGET_BYTES=$((fs * 2)) CACHE_BUDGET_PCT=10
[ "$(slot_budget 4)" = $((fs * 10 / 100 / 4)) ] || fail "10% of the fs over 4 slots: $(slot_budget 4)"

# Two slots, three 100000 B units each. Slot 2's units are all newer than
# slot 1's: a global LRU would empty slot 1 first; per slot, each loses just
# its own oldest unit.
for id in 1 2; do
  c="$(mkslot "$id")"
  if [ "$id" = 1 ]; then ages=(90 80 70); else ages=(30 20 10); fi
  for i in 0 1 2; do mkunit "$c/mise-data/installs/tool/v$i" 100000 "${ages[$i]}"; done
done
per_slot=$(budget_without "$RUNNER_DATA_DIR/slots/1/cache" "$RUNNER_DATA_DIR/slots/1/cache/mise-data/installs/tool/v0")
CACHE_BUDGET_BYTES=$((per_slot * 2)) CACHE_BUDGET_PCT=100
out=$(prune_caches)
for id in 1 2; do
  u="$RUNNER_DATA_DIR/slots/$id/cache/mise-data/installs/tool"
  gone "$u/v0"
  kept "$u/v1/data.bin"
  kept "$u/v2/data.bin"
  grep -q "slot $id: budget ${per_slot}B" <<<"$out" || fail "slot $id budget not ${per_slot}B"
done

finish "budget split evenly across slots"
