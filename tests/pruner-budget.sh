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
# The maven-proxy cache comes off the host budget before the split.
CACHE_BUDGET_BYTES=1000000 CACHE_BUDGET_PCT=100
mkfile "$RUNNER_DATA_DIR/maven-proxy/a/b/entry" 200000 1
proxy=$(sz "$RUNNER_DATA_DIR/maven-proxy")
[ "$(slot_budget 2)" = $(((1000000 - proxy) / 2)) ] || fail "proxy cache not taken off: $(slot_budget 2)"
CACHE_BUDGET_BYTES=100000
[ "$(slot_budget 2)" = 25000 ] || fail "a proxy cache above the budget: $(slot_budget 2), want half the budget split"
rm -rf "$RUNNER_DATA_DIR/maven-proxy"

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

# An idle slot: no runner has opened its .lock for SLOT_IDLE_DAYS (after
# RUNNERS went down). It takes no share of the budget and is emptied, so the
# active slots get the whole budget.
c3="$(mkslot 3)"
touch -m -d '30 days ago' "$RUNNER_DATA_DIR/slots/3/.lock"
mkunit "$c3/mise-data/installs/tool/v0" 100000 5
CACHE_BUDGET_BYTES=$((per_slot * 2))
out=$(prune_caches)
gone "$c3/mise-data/installs/tool/v0"
grep -q "slot 3: idle" <<<"$out" || fail "slot 3 not reported idle"
for id in 1 2; do
  grep -q "slot $id: budget ${per_slot}B" <<<"$out" || fail "slot $id budget not ${per_slot}B next to an idle slot"
done

# A runner that holds the slot's .lock keeps it active, claimed long ago or not.
mkunit "$c3/mise-data/installs/tool/v2" 100000 5
exec 7<"$RUNNER_DATA_DIR/slots/3/.lock"
flock 7
out=$(prune_caches)
exec 7<&-
kept "$c3/mise-data/installs/tool/v2/data.bin"
if grep -q "slot 3: idle" <<<"$out"; then fail "slot 3 emptied while a runner holds its .lock"; fi

# When every slot is idle (the whole host was stopped), none is emptied.
for id in 1 2 3; do touch -m -d '30 days ago' "$RUNNER_DATA_DIR/slots/$id/.lock"; done
mkunit "$c3/mise-data/installs/tool/v1" 100000 5
out=$(prune_caches)
kept "$c3/mise-data/installs/tool/v1/data.bin"
kept "$RUNNER_DATA_DIR/slots/1/cache/mise-data/installs/tool/v2/data.bin"

finish "budget split evenly across active slots"
