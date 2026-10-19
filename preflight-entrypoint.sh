#!/bin/bash
# Preflight wrapper around the upstream myoung34 entrypoint. Two jobs:
#
# 1. Slot claim (when RUNNER_DATA_DIR is set, as docker-compose.yml does).
#    Every runner container of a host shares RUNNER_DATA_DIR, bind-mounted at
#    the same path on host and container. This claims the lowest free
#    slots/<RUNNER_SLOT_PREFIX><n> with flock on its .lock and keeps the lock
#    for the container's whole life (fd 9 survives `exec`), so a slot's work
#    dir and caches are only ever used by one container at a time. Then:
#      - RUNNER_WORKDIR = slots/<id>/work. It is the same path on the host, so
#        `docker run -v "$PWD:..."` and container actions mount the checkout.
#      - LABELS = RUNNER_<id>_LABELS when that is set (numeric slots only).
#      - The tools' default cache paths link into slots/<id>/cache/<store>,
#        unless RUNNER_CACHES=off (small hosts, control runners).
#    pre-job.sh / cleanup.sh mark the slot busy for pruner.sh through
#    RUNNER_SLOT_DIR.
#
# 2. Registration check. When CONFIGURED_ACTIONS_RUNNER_FILES_DIR is set, the upstream entrypoint
# copies the persisted config into /actions-runner and skips registration
# whenever a .runner file exists — with no validation of the stored
# credentials and no fallback to ACCESS_TOKEN. If the runner was meanwhile
# removed server-side (pruned by GitHub after being offline too long, deleted
# manually, etc), the stored credentials are dead and the container
# crash-loops forever without ever re-registering, even though a perfectly
# good ACCESS_TOKEN is sitting in the environment.
#
# This preflight asks GitHub whether the persisted runner still exists. Only
# a definitive 404 wipes the persisted registration, which makes the upstream
# entrypoint fall through to a fresh ACCESS_TOKEN registration (and store the
# new credentials back into the persist dir). Transient errors, missing
# variables, or unparseable state leave everything untouched, so behavior is
# never worse than upstream's.
#
# Intentionally not using set -e: preflight must never block runner startup.

log() { echo "[preflight] $*"; }

# store:path pairs. The path is the tool's default location for root (jobs run
# as root, HOME=/root); pruner.sh knows how to evict each store safely.
CACHE_LINKS=(
  bun:/root/.bun
  npm:/root/.npm
  pnpm/store:/root/.local/share/pnpm # store-dir default: one store, one unit
  pnpm/cache:/root/.cache/pnpm # metadata cache
  gradle:/root/.gradle
  cargo:/root/.cargo
  rustup:/root/.rustup
  konan:/root/.konan
  mise-data:/root/.local/share/mise
  mise-cache:/root/.cache/mise
  hk:/root/.cache/hk
  pub:/root/.pub-cache
  toolcache:/opt/hostedtoolcache # AGENT_TOOLSDIRECTORY: setup-* actions, Flutter
)

# Claim the lowest free slot under $1 into SLOT_ID. fd 9 stays open on the
# claimed .lock in this shell, which then execs the runner with it.
claim_slot() {
  local root="$1" prefix="${RUNNER_SLOT_PREFIX:-}" n=1 id
  while :; do
    id="${prefix}${n}"
    mkdir -p "$root/slots/$id" || return 1
    exec 9>"$root/slots/$id/.lock" || return 1
    if flock -n 9; then
      SLOT_ID="$id"
      return 0
    fi
    exec 9>&-
    n=$((n + 1))
  done
}

# Point each default cache path at the slot. Anything already at the path
# (the container's writable layer from an earlier run, or an empty image dir)
# is replaced: the slot is the cache.
# Restarts (every job) find the links in place and fork nothing.
link_caches() {
  local cache="$1" pair store path
  for pair in "${CACHE_LINKS[@]}"; do
    store="${pair%%:*}"
    path="${pair#*:}"
    [ -L "$path" ] && [ "$path" -ef "$cache/$store" ] && continue
    mkdir -p "$cache/$store" "${path%/*}"
    rm -rf "$path"
    ln -s "$cache/$store" "$path"
  done
}

# CPUs this container may use: the cgroup v2 quota (cpu.max, from compose
# `cpus:`) rounded up, or nothing when unlimited. `nproc` inside a container
# reports the host's CPUs whatever the quota, and the tools size their worker
# pools from it.
cpu_quota() {
  local quota period
  read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null || return 1
  if [ "$quota" = max ] || [ "${period:-0}" -le 0 ]; then return 1; fi
  echo $(((quota + period - 1) / period))
}

# Under a CPU limit, cap the build tools' parallelism to it, unless the job
# environment already chose. The JVM and Node read the cgroup themselves.
tune_parallelism() {
  local n
  n=$(cpu_quota) || return 0
  export RUNNER_CPU_LIMIT="$n"
  export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$n}"
  export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$n}"
  export MAKEFLAGS="${MAKEFLAGS:--j$n}"
  case "${GRADLE_OPTS:-}" in
    *org.gradle.workers.max*) ;;
    *) export GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-Dorg.gradle.workers.max=$n" ;;
  esac
  log "cpu limit $n: build parallelism capped to $n"
}

