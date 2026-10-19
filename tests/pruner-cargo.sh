#!/bin/bash
# Cargo: .crate files, extracted crates and git checkouts/dbs are evicted;
# bin/ (cargo install'ed tools) and the registry index never are. Needs GNU tools:
#   bash tests/pruner-cargo.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

cache0="$(mkslot 1)"
c="$cache0/cargo"

mkfile "$c/bin/cargo-nextest" 200000 900 # oldest thing in the store
mkfile "$c/registry/index/idx/.cache/ab/serde" 50000 900
mkfile "$c/registry/cache/idx/old-1.0.0.crate" 100000 90
mkfile "$c/registry/cache/idx/fresh-1.0.0.crate" 100000 1
mkunit "$c/registry/src/idx/old-1.0.0" 100000 80
mkunit "$c/registry/src/idx/fresh-1.0.0" 100000 1
mkunit "$c/git/checkouts/oldrepo-aaa" 100000 70
mkunit "$c/git/checkouts/freshrepo-bbb" 100000 1
mkunit "$c/git/db/oldrepo-aaa" 100000 60
mkunit "$c/git/db/freshrepo-bbb" 100000 1

CACHE_BUDGET_BYTES=$(budget_without "$cache0" "$c/registry/cache/idx/old-1.0.0.crate" "$c/registry/src/idx/old-1.0.0" \
  "$c/git/checkouts/oldrepo-aaa" "$c/git/db/oldrepo-aaa")
prune_caches >/dev/null

gone "$c/registry/cache/idx/old-1.0.0.crate"
gone "$c/registry/src/idx/old-1.0.0"
gone "$c/git/checkouts/oldrepo-aaa"
gone "$c/git/db/oldrepo-aaa"
kept "$c/registry/cache/idx/fresh-1.0.0.crate"
kept "$c/registry/src/idx/fresh-1.0.0/data.bin"
kept "$c/git/checkouts/freshrepo-bbb/data.bin"
kept "$c/git/db/freshrepo-bbb/data.bin"
[ -s "$c/bin/cargo-nextest" ] || fail "bin/cargo-nextest removed"
[ -s "$c/registry/index/idx/.cache/ab/serde" ] || fail "registry index removed"

# Even with no budget at all, bin/ and the index stay.
CACHE_BUDGET_BYTES=1
prune_caches >/dev/null
[ -s "$c/bin/cargo-nextest" ] || fail "bin/cargo-nextest removed under a tiny budget"
[ -s "$c/registry/index/idx/.cache/ab/serde" ] || fail "registry index removed under a tiny budget"
[ ! -e "$c/registry/cache/idx/fresh-1.0.0.crate" ] || fail "fresh crate should go under a tiny budget"

finish "cargo evicted caches, bin/ protected"
