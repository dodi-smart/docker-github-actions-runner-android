#!/bin/bash
# Work dir: each work/<repo> checkout is one unit, evicted whole, least
# recently used first, within WORK_BUDGET_BYTES per slot; the runner's own
# work/_* dirs stay. Needs GNU tools:
#   bash tests/pruner-work.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

CACHE_BUDGET_BYTES=1000000000
mkslot 1 >/dev/null
w="$RUNNER_DATA_DIR/slots/1/work"
mkfile "$w/old-app/old-app/build/out.bin" 300000 60
mkfile "$w/old-app/old-app/.git/HEAD" 100 60
mkfile "$w/mid-app/mid-app/src/main.kt" 300000 20
mkfile "$w/new-app/new-app/src/main.kt" 300000 1
mkfile "$w/_actions/actions/checkout/v6/action.yml" 300000 90
mkfile "$w/_PipelineMapping/dodi-smart/old-app/PipelineFolder.json" 100 90

# No limit: nothing goes.
WORK_BUDGET_BYTES=0
out=$(prune_caches)
kept "$w/old-app/old-app/build/out.bin"
grep -q "work dir budget" <<<"$out" && fail "work dir pruned with WORK_BUDGET_BYTES=0"

# Room for two checkouts plus the runner's dirs: the oldest checkout goes whole.
WORK_BUDGET_BYTES=$(( $(sz "$w") - $(sz "$w/old-app") + 20000 ))
out=$(prune_caches)
grep -q "slot 1: work dir budget ${WORK_BUDGET_BYTES}B" <<<"$out" || fail "work dir budget not logged: $out"
gone "$w/old-app"
kept "$w/mid-app/mid-app/src/main.kt"
kept "$w/new-app/new-app/src/main.kt"
kept "$w/_actions/actions/checkout/v6/action.yml"
kept "$w/_PipelineMapping/dodi-smart/old-app/PipelineFolder.json"

# A busy slot is left alone.
touch "$RUNNER_DATA_DIR/slots/1/busy"
WORK_BUDGET_BYTES=1
prune_caches >/dev/null
kept "$w/mid-app/mid-app/src/main.kt"
rm "$RUNNER_DATA_DIR/slots/1/busy"

# An idle slot loses every checkout, next to an active one that keeps its own.
mkslot 2 >/dev/null
mkfile "$RUNNER_DATA_DIR/slots/2/work/app/app/src/main.kt" 1000 1
touch -m -d '30 days ago' "$RUNNER_DATA_DIR/slots/1/.lock"
WORK_BUDGET_BYTES=$((1024 * 1024 * 1024))
prune_caches >/dev/null
gone "$w/mid-app"
gone "$w/new-app"
kept "$w/_actions/actions/checkout/v6/action.yml"
kept "$RUNNER_DATA_DIR/slots/2/work/app/app/src/main.kt"

finish "work dirs evicted whole per repo, runner dirs kept"
