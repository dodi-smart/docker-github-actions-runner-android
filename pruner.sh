#!/bin/bash
# Nightly pruner. Run by the `pruner` compose service (same image, this script
# as the entrypoint), NOT by a runner job hook.
#
# These scans used to sit in cleanup.sh and ran after every job, costing
# 21-39 s of runner time each time and freeing nothing (issue #16). Here they
# run once a day, off the job path:
#   1. LRU size caps on the per-runner cache volumes (mounted under
#      $CACHES_ROOT/<runner>/<name>, see docker-compose.yml). Caches whose
#      entries are only valid whole (bun packages, mise tool versions) evict
#      whole entries; the rest evict single files.
#   2. docker system prune / builder prune on the host daemon (docker.sock).
#   3. Hourly, in the background: fill the shared action archive cache.
#
# Action archive cache: the runner copies
# $ACTION_CACHE_DIR/<owner>_<repo>/<sha>.tar.gz instead of downloading when it
# exists, but never writes it. prefetch_actions() fills it as the GitHub App, so
# downloads count against the App rather than the host IP (codeload 429s).
# Refs: every `uses:` found in the PREFETCH_SOURCES repos, plus PREFETCH_EXTRA.
# `pruner.sh prefetch` runs it once (rollout warm-up).
#
# Env:
#   PRUNE_INTERVAL_SECONDS   sleep between runs            (default 86400)
#   PRUNE_INITIAL_DELAY      sleep before the first run    (default 300; keeps a
#                            `docker compose up -d` from running a scan at once)
#   PRUNE_RUN_ONCE=true      run once and exit (manual / testing)
#   CACHES_ROOT              where the cache volumes are mounted (/caches)
#   CACHE_CAP_BYTES          cap for each file-level cache dir   (20 GiB)
#   MISE_DATA_CAP_BYTES      cap for each mise installs tree     (20 GiB)
#   ACTION_CACHE_CAP_BYTES   cap for the action archive cache (2 GiB)
#   PREFETCH_SOURCES / PREFETCH_EXTRA   "owner/repo@ref ..." to scan / fetch as-is
#   PREFETCH_INTERVAL_SECONDS  prefetch period (default 3600; 0 = off)
#   DOCKER_PRUNE_UNTIL / DOCKER_BUILDER_PRUNE_UNTIL   (24h / 72h)
#
# Intentionally not using set -e: one failing step must not stop the others.

CACHES_ROOT="${CACHES_ROOT:-/caches}"
CACHE_CAP_BYTES="${CACHE_CAP_BYTES:-21474836480}" # 20 GiB
MISE_DATA_CAP_BYTES="${MISE_DATA_CAP_BYTES:-21474836480}" # 20 GiB
ACTION_CACHE_DIR=/opt/actionarchivecache # mount point in docker-compose.yml
ACTION_CACHE_CAP_BYTES="${ACTION_CACHE_CAP_BYTES:-2147483648}" # 2 GiB
PREFETCH_SOURCES="${PREFETCH_SOURCES:-}"
PREFETCH_EXTRA="${PREFETCH_EXTRA:-}"
GITHUB_API="https://api.github.com"
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
    if [ -z "$path" ] || [ -z "$fsize" ]; then continue; fi
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

