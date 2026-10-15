#!/bin/bash
# Post-job cleanup script for GitHub Actions runner.
# Invoked automatically via ACTIONS_RUNNER_HOOK_JOB_COMPLETED after each job.
#
# Persist package, Gradle/Cargo and mise/hk caches on the named volumes. This
# hook only does the CHEAP tidy-up that has to happen after every job. The
# expensive size-cap scans (du over multi-GB trees, LRU eviction) used to run
# here and cost 21-39 s per job (issue #16); they now live in pruner.sh, run
# nightly by the `pruner` compose service. JOB_STARTED (pre-job.sh) is the
# poison sweep for a killed runner process.
#
# Intentionally not using set -e: individual cleanup failures should not
# prevent other cleanups from running.
#
# KEEP: $HOME/.bun, $HOME/.npm, $HOME/.cache/pnpm, $HOME/.cache/yarn,
#       $HOME/.cache/mise, $HOME/.local/share/mise, $HOME/.cache/hk,
#       $HOME/.konan, $HOME/.rustup,
#       Gradle modules-2 / build-cache-* / transforms-*, Cargo registry.
# DELETE: /tmp contents except $RUNNER_WORKDIR (and $RUNNER_TEMP if under
#         /tmp), Gradle daemon/journals/locks, runner _diag logs.

echo "[cleanup] Running post-job cleanup..."
BEFORE=$(df -h / | awk 'NR==2 {print $4}')

# True when $1 is $2 or lives inside $2.
_inside() {
  [ -n "$2" ] || return 1
  case "$1" in "$2"|"$2"/*) return 0 ;; esac
  return 1
}

# True when $1 is a strict ancestor of $2.
_ancestor_of() {
  [ -n "$2" ] || return 1
  case "$2" in "$1"/*) return 0 ;; esac
  return 1
}

# RUNNER_WORKDIR is /tmp/runner/work in docker-compose.yml. A blanket
# `find /tmp -delete` wipes the work volume. Spare the workdir (and
# RUNNER_TEMP if it sits under /tmp), plus their ancestors under /tmp.
#
# Walk top-down and never descend into a spared tree: the work volume holds
# checkouts plus node_modules, and `find -depth` (which disables -prune) used
# to walk every path in it on every job. Only strict ancestors of a spared
# path are entered, so the cost is the handful of entries outside the workdir.
clean_dir() {
  local dir="$1" workdir="$2" temp="$3" path
  while IFS= read -r -d '' path; do
    if _inside "$path" "$workdir" || _inside "$path" "$temp"; then
      continue
    fi
    if _ancestor_of "$path" "$workdir" || _ancestor_of "$path" "$temp"; then
      clean_dir "$path" "$workdir" "$temp"
      continue
    fi
    rm -rf "$path" 2>/dev/null || true
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

clean_tmp() {
  local workdir="${RUNNER_WORKDIR:-/tmp/runner/work}"
  local temp="${RUNNER_TEMP:-}"
  workdir="${workdir%/}"
  temp="${temp%/}"

  # Only a RUNNER_TEMP strictly under /tmp needs sparing.
  case "$temp" in /tmp/*) ;; *) temp="" ;; esac

  clean_dir /tmp "$workdir" "$temp"
}

clean_tmp

# Gradle daemon / journals / locks only. Keep modules-2, build-cache-*,
# transforms-*. $HOME covers both the root (default) and RUN_AS_ROOT=false
# (/home/runner) runner users.
rm -rf "$HOME"/.gradle/daemon/ 2>/dev/null || true
rm -rf "$HOME"/.gradle/caches/journal-* 2>/dev/null || true
# Shallow on purpose: Gradle's lock files sit at most three levels under
# caches/, and a find over the whole (multi-GB) tree is what made this slow.
find "$HOME"/.gradle/caches -maxdepth 3 -name '*.lock' -delete 2>/dev/null || true

# Runner diagnostic logs
find /actions-runner/_diag -name '*.log' -delete 2>/dev/null || true
find /runner-data/_diag -name '*.log' -delete 2>/dev/null || true

AFTER=$(df -h / | awk 'NR==2 {print $4}')
echo "[cleanup] Post-job cleanup complete. Disk free: ${BEFORE} -> ${AFTER}"
