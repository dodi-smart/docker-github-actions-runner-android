#!/bin/bash
# Pruner. Run by the `pruner` compose service (same image, this script as the
# entrypoint), NOT by a runner job hook.
#
# These scans used to sit in cleanup.sh and ran after every job, costing
# 21-39 s of runner time each time and freeing nothing (issue #16). Here they
# run off the job path:
#   1. A size budget per runner slot ($RUNNER_DATA_DIR/slots/<id>/cache/<store>),
#      enforced with one global LRU across all the stores of the slot. What is
#      evictable is described by STORE_TABLE below: caches whose entries are only
#      valid whole (bun packages, gradle versions, mise tool versions, ...) evict
#      whole directories, the rest evict single files.
#   2. docker system prune / builder prune on the host daemon (docker.sock).
#   3. Hourly, in the background: fill the shared action archive cache.
#
# Job safety: a slot is pruned only while holding its `.prune.lock` (pre-job.sh
# waits on it) and only when it is not mid-job: a `busy` marker younger than 6 h
# means a job is running there, so the slot is skipped; an older one is stale.
#
# Adaptive schedule: every PRUNE_CHECK_SECONDS a cheap df runs; a full pass
# happens when free space is below PRUNE_FREE_PCT, or when PRUNE_INTERVAL_SECONDS
# have passed since the last pass. Under disk pressure docker prune is tighter.
#
# Action archive cache: the runner copies
# $ACTION_CACHE_DIR/<owner>_<repo>/<sha>.tar.gz instead of downloading when it
# exists, but never writes it. prefetch_actions() fills it as the GitHub App, so
# downloads count against the App rather than the host IP (codeload 429s).
# Refs: every `uses:` found in the PREFETCH_SOURCES repos, plus PREFETCH_EXTRA.
# `pruner.sh prefetch` runs it once (rollout warm-up).
#
# Env:
#   RUNNER_DATA_DIR          data root holding slots/<id>/ (/var/lib/github-runner)
#   CACHE_BUDGET_BYTES       total cache budget over all slots   (60 GiB)
#   CACHE_BUDGET_PCT         ... capped to this % of the filesystem holding
#                            RUNNER_DATA_DIR (40); the smaller wins and is split
#                            evenly between the slots
#   CACHE_CAP_BYTES          DEPRECATED alias of CACHE_BUDGET_BYTES
#   PRUNE_CHECK_SECONDS      df check period                       (3600)
#   PRUNE_FREE_PCT           full pass when free space is below    (15)
#   PRUNE_INTERVAL_SECONDS   full pass at least this often         (86400)
#   PRUNE_INITIAL_DELAY      sleep before the first check (300; keeps a
#                            `docker compose up -d` from running a scan at once)
#   PRUNE_RUN_ONCE=true      run one pass and exit (manual / testing)
#   ACTION_CACHE_CAP_BYTES   cap for the action archive cache (2 GiB)
#   PREFETCH_SOURCES / PREFETCH_EXTRA   "owner/repo@ref ..." to scan / fetch as-is
#   PREFETCH_INTERVAL_SECONDS  prefetch period (default 3600; 0 = off)
#   DOCKER_PRUNE_UNTIL / DOCKER_PRUNE_UNTIL_LOW / DOCKER_BUILDER_PRUNE_UNTIL
#                            (24h / 2h when below PRUNE_FREE_PCT / 72h)
#
# Intentionally not using set -e: one failing step must not stop the others.

