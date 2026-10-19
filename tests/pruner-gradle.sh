#!/bin/bash
# Gradle: whole module versions / transform dirs / wrapper dists / jars dirs
# are evicted, never single files inside them, and the metadata Gradle keeps
# beside them (modules-2/metadata-*) is left alone. Needs GNU tools:
#   bash tests/pruner-gradle.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

cache0="$(mkslot 1)"
g="$cache0/gradle"
fs="$g/caches/modules-2/files-2.1"

mkunit "$fs/org.old/lib/1.0.0/h1" 100000 90      # oldest version of a module
mkfile "$fs/org.old/lib/1.0.0/h1/lib-1.0.0.pom" 50000 400
mkunit "$fs/org.old/lib/1.1.0/h2" 100000 2       # newer version of the same module
mkunit "$fs/org.fresh/app/2.0.0/h3" 100000 1
mkunit "$g/caches/transforms-4/oldhash" 100000 80
mkunit "$g/caches/transforms-4/freshhash" 100000 1
mkunit "$g/wrapper/dists/gradle-7.0-bin/abc" 100000 70
mkunit "$g/wrapper/dists/gradle-8.5-bin/def" 100000 1
mkunit "$g/caches/jars-9/oldjars" 100000 60
mkfile "$g/caches/build-cache-1/oldentry" 100000 50
mkfile "$g/caches/build-cache-1/freshentry" 100000 1
mkdir -p "$g/caches/modules-2/metadata-2.107"
echo meta >"$g/caches/modules-2/metadata-2.107/descriptors.bin"
touch -a -d '500 days ago' "$g/caches/modules-2/metadata-2.107/descriptors.bin"

CACHE_BUDGET_BYTES=$(budget_without "$cache0" "$fs/org.old/lib/1.0.0" "$g/caches/transforms-4/oldhash" \
  "$g/wrapper/dists/gradle-7.0-bin" "$g/caches/jars-9/oldjars" "$g/caches/build-cache-1/oldentry")
prune_caches >/dev/null

gone "$fs/org.old/lib/1.0.0"
gone "$g/caches/transforms-4/oldhash"
gone "$g/wrapper/dists/gradle-7.0-bin"
gone "$g/caches/jars-9/oldjars"
gone "$g/caches/build-cache-1/oldentry"
kept "$fs/org.old/lib/1.1.0/h2/data.bin"
kept "$fs/org.fresh/app/2.0.0/h3/data.bin"
kept "$g/caches/transforms-4/freshhash/data.bin"
kept "$g/wrapper/dists/gradle-8.5-bin/def/data.bin"
kept "$g/caches/build-cache-1/freshentry"
kept "$g/caches/modules-2/metadata-2.107/descriptors.bin"
[ -d "$fs/org.old/lib" ] || fail "module dir removed while a version is left"
[ -d "$fs" ] || fail "files-2.1 removed"
[ -d "$g/caches/build-cache-1" ] || fail "build-cache-1 removed"

size=$(stores_bytes "$cache0")
[ "$size" -le "$CACHE_BUDGET_BYTES" ] || fail "slot ${size}B still over the ${CACHE_BUDGET_BYTES}B budget"

finish "gradle evicted whole versions, metadata untouched"