# bun treats install/cache/<pkg>@<ver>@@@<n>/ as complete whenever the folder
# exists, so a file evicted from it is silently missing from every later
# node_modules (next@16.3.8 lost dist/compiled/server-only/empty.js, breaking
# every Next build). 0-byte files went first: copying them never reads, so
# their atime never moved. Evict whole package folders instead, least recently
# used first by the atime of their package.json (read on every install and
# import), until the whole volume ($1, mounted from /root/.bun) fits under the
# cap. Never touches $1/bin (the bun binary itself) or the @t@ manifest piles.
lru_cap_bun() {
  local dir="$1" cap="${2:-$CACHE_CAP_BYTES}"
  local cache="$dir/install/cache"
  local excess freed=0 rec path dsize base t
  [ -d "$cache" ] || return 0
  # Leftovers of interrupted extractions; the age guard spares live installs.
  find "$cache" -mindepth 1 -maxdepth 2 ! -name .tmp \( -name '*.tmp' -o -name '*.part' \) \
    -mmin +60 -exec rm -rf {} + 2>/dev/null
  find "$cache/.tmp" -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2>/dev/null
  excess=$(excess_bytes "$dir" "$cap") || return 0
  log "evicting least recently used packages from $cache"
  while IFS= read -r -d '' rec; do
    [ "$freed" -ge "$excess" ] && break
    path="${rec#*	}"
    [ -d "$path" ] || continue
    dsize=$(dir_bytes "$path")
    rm -rf "$path" 2>/dev/null || true
    freed=$((freed + ${dsize:-0}))
    # Drop the <pkg>/<ver>@@@<n> symlink pointing at it, and the dir if empty.
    base="${path##*/}"
    rm -f "${path%/*}/${base%%@*}/${base#*@}" 2>/dev/null
    rmdir "${path%/*}/${base%%@*}" 2>/dev/null
  done < <(
    # <pkg>@<ver>... at the top level, @scope/<pkg>@<ver>... one level down.
    find "$cache" -mindepth 1 -maxdepth 2 -type d -name '*@*' ! -name '@*' \
      \( -path "$cache/@*/*" -o ! -path "$cache/*/*" \) -print0 2>/dev/null |
      while IFS= read -r -d '' path; do
        t=$(stat -c %X "$path/package.json" 2>/dev/null || stat -c %Y "$path" 2>/dev/null) || continue
        printf '%s\t%s\0' "$t" "$path"
      done | sort -z -n
  )
  find "$cache" -mindepth 1 -maxdepth 1 -name '@*' ! -name '@t@' -type d -empty -delete 2>/dev/null || true
  log "$cache freed ~${freed}B"
}