RUNNER_DATA_DIR="${RUNNER_DATA_DIR:-/var/lib/github-runner}"
CACHE_BUDGET_BYTES="${CACHE_BUDGET_BYTES:-}"
CACHE_BUDGET_PCT="${CACHE_BUDGET_PCT:-40}"
PRUNE_CHECK_SECONDS="${PRUNE_CHECK_SECONDS:-3600}"
PRUNE_FREE_PCT="${PRUNE_FREE_PCT:-15}"
PRUNE_INTERVAL_SECONDS="${PRUNE_INTERVAL_SECONDS:-86400}"
BUSY_STALE_MINUTES=360 # a `busy` marker older than 6 h is a crashed job's leftover
ACTION_CACHE_DIR=/opt/actionarchivecache # mount point in docker-compose.yml
ACTION_CACHE_CAP_BYTES="${ACTION_CACHE_CAP_BYTES:-2147483648}" # 2 GiB
PREFETCH_SOURCES="${PREFETCH_SOURCES:-}"
PREFETCH_EXTRA="${PREFETCH_EXTRA:-}"
GITHUB_API="https://api.github.com"
DOCKER_PRUNE_UNTIL="${DOCKER_PRUNE_UNTIL:-24h}"
DOCKER_PRUNE_UNTIL_LOW="${DOCKER_PRUNE_UNTIL_LOW:-2h}"
DOCKER_BUILDER_PRUNE_UNTIL="${DOCKER_BUILDER_PRUNE_UNTIL:-72h}"

log() { echo "[pruner] $(date -u +%FT%TZ) $*"; }

if [ -z "$CACHE_BUDGET_BYTES" ]; then
  if [ -n "${CACHE_CAP_BYTES:-}" ]; then
    CACHE_BUDGET_BYTES="$CACHE_CAP_BYTES"
    log "CACHE_CAP_BYTES is deprecated; using it as CACHE_BUDGET_BYTES (now the total over all slots)"
  else
    CACHE_BUDGET_BYTES=64424509440 # 60 GiB
  fi
fi

# Evictable units per store, one rule per line: store|kind|glob|skip
#   kind d: every directory matching glob (relative to the store dir, never a
#           symlink) is one unit, removed whole; skip is a case pattern for the
#           relative path of units to leave alone. Glob "." makes the whole
#           store dir one unit (pnpm: store/ + cache/ are all-or-nothing); it is
#           emptied, but its subdirs are kept, as container symlinks point there.
#   kind f: every regular file named skip (a find -name pattern) under the dir
#           glob is one unit.
# Anything no rule matches (bun's bin/ and @t@ piles, cargo's bin/ and registry
# index, rustup's settings.toml, ...) is never touched. Hooks for the few stores
# needing more than a rule are in unit_key / unit_protected / unit_pre_evict /
# unit_post_evict / store_sweep.
STORE_TABLE='
bun|d|install/cache/*@*|install/cache/@*
bun|d|install/cache/@*/*@*|install/cache/@t@/*
npm|f|_cacache|*
pnpm|d|.|
gradle|d|caches/modules-2/files-2.1/*/*/*|
gradle|d|caches/transforms-*/*|
gradle|d|wrapper/dists/*|
gradle|d|caches/jars-*/*|
gradle|f|caches/build-cache-1|*
cargo|f|registry/cache|*.crate
cargo|d|registry/src/*/*|
cargo|d|git/checkouts/*|
cargo|d|git/db/*|
rustup|d|toolchains/*|
konan|d|dependencies/*|
konan|d|kotlin-native-prebuilt-*|
mise-data|d|installs/*/*|
pub|d|hosted/*/*|
pub|d|git/*|
toolcache|d|*/*|
mise-cache|f|.|*
hk|f|.|*
actions|f|.|*
'

# Stores of a runner slot (everything but the shared action archive cache).
slot_stores() {
  awk -F'|' 'NF > 3 && $1 != "actions" && !seen[$1]++ {print $1}' <<<"$STORE_TABLE"
}

dir_bytes() {
  du -sb "$1" 2>/dev/null | awk '{printf "%.0f\n", $1}'
}

# default_toolchain from rustup's settings.toml ($1 = RUSTUP_HOME).
rustup_default() {
  sed -n 's/^default_toolchain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1/settings.toml" 2>/dev/null | head -n 1
}

