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
#   DOCKER_PRUNE_KEEP_LABELS space-separated key or key=value entries: images and
#                            stopped containers carrying any of them stay, and so
#                            does the image of such a container (empty)
#   DOCKER_PRUNE_KEEP_IMAGES space-separated patterns on the names `docker image
#                            ls` prints, * crossing /: "variscite:* ghcr.io/acme/*".
#                            A bare repository covers all of its tags (empty)
#
# Intentionally not using set -e: one failing step must not stop the others.

RUNNER_DATA_DIR="${RUNNER_DATA_DIR:-/var/lib/github-runner}"
CACHE_BUDGET_BYTES="${CACHE_BUDGET_BYTES:-64424509440}" # 60 GiB
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
DOCKER_PRUNE_KEEP_LABELS="${DOCKER_PRUNE_KEEP_LABELS:-}"
DOCKER_PRUNE_KEEP_IMAGES="${DOCKER_PRUNE_KEEP_IMAGES:-}"

log() { echo "[pruner] $(date -u +%FT%TZ) $*"; }

# Evictable units per store, one rule per line: store|kind|glob|skip|opts
#   kind d: every directory matching glob (relative to the store dir, never a
#           symlink) is one unit, removed whole; skip is a case pattern for the
#           relative path of units to leave alone. Glob "." makes the whole
#           store dir one unit (pnpm: store/ + cache/ are all-or-nothing); it is
#           emptied, but its subdirs are kept, as container symlinks point there.
#   kind f: every regular file named skip (a find -name pattern) under the dir
#           glob is one unit.
#   opts:   comma-separated. shared: not a runner-slot store (the action archive
#           cache). key=<file>: LRU order of a dir unit is the atime of <unit>/<file>
#           (the unit's mtime when it has none), not the newest atime of any file.
# Globs use * and ? only; like the shell, they skip names starting with a dot.
# Anything no rule matches (bun's bin/ and @t@ piles, cargo's bin/ and registry
# index, rustup's settings.toml, ...) is never touched. The few stores needing
# more than a rule are in store_hook. Leftovers of killed bun extractions
# (*.tmp, *.part) are pre-job.sh's job: it sweeps them before the next job of a
# crashed slot.
STORE_TABLE='
bun|d|install/cache/*@*|install/cache/@*|key=package.json
bun|d|install/cache/@*/*@*|install/cache/@t@/*|key=package.json
npm|f|_cacache|*|
pnpm|d|.||
gradle|d|caches/modules-2/files-2.1/*/*/*||
gradle|d|caches/transforms-*/*||
gradle|d|wrapper/dists/*||
gradle|d|caches/jars-*/*||
gradle|f|caches/build-cache-1|*|
cargo|f|registry/cache|*.crate|
cargo|d|registry/src/*/*||
cargo|d|git/checkouts/*||
cargo|d|git/db/*||
rustup|d|toolchains/*||
konan|d|dependencies/*||
konan|d|kotlin-native-prebuilt-*||
mise-data|d|installs/*/*||
pub|d|hosted/*/*||
pub|d|git/*||
toolcache|d|*/*||
mise-cache|f|.|*|
hk|f|.|*|
actions|f|.|*|shared
'

# Stores of a runner slot (everything but the shared action archive cache).
slot_stores() {
  awk -F'|' 'NF > 3 && $5 !~ /(^|,)shared(,|$)/ && !seen[$1]++ {print $1}' <<<"$STORE_TABLE"
}

dir_bytes() {
  du -sb "$1" 2>/dev/null | awk '{printf "%.0f\n", $1}'
}

# default_toolchain from rustup's settings.toml ($1 = RUSTUP_HOME).
rustup_default() {
  sed -n 's/^default_toolchain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1/settings.toml" 2>/dev/null | head -n 1
}

