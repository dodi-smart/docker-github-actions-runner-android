#!/bin/bash
# Nightly pruner. Run by the `pruner` compose service (same image, this script
# as the entrypoint), NOT by a runner job hook.
#
# These scans used to sit in cleanup.sh and ran after every job, costing
# 21-39 s of runner time each time and freeing nothing (issue #16). Here they
# run once a day, off the job path:
#   1. LRU size caps on the per-runner cache volumes (mounted under
#      $CACHES_ROOT/<runner>/<name>, see docker-compose.yml).
#   2. docker system prune / builder prune on the host daemon (docker.sock).
#
# Env:
#   PRUNE_INTERVAL_SECONDS   sleep between runs            (default 86400)
#   PRUNE_INITIAL_DELAY      sleep before the first run    (default 300; keeps a
#                            `docker compose up -d` from running a scan at once)
#   PRUNE_RUN_ONCE=true      run once and exit (manual / testing)
#   CACHES_ROOT              where the cache volumes are mounted (/caches)
#   CACHE_CAP_BYTES          cap for each file-level cache dir   (20 GiB)
#   MISE_DATA_CAP_BYTES      cap for each mise installs tree     (20 GiB)
#   DOCKER_PRUNE_UNTIL / DOCKER_BUILDER_PRUNE_UNTIL   (24h / 72h)
#
# Intentionally not using set -e: one failing step must not stop the others.

CACHES_ROOT="${CACHES_ROOT:-/caches}"
CACHE_CAP_BYTES="${CACHE_CAP_BYTES:-21474836480}" # 20 GiB
MISE_DATA_CAP_BYTES="${MISE_DATA_CAP_BYTES:-21474836480}" # 20 GiB
DOCKER_PRUNE_UNTIL="${DOCKER_PRUNE_UNTIL:-24h}"
DOCKER_BUILDER_PRUNE_UNTIL="${DOCKER_BUILDER_PRUNE_UNTIL:-72h}"

log() { echo "[pruner] $(date -u +%FT%TZ) $*"; }

dir_bytes() {
  du -sb "$1" 2>/dev/null | awk '{print $1}'
}

# Print how many bytes dir $1 is over cap $2. Returns 1 (printing nothing) when
# the dir is missing, unreadable, or already within the cap.
excess_bytes() {
  local dir="$1" cap="$2" size
  [ -d "$dir" ] || return 1
  size=$(dir_bytes "$dir")
  [ -n "$size" ] || return 1
  if [ "$size" -le "$cap" ]; then
    log "$dir ${size}B <= cap ${cap}B" >&2
    return 1
  fi
  log "$dir is ${size}B (cap ${cap}B)" >&2
  echo $((size - cap))
}

# LRU-evict regular files, least recently accessed first, until $1 is at or
# under $2 bytes. Ordered by atime (a read counts as use; Gradle never touches
# mtime on read, so mtime order evicted the most-used dependencies first).
# Volumes mounted relatime still refresh atime on the first read after a
# change. Does not wholesale wipe the tree.
lru_cap() {
  local dir="$1" cap="${2:-$CACHE_CAP_BYTES}"
  local excess freed=0 rec fsize path
  excess=$(excess_bytes "$dir" "$cap") || return 0
  log "evicting least recently used files from $dir"
  while IFS= read -r -d '' rec; do
    [ "$freed" -ge "$excess" ] && break
    rec="${rec#*	}"        # drop atime
    fsize="${rec%%	*}"
    path="${rec#*	}"
    [ -n "$path" ] && [ -n "$fsize" ] || continue
    rm -f "$path" 2>/dev/null || true
    freed=$((freed + fsize))
  done < <(find "$dir" -type f -printf '%A@\t%s\t%p\0' 2>/dev/null | sort -z -n)
  find "$dir" -type d -empty -delete 2>/dev/null || true
  log "$dir freed ~${freed}B"
}

# mise installs (installs/<tool>/<version>) are only useful whole: deleting
# single files would leave a tool that exists but is broken. Evict whole
# <tool>/<version> directories instead, oldest install first, until the
# installs tree fits under the cap.
lru_cap_mise_installs() {
  local data="$1" cap="${2:-$MISE_DATA_CAP_BYTES}"
  local installs="$data/installs"
  local excess freed=0 rec path dsize
  excess=$(excess_bytes "$installs" "$cap") || return 0
  log "evicting oldest tool versions from $installs"
  while IFS= read -r -d '' rec; do
    [ "$freed" -ge "$excess" ] && break
    path="${rec#*	}"
    [ -d "$path" ] || continue
    dsize=$(dir_bytes "$path")
    rm -rf "$path" 2>/dev/null || true
    freed=$((freed + ${dsize:-0}))
  done < <(find "$installs" -mindepth 2 -maxdepth 2 -type d -printf '%T@\t%p\0' 2>/dev/null | sort -z -n)
  log "$installs freed ~${freed}B"
}

prune_caches() {
  local runner
  for runner in "$CACHES_ROOT"/*/; do
    [ -d "$runner" ] || continue
    runner="${runner%/}"
    log "capping caches under $runner"
    lru_cap "$runner/gradle"
    lru_cap "$runner/bun"
    lru_cap "$runner/mise-cache"
    lru_cap "$runner/hk"
    lru_cap_mise_installs "$runner/mise-data"
  done
}

prune_docker() {
  if ! docker info >/dev/null 2>&1; then
    log "docker daemon unreachable; skipping docker prune"
    return 0
  fi
  log "docker system prune -af --filter until=${DOCKER_PRUNE_UNTIL}"
  docker system prune -af --filter "until=${DOCKER_PRUNE_UNTIL}" 2>&1 | sed 's/^/[pruner] /'
  log "docker builder prune -af --filter until=${DOCKER_BUILDER_PRUNE_UNTIL}"
  docker builder prune -af --filter "until=${DOCKER_BUILDER_PRUNE_UNTIL}" 2>&1 | sed 's/^/[pruner] /'
}

run_once() {
  local before after
  before=$(df -h / | awk 'NR==2 {print $4}')
  prune_caches
  prune_docker
  after=$(df -h / | awk 'NR==2 {print $4}')
  log "done. Disk free: ${before} -> ${after}"
}

if [ "${PRUNE_RUN_ONCE:-}" = "true" ]; then
  run_once
  exit 0
fi

sleep "${PRUNE_INITIAL_DELAY:-300}"
while true; do
  run_once
  sleep "${PRUNE_INTERVAL_SECONDS:-86400}"
done
