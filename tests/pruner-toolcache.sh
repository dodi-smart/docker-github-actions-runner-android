#!/bin/bash
# toolcache: <tool>/<ver> is evicted whole, taking its <arch>.complete marker
# with it so setup-* actions never see a "complete" tool that is gone. Needs GNU tools:
#   bash tests/pruner-toolcache.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

cache0="$(mkslot 1)"
t="$cache0/toolcache"

# mktool <tool> <ver> <age in days>
mktool() {
  mkfile "$t/$1/$2/x64/bin/$1" 100000 "$3"
  touch -a -d "$3 days ago" "$t/$1/$2/x64.complete"
}
mktool node 18.0.0 90
mktool node 20.0.0 1
mktool Python 3.9.0 80 # the only Python version

CACHE_BUDGET_BYTES=$(budget_without "$cache0" "$t/node/18.0.0" "$t/Python/3.9.0")
prune_caches >/dev/null

gone "$t/node/18.0.0"
gone "$t/node/18.0.0/x64.complete"
gone "$t/Python"
kept "$t/node/20.0.0/x64/bin/node"
kept "$t/node/20.0.0/x64.complete"

finish "toolcache version evicted with its .complete marker"