# bun treats install/cache/<pkg>@<ver>@@@<n>/ as complete whenever the folder
# exists, so a file evicted from it is silently missing from every later
# node_modules (next@16.3.8 lost dist/compiled/server-only/empty.js, breaking
# every Next build). 0-byte files went first: copying them never reads, so
# their atime never moved. Hence whole packages, least recently used first by
# the atime of their package.json (read on every install and import).

# Before measuring a store ($1 = name, $2 = dir).
store_sweep() {
  [ "$1" = bun ] || return 0
  local cache="$2/install/cache"
  [ -d "$cache" ] || return 0
  # Leftovers of interrupted extractions; the age guard spares live installs.
  find "$cache" -mindepth 1 -maxdepth 2 ! -name .tmp \( -name '*.tmp' -o -name '*.part' \) \
    -mmin +60 -exec rm -rf {} + 2>/dev/null
  find "$cache/.tmp" -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2>/dev/null
}

# LRU key override for dir unit $2 of store $1; prints nothing to keep the
# newest-atime-of-any-file key.
unit_key() {
  [ "$1" = bun ] || return 0
  stat -c %X "$2/package.json" 2>/dev/null || stat -c %Y "$2" 2>/dev/null
}

# Succeeds when unit $3 (relative to dir $2 of store $1) must not be evicted.
unit_protected() {
  local def
  [ "$1" = rustup ] || return 1
  def=$(rustup_default "$2")
  [ -n "$def" ] || return 1
  case "${3##*/}" in
    "$def" | "$def"-*) return 0 ;; # `stable` is the dir stable-<host triple>
  esac
  return 1
}

# toolcache: <ver>/<arch>.complete says <ver>/<arch> is whole. Drop the markers
# first so an interrupted removal never leaves a "complete" half tree.
unit_pre_evict() {
  [ "$1" = toolcache ] || return 0
  find "$2" -name '*.complete' -delete 2>/dev/null
}

# After unit $2 of store $1 is gone.
unit_post_evict() {
  local base
  [ "$1" = bun ] || return 0
  # Drop the <pkg>/<ver>@@@<n> symlink pointing at it, and the dir if empty.
  base="${2##*/}"
  rm -f "${2%/*}/${base%%@*}/${base#*@}" 2>/dev/null
  rmdir "${2%/*}/${base%%@*}" 2>/dev/null
  return 0
}

# Print NUL-terminated "key<TAB>size<TAB>store<TAB>stop<TAB>path" records, one
# per evictable unit of store $1 living in dir $2. key is the LRU order (atime,
# seconds); stop is the dir above which emptied parents are not removed.
collect_units() {
  local store="$1" sd="$2" s kind glob skip pre stop
  [ -d "$sd" ] || return 0
  while IFS='|' read -r s kind glob skip; do
    [ "$s" = "$store" ] || continue
    if [ "$kind" = f ]; then
      [ -d "$sd/$glob" ] || continue
      find "$sd/$glob" -type f -name "$skip" -printf "%A@\t%s\t$store\t-\t%p\0" 2>/dev/null
      continue
    fi
    pre="${glob%%[*?[]*}"
    case "$pre" in
      */*) pre="${pre%/*}" ;;
      *) pre="" ;;
    esac
    stop="$sd${pre:+/$pre}"
    (
      cd "$sd" 2>/dev/null || exit 0
      shopt -s nullglob
      # shellcheck disable=SC2086  # glob expansion is the point
      for rel in $glob; do
        if [ ! -d "$rel" ] || [ -L "$rel" ]; then continue; fi
        # shellcheck disable=SC2254  # skip is a pattern
        case "$rel" in $skip) continue ;; esac
        if unit_protected "$store" "$sd" "$rel"; then continue; fi
        stats=$(find "$rel" -printf '%y\t%A@\t%s\n' 2>/dev/null |
          awk -F'\t' '{ s += $3; if ($1 == "f" && $2 + 0 > m) m = $2 + 0 } END { printf "%.6f\t%.0f\n", m, s }')
        key="${stats%%$'\t'*}"
        t=$(unit_key "$store" "$rel")
        [ -z "$t" ] || key="$t"
        printf '%s\t%s\t%s\t%s\t%s\0' "$key" "${stats#*$'\t'}" "$store" "$stop" "$sd/$rel"
      done
    )
  done <<<"$STORE_TABLE"
}

# Remove unit $3 of store $1 (stop dir $2): a whole directory (then its emptied
# parents up to $2), or a single file.
evict_unit() {
  local store="$1" stop="$2" path="$3" p
  if [ "${path##*/}" = . ]; then
    find "${path%/.}" -mindepth 2 -delete 2>/dev/null
    find "${path%/.}" -mindepth 1 -maxdepth 1 ! -type d -delete 2>/dev/null
  elif [ -d "$path" ] && [ ! -L "$path" ]; then
    unit_pre_evict "$store" "$path"
    rm -rf "$path" 2>/dev/null
    unit_post_evict "$store" "$path"
    p="${path%/*}"
    while [ "$p" != "$stop" ] && [ "${p#"$stop"/}" != "$p" ]; do
      rmdir "$p" 2>/dev/null || break
      p="${p%/*}"
    done
  else
    rm -f "$path" 2>/dev/null
  fi
}