# The per-store behaviour a table rule cannot express: store_hook <phase> <store> <args>.
#   protect <store> <store dir>   prints the names of units never to evict, one
#                                 per line (a unit named N or N-* is kept)
#   pre     <store> <unit path>   before a dir unit is removed
#   post    <store> <unit path>   after it is gone
store_hook() {
  local base
  case "$1:$2" in
    # `stable` is the dir stable-<host triple>, hence the N-* match.
    protect:rustup) rustup_default "$3" ;;
    # <ver>/<arch>.complete says <ver>/<arch> is whole. Drop the markers first
    # so an interrupted removal never leaves a "complete" half tree.
    pre:toolcache) find "$3" -mindepth 1 -maxdepth 1 -name '*.complete' -delete 2>/dev/null ;;
    # Drop the <pkg>/<ver>@@@<n> symlink pointing at the unit, and the dir if empty.
    post:bun)
      base="${3##*/}"
      rm -f "${3%/*}/${base%%@*}/${base#*@}" 2>/dev/null
      rmdir "${3%/*}/${base%%@*}" 2>/dev/null
      ;;
  esac
  return 0
}

# bun treats install/cache/<pkg>@<ver>@@@<n>/ as complete whenever the folder
# exists, so a file evicted from it is silently missing from every later
# node_modules (next@16.3.8 lost dist/compiled/server-only/empty.js, breaking
# every Next build). 0-byte files went first: copying them never reads, so
# their atime never moved. Hence whole packages, least recently used first by
# the atime of their package.json (read on every install and import): the
# key=package.json option of the bun rules.

# awk program of collect_units. Input: find lines "%P\t%y\t%A@\t%T@\t%s\t%d"
# (path below the rule's prefix, type, atime, mtime, size, depth). Variables:
# store, sd (store dir), pre (rule prefix), glob (rule glob below pre), depth
# (its component count), skip (case pattern on the path below sd), keyfile (see
# key= in STORE_TABLE), protect (names never evicted, one per line).
# mawk compatible (this is Ubuntu's default awk): no gensub, no NUL in strings.
# shellcheck disable=SC2016  # awk program, not shell
UNITS_AWK='
# Shell glob (* and ? only; a leading dot is never matched) as an anchored regex.
function glob_re(g,   i, ch, out, start) {
  out = "^"; start = 1
  for (i = 1; i <= length(g); i++) {
    ch = substr(g, i, 1)
    if (ch == "*") out = out (start ? "([^./][^/]*)?" : "[^/]*")
    else if (ch == "?") out = out (start ? "[^./]" : "[^/]")
    else if (index(".+(){}|^$[]\\", ch)) out = out "\\" ch
    else out = out ch
    start = (ch == "/")
  }
  return out "$"
}
# `case` pattern (* matches / too) as an anchored regex.
function case_re(g,   i, ch, out) {
  out = "^"
  for (i = 1; i <= length(g); i++) {
    ch = substr(g, i, 1)
    if (ch == "*") out = out ".*"
    else if (ch == "?") out = out "."
    else if (index(".+(){}|^$[]\\", ch)) out = out "\\" ch
    else out = out ch
  }
  return out "$"
}
function flush(   key) {
  if (cur == "") return
  key = keyfile == "" ? maxf : (keyat != "" ? keyat : mtime)
  printf "%.6f\t%.0f\t%s\t%s\t%s%c", key, size, store, stop, sd "/" rel, 0
  cur = ""
}
function protected(rel,   base, i) {
  base = rel; sub(/^.*\//, "", base)
  for (i = 1; i <= nprot; i++)
    if (prot[i] != "" && (base == prot[i] || index(base, prot[i] "-") == 1)) return 1
  return 0
}
BEGIN {
  FS = "\t"
  root = (glob == ".")
  if (root) depth = 0
  gre = glob_re(glob)
  sre = skip == "" ? "" : case_re(skip)
  nprot = split(protect, prot, "\n")
  stop = sd (pre == "" ? "" : "/" pre)
}
NF != 6 { next }
{
  d = $6 + 0
  if (d > depth) {  # below the unit level: part of the current unit, if any
    if (cur == "") next
    if (!root && substr($1, 1, plen) != cp) next
    size += $5
    if ($2 == "f") {
      if ($3 + 0 > maxf) maxf = $3 + 0
      if (keyfile != "" && $1 == cp keyfile) keyat = $3
    }
    next
  }
  flush()
  if (d < depth || $2 != "d") next
  if (!root && $1 !~ gre) next
  rel = root ? "." : (pre == "" ? $1 : pre "/" $1)
  if (sre != "" && rel ~ sre) next
  if (protected(rel)) next
  cur = rel; cp = $1 "/"; plen = length(cp)
  if (root) cp = ""
  size = $5; maxf = 0; keyat = ""; mtime = $4
}
END { flush() }
'

# Print NUL-terminated "key<TAB>size<TAB>store<TAB>stop<TAB>path" records, one
# per evictable unit of store $1 living in dir $2. key is the LRU order (atime,
# seconds); stop is the dir above which emptied parents are not removed.
#
# One find per dir rule lists everything below the rule's fixed prefix, and one
# awk turns that listing into units. A unit sits at a fixed depth (the glob's
# component count) and find lists a directory right before its contents, so a
# unit's size, newest file atime and package.json atime are summed up as the
# lines go by: no per-unit process.
collect_units() {
  local store="$1" sd="$2" s kind glob skip opts pre rest key protect
  local -a parts
  [ -d "$sd" ] || return 0
  protect=$(store_hook protect "$store" "$sd")
  while IFS='|' read -r s kind glob skip opts; do
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
    rest="${glob#"$pre"}"
    rest="${rest#/}"
    IFS=/ read -ra parts <<<"$rest"
    key=""
    case ",$opts," in *,key=*) key="${opts#*key=}"; key="${key%%,*}" ;; esac
    [ -d "$sd${pre:+/$pre}" ] || continue
    find "$sd${pre:+/$pre}" -printf '%P\t%y\t%A@\t%T@\t%s\t%d\n' 2>/dev/null |
      awk -F'\t' -v store="$store" -v sd="$sd" -v pre="$pre" -v glob="$rest" -v depth="${#parts[@]}" \
        -v skip="$skip" -v keyfile="$key" -v protect="$protect" "$UNITS_AWK"
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
    store_hook pre "$store" "$path"
    rm -rf "$path" 2>/dev/null
    store_hook post "$store" "$path"
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
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
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

# Epoch of docker's `until` value $1: a duration back from now (24h, 90m, 1h30m)
# or a point in time. Prints nothing when it is neither.
until_epoch() {
  local rest="$1" secs=0 unit
  while [[ $rest =~ ^([0-9]+)([hms])(.*)$ ]]; do
    case "${BASH_REMATCH[2]}" in
      h) unit=3600 ;;
      m) unit=60 ;;
      s) unit=1 ;;
    esac
    secs=$((secs + BASH_REMATCH[1] * unit))
    rest="${BASH_REMATCH[3]}"
  done
  if [ -z "$rest" ]; then
    echo $(($(date +%s) - secs))
  elif [[ $1 == [0-9][0-9][0-9][0-9]-* ]]; then # date alone would take "2d" for a time
    date -d "$1" +%s 2>/dev/null
  fi
}