# Install rustup (no toolchain) into ~/.cargo, which is the slot's cargo cache
# when caches are on, from the image's rustup-init. Offline and done once per
# slot: later starts find it. Toolchains then persist in ~/.rustup.
ensure_rustup() {
  [ -x /usr/local/bin/rustup-init ] || return 0
  [ -x "$HOME/.cargo/bin/rustup" ] && return 0
  # Self-update off: the image pins rustup, and the check is a network call on
  # every toolchain install.
  if rustup-init -y -q --no-modify-path --default-toolchain none >/dev/null 2>&1 &&
    "$HOME/.cargo/bin/rustup" set auto-self-update disable >/dev/null 2>&1; then
    log "rustup installed into $HOME/.cargo"
  else
    log "rustup-init failed; jobs install rustup themselves"
  fi
}

setup_slot() {
  local root="${RUNNER_DATA_DIR:-}" id dir labels_var
  [ -n "$root" ] || return 0
  # Not in $(...): a subshell would close fd 9, and with it the claim.
  if ! claim_slot "$root"; then
    log "cannot claim a slot under $root/slots; running without one"
    return 0
  fi
  id="$SLOT_ID"
  dir="$root/slots/$id"
  mkdir -p "$dir/work"
  export RUNNER_SLOT="$id" RUNNER_SLOT_DIR="$dir" RUNNER_WORKDIR="$dir/work"
  export RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-runner}-${id}"
  labels_var="RUNNER_${id}_LABELS"
  if [[ "$id" =~ ^[0-9]+$ ]] && [ -n "${!labels_var:-}" ]; then
    export LABELS="${!labels_var}"
  fi
  if [ "${RUNNER_CACHES:-on}" = off ]; then
    log "slot $id ($dir), caches off"
  else
    link_caches "$dir/cache"
    log "slot $id ($dir), caches under $dir/cache"
  fi
}

# The runner's IsConfigured()/HasCredentials() checks treat .runner_migrated /
# .credentials_migrated as equivalent to the primary files, so a wipe must
# remove all five or config.sh refuses to re-register while run.sh can't load
# settings ("Value cannot be null. (Parameter 'configuredSettings')") — a
# crash loop that never self-heals. The files are removed from /actions-runner
# too: the writable layer survives restarts, and the upstream entrypoint's
# persist-back step otherwise re-seeds the persist dir from it.
wipe_registration() {
  local dir="$1" f
  for f in .runner .credentials .credentials_rsaparams .runner_migrated .credentials_migrated; do
    rm -f "$dir/$f" "/actions-runner/$f"
  done
}

preflight() {
  local dir="${CONFIGURED_ACTIONS_RUNNER_FILES_DIR:-}"
  [ -n "$dir" ] || return 0

  # Heal the wedged state left behind by a partial wipe (an older preflight or
  # manual cleanup that removed .runner but not .runner_migrated): without
  # .runner there is nothing to validate, and the orphaned migrated files
  # alone block registration.
  if [ ! -f "$dir/.runner" ] && [ -f "$dir/.runner_migrated" ]; then
    log "orphaned .runner_migrated without .runner; removing it so registration can proceed"
    wipe_registration "$dir"
  fi

  [ -f "$dir/.runner" ] || return 0
  if [ -z "${ACCESS_TOKEN:-}" ]; then
    log "ACCESS_TOKEN not set; cannot validate persisted registration, leaving as-is"
    return 0
  fi

  # .runner is JSON written by the runner itself; it may carry a UTF-8 BOM.
  local agent_id
  agent_id=$(sed '1s/^\xEF\xBB\xBF//' "$dir/.runner" | jq -r '.agentId // empty' 2>/dev/null)
  if [ -z "$agent_id" ]; then
    log "could not read agentId from $dir/.runner; leaving as-is"
    return 0
  fi

  local github_host="${GITHUB_HOST:-github.com}"
  local api_base
  if [ "$github_host" = "github.com" ]; then
    api_base="https://api.github.com"
  else
    api_base="https://${github_host}/api/v3"
  fi

  local api_path
  case "${RUNNER_SCOPE:-repo}" in
    org)
      if [ -z "${ORG_NAME:-}" ]; then
        log "RUNNER_SCOPE=org but ORG_NAME unset; leaving as-is"
        return 0
      fi
      api_path="orgs/${ORG_NAME}/actions/runners/${agent_id}"
      ;;
    ent*)
      log "enterprise scope validation not implemented; leaving as-is"
      return 0
      ;;
    *)
      # repo scope: REPO_URL looks like https://<host>/<owner>/<repo>
      local repo_path="${REPO_URL#*://*/}"
      if [ -z "$repo_path" ] || [ "$repo_path" = "${REPO_URL:-}" ]; then
        log "cannot parse REPO_URL; leaving as-is"
        return 0
      fi
      api_path="repos/${repo_path}/actions/runners/${agent_id}"
      ;;
  esac

  # Bounded timeouts so a DNS/TLS/network stall can't block runner startup;
  # a timeout falls into the default case below and leaves the config as-is.
  local status
  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 15 \
    -H "Authorization: token ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${api_base}/${api_path}" 2>/dev/null)

  case "$status" in
    200)
      log "persisted runner agentId=${agent_id} still registered; reusing stored credentials"
      ;;
    404)
      log "persisted runner agentId=${agent_id} no longer exists on ${github_host};" \
        "wiping persisted registration to force fresh ACCESS_TOKEN registration"
      wipe_registration "$dir"
      ;;
    *)
      log "could not validate persisted runner (HTTP ${status:-none}); leaving as-is"
      ;;
  esac
}

# Sourced (tests/): define the functions only.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

setup_slot
ensure_rustup
tune_parallelism
preflight
exec /entrypoint.sh "$@"