# Keep the stores given as <store>=<dir> pairs ($2...) within $1 bytes in total,
# evicting units across all of them in global LRU order, least recently used
# first (a read counts as use; Gradle never touches mtime on read, so mtime
# order evicted the most-used dependencies first). Volumes mounted relatime
# still refresh atime on the first read after a change.
lru_entries() {
  local budget="$1" spec store sd total=0 sz excess freed=0 n=0
  local rec key size stop path
  local -A dirs=() touched=()
  shift
  for spec in "$@"; do
    store="${spec%%=*}"
    sd="${spec#*=}"
    [ -d "$sd" ] || continue
    store_sweep "$store" "$sd"
    dirs[$store]="$sd"
    sz=$(dir_bytes "$sd")
    total=$((total + ${sz:-0}))
  done
  if [ "$total" -le "$budget" ]; then
    log "${total}B <= budget ${budget}B"
    return 0
  fi
  excess=$((total - budget))
  log "${total}B (budget ${budget}B), evicting least recently used entries"
  while IFS= read -r -d '' rec; do
    if [ "$freed" -ge "$excess" ]; then break; fi
    IFS=$'\t' read -r key size store stop path <<<"$rec"
    if [ -z "$path" ] || [ -z "$size" ]; then continue; fi
    evict_unit "$store" "$stop" "$path"
    freed=$((freed + size))
    n=$((n + 1))
    touched[$store]=1
  done < <(
    for store in "${!dirs[@]}"; do collect_units "$store" "${dirs[$store]}"; done |
      LC_ALL=C sort -z -n
  )
  # Emptied directories under file-level stores.
  for store in "${!touched[@]}"; do
    while IFS='|' read -r s kind glob _; do
      if [ "$s" = "$store" ] && [ "$kind" = f ] && [ -d "${dirs[$store]}/$glob" ]; then
        find "${dirs[$store]}/$glob" -mindepth 1 -type d -empty -delete 2>/dev/null
      fi
    done <<<"$STORE_TABLE"
  done
  if [ "$freed" -lt "$excess" ]; then
    log "evicted $n entries, ~${freed}B freed; still ~$((excess - freed))B over budget (protected or untracked data)"
  else
    log "evicted $n entries, ~${freed}B freed"
  fi
}

# Total cache budget in bytes of one slot, with $1 slots sharing it.
slot_budget() {
  local slots="$1" fs total
  total="$CACHE_BUDGET_BYTES"
  fs=$(df -B1 --output=size "$RUNNER_DATA_DIR" 2>/dev/null | awk 'NR == 2 {print $1}')
  if [ -n "$fs" ] && [ $((fs * CACHE_BUDGET_PCT / 100)) -lt "$total" ]; then
    total=$((fs * CACHE_BUDGET_PCT / 100))
  fi
  echo $((total / slots))
}