prune_caches() {
  local runner
  for runner in "$CACHES_ROOT"/*/; do
    [ -d "$runner" ] || continue
    runner="${runner%/}"
    log "capping caches under $runner"
    lru_cap "$runner/gradle"
    lru_cap_bun "$runner/bun"
    lru_cap "$runner/mise-cache"
    lru_cap "$runner/hk" # configs/<hash>.json + pklr/packages/<hash>.zip: whole files
    lru_cap_mise_installs "$runner/mise-data"
  done
  lru_cap "$ACTION_CACHE_DIR" "$ACTION_CACHE_CAP_BYTES"
}

gh_curl() {
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 \
    -H "Authorization: Bearer ${GH_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

# Print "owner/repo ref" for every remote action under tree $1. Skips local
# (./), docker:// and reusable-workflow (.github/workflows/) refs, which the
# runner never fetches as an action archive; subpath actions (owner/repo/sub)
# share the owner/repo archive.
action_refs_from_tree() {
  grep -rhE --include='*.yml' --include='*.yaml' '^[[:space:]-]*uses:[[:space:]]' "$1" 2>/dev/null |
    sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/["'"'"']//g; s/[[:space:]#].*$//' |
    awk -F@ 'NF == 2 && $1 !~ /^(\.|docker:)/ && $1 !~ /[$]/ && $1 !~ /\.github\/workflows\// {
      split($1, p, "/"); if (p[2] != "") print p[1] "/" p[2], $2 }'
}

# Fetch the archive of $1 (owner/repo) at $2 (tag, branch or sha) into the
# cache as <owner>_<repo>/<sha>.tar.gz, via temp file + rename so a runner never
# reads a partial file. Prints 1 when it downloaded something.
prefetch_one() {
  local name="$1" ref="$2" sha="$2" dir file tmp
  dir="$ACTION_CACHE_DIR/${name//\//_}"
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    sha=$(gh_curl -H 'Accept: application/vnd.github.sha' "$GITHUB_API/repos/$name/commits/$ref")
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      log "prefetch: cannot resolve $name@$ref" >&2
      return 1
    fi
  fi
  file="$dir/$sha.tar.gz"
  [ -s "$file" ] && return 0
  mkdir -p "$dir" && tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  if gh_curl -o "$tmp" "$GITHUB_API/repos/$name/tarball/$sha" && tar -tzf "$tmp" >/dev/null 2>&1; then
    chmod 644 "$tmp" && mv -f "$tmp" "$file" && { log "prefetch: cached $name@$sha ($ref)" >&2; echo 1; return 0; }
  fi
  rm -f "$tmp"
  log "prefetch: download failed for $name@$sha" >&2
  return 1
}

prefetch_actions() {
  local work src refs name ref out n=0 fetched=0 failed=0 token
  [ -n "$PREFETCH_SOURCES$PREFETCH_EXTRA" ] || return 0 # cache not configured
  if [ -z "${APP_ID:-}" ] || [ -z "${APP_PRIVATE_KEY:-}" ] || [ -z "${APP_LOGIN:-}" ]; then
    log "prefetch: APP_ID/APP_PRIVATE_KEY/APP_LOGIN not set; skipping"
    return 0
  fi
  mkdir -p "$ACTION_CACHE_DIR" || return 0
  # Same \n unescaping as the upstream entrypoint applies to APP_PRIVATE_KEY.
  token=$(APP_PRIVATE_KEY="${APP_PRIVATE_KEY//\\n/$'\n'}" bash /app_token.sh 2>/dev/null)
  if [ -z "$token" ] || [ "$token" = null ]; then
    log "prefetch: could not mint an installation token; skipping"
    return 0
  fi
  GH_TOKEN="$token"
  work=$(mktemp -d) || return 0
  : > "$work/refs"
  for src in $PREFETCH_SOURCES; do
    mkdir -p "$work/src"
    if gh_curl -o "$work/src.tgz" "$GITHUB_API/repos/${src%@*}/tarball/${src#*@}" &&
       tar -xzf "$work/src.tgz" -C "$work/src"; then
      action_refs_from_tree "$work/src" >> "$work/refs"
    else
      log "prefetch: cannot read source $src"
    fi
    rm -rf "$work/src" "$work/src.tgz"
  done
  for src in $PREFETCH_EXTRA; do echo "${src%@*} ${src#*@}" >> "$work/refs"; done
  refs=$(sort -u "$work/refs")
  rm -rf "$work"
  while read -r name ref; do
    if [ -z "$name" ] || [ -z "$ref" ]; then continue; fi
    n=$((n + 1))
    if out=$(prefetch_one "$name" "$ref"); then
      [ "$out" = 1 ] && fetched=$((fetched + 1))
    else
      failed=$((failed + 1))
    fi
  done <<< "$refs"
  # Stale temp files from an interrupted download.
  find "$ACTION_CACHE_DIR" -name '.tmp.*' -mmin +60 -delete 2>/dev/null
  log "prefetch: $n refs, $fetched downloaded, $failed failed"
  GH_TOKEN=""
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

# Sourced (tests/): define the functions only.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

if [ "${1:-}" = prefetch ]; then
  prefetch_actions
  exit 0
fi

if [ "${PRUNE_RUN_ONCE:-}" = "true" ]; then
  run_once
  exit 0
fi

if [ "${PREFETCH_INTERVAL_SECONDS:-3600}" -gt 0 ]; then
  (
    sleep 30
    while true; do
      prefetch_actions
      sleep "${PREFETCH_INTERVAL_SECONDS:-3600}"
    done
  ) &
fi

sleep "${PRUNE_INITIAL_DELAY:-300}"
while true; do
  run_once
  sleep "${PRUNE_INTERVAL_SECONDS:-86400}"
done