# Whether creation time $1 is before epoch $2. An image can have no creation
# time: like docker's own prune, leave it (date would read "" as this morning).
created_before() {
  local t
  [ -n "$1" ] && t=$(date -d "$1" +%s 2>/dev/null) && [ "$t" -lt "$2" ]
}

# What `docker system prune -af --filter until=$1` does, minus the images and
# stopped containers DOCKER_PRUNE_KEEP_* protect. The prune itself cannot do it:
# it has no reference filter, and given several label!= filters it spares only
# what carries all of them (containers on every image store, images on overlay2;
# only the containerd store spares what carries any). So docker is asked about
# one label at a time and this function removes what is left, without -f: an
# image a job has just started on stays. Any failed listing ends the pass, as a
# missing list of what to keep must never read as nothing to keep.
prune_docker_keeping() {
  local until="$1" cutoff out containers images label id name created image repo tag size pat ref
  local removed_containers=0 removed_refs=0
  local -a labels patterns
  local -A kept_containers=() kept_images=() in_use=() sizes=() refs=() created_at=()
  read -ra labels <<<"$DOCKER_PRUNE_KEEP_LABELS"
  read -ra patterns <<<"$DOCKER_PRUNE_KEEP_IMAGES" # read: a pattern never globs the cwd
  cutoff=$(until_epoch "$until")
  if [ -z "$cutoff" ]; then
    log "cannot read until=${until}; skipping docker prune"
    return 0
  fi
  log "docker prune until=${until}, keeping labels [${labels[*]}] images [${patterns[*]}]"

  for label in "${labels[@]}"; do
    if ! containers=$(docker ps -aq --no-trunc --filter "label=$label") ||
       ! images=$(docker image ls -q --no-trunc --filter "label=$label"); then
      log "cannot list what label $label keeps; skipping docker prune"
      return 0
    fi
    for id in $containers; do kept_containers[$id]="$label"; done
    for id in $images; do kept_images[$id]="label $label"; done
  done
  out=$(docker image ls --no-trunc --format '{{.ID}} {{.Repository}} {{.Tag}} {{.Size}}') ||
    { log "cannot list images; skipping docker prune"; return 0; }
  while read -r id repo tag size; do
    [ -n "$id" ] || continue
    sizes[$id]="$size"
    [ "$repo" != '<none>' ] || continue
    [ "$tag" = '<none>' ] || refs[$id]+=" $repo:$tag"
    for pat in "${patterns[@]}"; do
      # shellcheck disable=SC2053  # the right side is a pattern on purpose
      if [[ $repo:$tag == $pat || $repo == $pat ]]; then kept_images[$id]="pattern $pat"; fi
    done
  done <<<"$out"

  out=$(docker ps -aq --no-trunc --filter status=created --filter status=exited --filter status=dead) ||
    { log "cannot list stopped containers; skipping docker prune"; return 0; }
  if [ -n "$out" ]; then
    # A container gone by now fails the call but not the lines of the others.
    # shellcheck disable=SC2086  # one word per container id
    out=$(docker inspect --format '{{.Id}} {{.Name}} {{.Image}} {{.Created}}' $out 2>/dev/null) || true
  fi
  while read -r id name image created; do
    [ -n "$id" ] || continue
    if [ -n "${kept_containers[$id]:-}" ]; then
      log "kept container ${name#/} (label ${kept_containers[$id]})"
      kept_images[$image]="container ${name#/}"
    elif created_before "$created" "$cutoff" && docker rm "$id" >/dev/null 2>&1; then
      removed_containers=$((removed_containers + 1))
    fi
  done <<<"$out"

  docker network prune -f --filter "until=${until}" 2>&1 | sed 's/^/[pruner] /'

  # After the containers: an image is free once its last container has gone.
  out=$(docker ps -aq --no-trunc) || { log "cannot list containers; skipping image prune"; return 0; }
  if [ -n "$out" ]; then
    # shellcheck disable=SC2086  # one word per container id
    out=$(docker inspect --format '{{.Image}}' $out 2>/dev/null) || true
    [ -n "$out" ] || { log "cannot inspect containers; skipping image prune"; return 0; }
    for id in $out; do in_use[$id]=1; done
  fi
  out=$(docker image inspect --format '{{.Id}} {{.Created}}' "${!sizes[@]}" 2>/dev/null) || true
  while read -r id created; do
    [ -n "$id" ] && created_at[$id]="$created"
  done <<<"$out"
  for id in "${!sizes[@]}"; do
    ref="${refs[$id]:-$id}"
    if [ -n "${kept_images[$id]:-}" ]; then
      log "kept image ${ref# } ${sizes[$id]} (${kept_images[$id]})"
    elif [ -z "${in_use[$id]:-}" ] && created_before "${created_at[$id]:-}" "$cutoff"; then
      # Every tag by name: an id with several tags is refused without -f.
      for ref in $ref; do
        if out=$(docker image rm "$ref" 2>&1); then
          removed_refs=$((removed_refs + 1))
          log "removed image $ref"
        else
          log "left image $ref: $out"
        fi
      done
    fi
  done
  log "removed ${removed_containers} containers and ${removed_refs} image references"

  log "docker builder prune -af --filter until=${until}"
  docker builder prune -af --filter "until=${until}" 2>&1 | sed 's/^/[pruner] /'
}

# $1 = low: free space is below PRUNE_FREE_PCT, so prune docker harder.
prune_docker() {
  local until="$DOCKER_PRUNE_UNTIL"
  [ "${1:-}" = low ] && until="$DOCKER_PRUNE_UNTIL_LOW"
  if ! docker info >/dev/null 2>&1; then
    log "docker daemon unreachable; skipping docker prune"
    return 0
  fi
  if [ -n "${DOCKER_PRUNE_KEEP_LABELS// /}${DOCKER_PRUNE_KEEP_IMAGES// /}" ]; then
    prune_docker_keeping "$until"
  else
    log "docker system prune -af --filter until=${until}"
    docker system prune -af --filter "until=${until}" 2>&1 | sed 's/^/[pruner] /'
  fi
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
