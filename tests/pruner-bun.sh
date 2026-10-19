#!/bin/bash
# pruner.sh must evict whole bun packages, never single files: bun reuses a
# cache folder as complete whenever it exists. Builds a fake /root/.bun store
# in a slot (packages holding 0-byte files with old atimes, a scoped package,
# the <pkg>/<ver> symlinks, @t@ piles and bin/bun), runs prune_caches under a
# small budget, then checks every surviving package is complete and every
# evicted one is fully gone. Needs GNU tools (Linux, or `docker run ubuntu`):
#   bash tests/pruner-bun.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

cache0="$(mkslot 1)"
bun="$cache0/bun"
cache="$bun/install/cache"
mkdir -p "$bun/bin" "$cache/@t@"
head -c 300000 /dev/zero >"$bun/bin/bun"
ln -s /root/.bun/bin/bun "$bun/bin/bunx"
head -c 2000 /dev/zero >"$cache/@t@/0061322e0ad01aa4.pile"

# make_pkg <entry relative to cache> <age in days of package.json atime>
make_pkg() {
  local entry="$1" days="$2" d="$cache/$1" base
  mkdir -p "$d/dist/compiled/server-only"
  head -c 100000 /dev/urandom >"$d/index.js"
  echo '{"name":"x"}' >"$d/package.json"
  : >"$d/dist/compiled/server-only/empty.js" # 0-byte, atime never refreshes
  : >"$d/LICENSE.empty"
  # 0-byte files are the oldest thing in the volume, as in production.
  find "$d" -type f -empty -exec touch -a -d '400 days ago' {} +
  touch -a -d "$days days ago" "$d/package.json"
  base="${entry##*/}"
  mkdir -p "$(dirname "$d")/${base%%@*}"
  ln -s "/root/.bun/install/cache/$entry" "$(dirname "$d")/${base%%@*}/${base#*@}"
  find "$d" -type f | sed "s|^$d/||" | sort >"$work/${entry//\//_}.files"
}

make_pkg 'old-a@1.0.0@@@1' 90
make_pkg 'old-b@2.0.0@@@1' 80
make_pkg '@scope/old-c@3.0.0@@@1' 70
make_pkg 'next@16.3.8@@@1' 1
make_pkg 'next@16.4.2@@@1' 2
make_pkg '@scope/fresh@1.0.0@@@1' 3
make_pkg 'nopkgjson@1.0.0@@@1' 0
rm "$cache/nopkgjson@1.0.0@@@1/package.json" # falls back to dir mtime
sed -i '/^package.json$/d' "$work/nopkgjson@1.0.0@@@1.files"
touch -d '1 hour ago' "$cache/nopkgjson@1.0.0@@@1"

# Budget = volume minus the three oldest packages (old-a, old-b, @scope/old-c):
# exactly those three must go, nothing else.
CACHE_BUDGET_BYTES=$(budget_without "$cache0" "$cache/old-a@1.0.0@@@1" "$cache/old-b@2.0.0@@@1" \
  "$cache/@scope/old-c@3.0.0@@@1")
prune_caches >/dev/null

for entry in 'old-a@1.0.0@@@1' 'old-b@2.0.0@@@1' '@scope/old-c@3.0.0@@@1'; do
  base="${entry##*/}"
  [ ! -e "$cache/$entry" ] || fail "$entry should be evicted"
  [ ! -L "$(dirname "$cache/$entry")/${base%%@*}/${base#*@}" ] || fail "$entry symlink left behind"
  [ ! -e "$(dirname "$cache/$entry")/${base%%@*}" ] || fail "$entry name dir left behind"
done

for entry in 'next@16.3.8@@@1' 'next@16.4.2@@@1' '@scope/fresh@1.0.0@@@1' 'nopkgjson@1.0.0@@@1'; do
  d="$cache/$entry"
  if [ ! -d "$d" ]; then
    fail "$entry should survive"
    continue
  fi
  diff <(find "$d" -type f | sed "s|^$d/||" | sort) "$work/${entry//\//_}.files" >/dev/null ||
    fail "$entry is incomplete"
  base="${entry##*/}"
  [ -L "$(dirname "$d")/${base%%@*}/${base#*@}" ] || fail "$entry symlink removed"
done

[ -f "$cache/next@16.3.8@@@1/dist/compiled/server-only/empty.js" ] || fail "next lost server-only/empty.js"
[ -s "$bun/bin/bun" ] || fail "bin/bun removed"
[ -L "$bun/bin/bunx" ] || fail "bin/bunx removed"
[ -f "$cache/@t@/0061322e0ad01aa4.pile" ] || fail "@t@ pile removed"
[ -d "$cache/@scope" ] || fail "@scope dir removed while it still holds a package"

size=$(stores_bytes "$cache0")
[ "$size" -le "$CACHE_BUDGET_BYTES" ] || fail "slot ${size}B still over the ${CACHE_BUDGET_BYTES}B budget"

finish "bun cache evicted by whole package (slot ${size}B)"