# Free space of the filesystem holding RUNNER_DATA_DIR, in whole percent.
free_pct() {
  local dir="$RUNNER_DATA_DIR"
  [ -d "$dir" ] || dir=/
  df -B1 --output=avail,size "$dir" 2>/dev/null | awk 'NR == 2 && $2 > 0 {print int($1 * 100 / $2)}'
}

# Prune one slot ($1 = slot dir) down to $2 bytes, unless a job is running in
# it. The flock keeps jobs from starting meanwhile: pre-job.sh waits on it.
prune_slot() {
  local slot="$1" budget="$2" id start="$SECONDS"
  id="${slot##*/}"
  (
    flock -n 9 || { log "slot $id: another prune holds the lock; skipping"; exit 0; }
    if [ -e "$slot/busy" ]; then
      if [ -n "$(find "$slot/busy" -maxdepth 0 -mmin "-$BUSY_STALE_MINUTES" 2>/dev/null)" ]; then
        log "slot $id: job running (busy marker); skipping"
        exit 0
      fi
      log "slot $id: stale busy marker (> ${BUSY_STALE_MINUTES} min); pruning anyway"
    fi
    args=()
    for store in $(slot_stores); do args+=("$store=$slot/cache/$store"); done
    log "slot $id: budget ${budget}B"
    lru_entries "$budget" "${args[@]}"
  ) 9>"$slot/.prune.lock"
  log "slot $id: took $((SECONDS - start))s"
}

prune_caches() {
  local caches=() cache budget
  for cache in "$RUNNER_DATA_DIR"/slots/*/cache; do
    [ -d "$cache" ] && caches+=("$cache")
  done
  if [ "${#caches[@]}" -gt 0 ]; then
    budget=$(slot_budget "${#caches[@]}")
    for cache in "${caches[@]}"; do prune_slot "${cache%/cache}" "$budget"; done
  else
    log "no slots under $RUNNER_DATA_DIR/slots"
  fi
  lru_entries "$ACTION_CACHE_CAP_BYTES" "actions=$ACTION_CACHE_DIR"
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

# $1 = low: free space is below PRUNE_FREE_PCT, so prune docker harder.
prune_docker() {
  local until="$DOCKER_PRUNE_UNTIL"
  [ "${1:-}" = low ] && until="$DOCKER_PRUNE_UNTIL_LOW"
  if ! docker info >/dev/null 2>&1; then
    log "docker daemon unreachable; skipping docker prune"
    return 0
  fi
  log "docker system prune -af --filter until=${until}"
  docker system prune -af --filter "until=${until}" 2>&1 | sed 's/^/[pruner] /'
  log "docker builder prune -af --filter until=${DOCKER_BUILDER_PRUNE_UNTIL}"
  docker builder prune -af --filter "until=${DOCKER_BUILDER_PRUNE_UNTIL}" 2>&1 | sed 's/^/[pruner] /'
}

run_once() {
  local before after
  before=$(df -h / | awk 'NR==2 {print $4}')
  prune_caches
  prune_docker "${1:-}"
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
last=0
while true; do
  free=$(free_pct)
  low=""
  now=$(date +%s)
  if [ -n "$free" ] && [ "$free" -lt "$PRUNE_FREE_PCT" ]; then
    low=low
    log "free space ${free}% < ${PRUNE_FREE_PCT}%: full pass"
  elif [ $((now - last)) -ge "$PRUNE_INTERVAL_SECONDS" ]; then
    log "free space ${free:-?}%, ${PRUNE_INTERVAL_SECONDS}s since the last pass: full pass"
  fi
  if [ -n "$low" ] || [ $((now - last)) -ge "$PRUNE_INTERVAL_SECONDS" ]; then
    run_once "$low"
    last=$(date +%s)
  fi
  sleep "$PRUNE_CHECK_SECONDS"
done
