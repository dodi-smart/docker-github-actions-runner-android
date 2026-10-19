#!/bin/bash
# pnpm: the store is all-or-nothing, ranked by its newest atime. Never a file
# or two out of a store (pnpm trusts the files its index lists). Needs GNU tools:
#   bash tests/pruner-pnpm.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

# mkstore <cache dir> <newest atime age in days>: a store with one very old
# file and one file of the given age.
mkstore() {
  mkfile "$1/pnpm/store/v10/files/aa/old-file" 100000 300
  mkfile "$1/pnpm/store/v10/files/bb/newest-file" 100000 "$2"
}

# Slot 1: the pnpm store (newest atime 10 d) is older than a gradle unit (1 d):
# the whole store must go, even though dropping its 300 d file would do.
c1="$(mkslot 1)"
mkstore "$c1" 10
mkunit "$c1/gradle/caches/transforms-4/h" 100000 1
CACHE_BUDGET_BYTES=$(($(stores_bytes "$c1") - 150000))
prune_caches >/dev/null
gone "$c1/pnpm/store"
kept "$c1/gradle/caches/transforms-4/h/data.bin"

# Slot 2: the store is the most recently used, so the gradle unit goes and the
# store stays untouched, including its 300 d file.
rm -rf "$RUNNER_DATA_DIR/slots/1"
c2="$(mkslot 2)"
mkstore "$c2" 1
mkunit "$c2/gradle/caches/transforms-4/h" 100000 10
CACHE_BUDGET_BYTES=$(($(stores_bytes "$c2") - 50000))
prune_caches >/dev/null
gone "$c2/gradle/caches/transforms-4/h"
kept "$c2/pnpm/store/v10/files/aa/old-file"
kept "$c2/pnpm/store/v10/files/bb/newest-file"

finish "pnpm store evicted whole or not at all"
