#!/bin/bash
# Post-job cleanup script for GitHub Actions runner.
# Invoked automatically via ACTIONS_RUNNER_HOOK_JOB_COMPLETED after each job.
#
# Persist package and Gradle/Cargo caches on the named volumes. Cap each
# runner's gradle-home and bun-home at ~20 GB with LRU eviction — do not
# wholesale wipe. JOB_STARTED (pre-job.sh) is the poison sweep for a killed
# runner process; this hook is the tidy-up when the job finishes normally.
#
# Intentionally not using set -e: individual cleanup failures should not
# prevent other cleanups from running.
#
# KEEP: /root/.bun, /root/.npm, /root/.cache/pnpm, /root/.cache/yarn,
#       Gradle modules-2 / build-cache-* / transforms-*, Cargo registry.
# DELETE: /tmp contents except $RUNNER_WORKDIR (and $RUNNER_TEMP if under
#         /tmp), Gradle daemon/journals/locks, runner _diag logs.

CACHE_CAP_BYTES="${CACHE_CAP_BYTES:-21474836480}" # 20 GiB

echo "[cleanup] Running post-job cleanup..."
BEFORE=$(df -h / | awk 'NR==2 {print $4}')

# True when $1 is $2, a descendant of $2, or an ancestor of $2.
_spared() {
  local path="$1"
  local keep="$2"
  [ -z "$keep" ] && return 1
  case "$path" in
    "$keep"|"$keep"/*) return 0 ;;
  esac
  case "$keep" in
    "$path"/*) return 0 ;;
  esac
  return 1
}

# RUNNER_WORKDIR is /tmp/runner/work on the beelinks. A blanket
# `find /tmp -delete` wipes the work volume. Spare the workdir (and
# RUNNER_TEMP if it sits under /tmp), plus their ancestors under /tmp.
clean_tmp() {
  local workdir="${RUNNER_WORKDIR:-/tmp/runner/work}"
  local temp="${RUNNER_TEMP:-}"
  workdir="${workdir%/}"
  temp="${temp%/}"

  if [ -n "$temp" ] && [ "$temp" != "/tmp" ] && [ "${temp#/tmp/}" = "$temp" ]; then
    temp=""
  fi
  if [ "$temp" = "/tmp" ]; then
    temp=""
  fi

  local path
  while IFS= read -r -d '' path; do
    _spared "$path" "$workdir" && continue
    _spared "$path" "$temp" && continue
    rm -rf "$path" 2>/dev/null || true
  done < <(find /tmp -mindepth 1 -depth -print0 2>/dev/null)
}

# LRU-evict oldest regular files until $1 is at or under CACHE_CAP_BYTES.
# Does not wholesale wipe the tree.
lru_cap() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  local size
  size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
  [ -n "$size" ] || return 0
  if [ "$size" -le "$CACHE_CAP_BYTES" ]; then
    return 0
  fi
  local excess=$((size - CACHE_CAP_BYTES))
  local freed=0
  echo "[cleanup] $dir is ${size} bytes (cap ${CACHE_CAP_BYTES}); LRU-evicting oldest files"
  local rec fsize path
  while IFS= read -r -d '' rec; do
    [ "$freed" -ge "$excess" ] && break
    rec="${rec#*	}"
    fsize="${rec%%	*}"
    path="${rec#*	}"
    [ -n "$path" ] && [ -n "$fsize" ] || continue
    rm -f "$path" 2>/dev/null || true
    freed=$((freed + fsize))
  done < <(find "$dir" -type f -printf '%T@\t%s\t%p\0' 2>/dev/null | sort -z -n)
  find "$dir" -type d -empty -delete 2>/dev/null || true
}

clean_tmp

# Gradle daemon / journals / locks only. Keep modules-2, build-cache-*,
# transforms-*.
rm -rf /root/.gradle/daemon/ 2>/dev/null || true
rm -rf /root/.gradle/caches/journal-* 2>/dev/null || true
find /root/.gradle -name '*.lock' -delete 2>/dev/null || true

# Runner diagnostic logs
find /actions-runner/_diag -name '*.log' -delete 2>/dev/null || true
find /runner-data/_diag -name '*.log' -delete 2>/dev/null || true

lru_cap /root/.gradle
lru_cap /root/.bun

AFTER=$(df -h / | awk 'NR==2 {print $4}')
echo "[cleanup] Post-job cleanup complete. Disk free: ${BEFORE} -> ${AFTER}"
