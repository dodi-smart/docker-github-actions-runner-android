#!/bin/bash
# Pre-job hook for GitHub Actions runner.
# Invoked via ACTIONS_RUNNER_HOOK_JOB_STARTED before each job.
#
# 1. Mark the slot busy so pruner.sh leaves its caches alone while the job
#    runs. If the pruner is mid-pass on this slot, wait for it (bounded) so a
#    job never starts on a half-evicted cache.
# 2. Crash sweep. JOB_COMPLETED (cleanup.sh) does not run when the runner
#    process dies (OOM), and a `busy` marker it never removed says so. Then,
#    and only then, delete what a killed job leaves half-written. Do not rm -rf
#    cache trees: the slot caches are the warm cache. Without a slot (the image
#    run outside compose) there is no marker, so it always sweeps.
#
# Intentionally not using set -e: individual prune failures should not
# prevent the job from starting.
#
# NOTE: this is only half the fix. Workflows that restore ~/.bun/install/cache
# via actions/cache with restore-keys can re-import a poisoned entry from the
# GitHub cache, which outlives this container. Those workflows should use an
# exact cache key (no restore-keys) so a corrupt entry cannot be carried
# forward across lockfile changes.

PRUNE_WAIT_SECONDS="${PRUNE_WAIT_SECONDS:-600}"

crashed=true
if [ -n "${RUNNER_SLOT_DIR:-}" ] && [ -d "$RUNNER_SLOT_DIR" ]; then
  [ -e "$RUNNER_SLOT_DIR/busy" ] || crashed=false
  if exec 8>"$RUNNER_SLOT_DIR/.prune.lock"; then
    flock -w "$PRUNE_WAIT_SECONDS" 8 ||
      echo "[pre-job] pruner still busy on $RUNNER_SLOT_DIR after ${PRUNE_WAIT_SECONDS}s; starting anyway"
    touch "$RUNNER_SLOT_DIR/busy"
    exec 8>&-
  fi
fi

[ "$crashed" = true ] || exit 0
echo "[pre-job] Previous job did not finish; sweeping incomplete cache entries..."

# Bun: a killed job leaves partial extractions (*.tmp / *.part, and the .tmp
# scratch dir) next to the package folders: at the top of the cache, or one
# level down for @scope. The next job then fails with "Fail extracting tarball
# for ..." and it looks like a dependency problem rather than a runner
# problem. Only those two levels: the cache holds hundreds of thousands of
# files, and a file inside a package that happens to end in .tmp is content.
bun_cache="$HOME/.bun/install/cache"
find "$bun_cache" "$bun_cache"/@*/ -mindepth 1 -maxdepth 1 \( -name '*.tmp' -o -name '*.part' \) \
  -exec rm -rf {} + 2>/dev/null

# Gradle: leftover lock / journal / daemon state from a killed compile.
# Keep modules-2, build-cache-*, and transforms-*.
rm -f "$HOME"/.gradle/caches/modules-2/modules-2.lock 2>/dev/null
rm -rf "$HOME"/.gradle/caches/journal-* "$HOME"/.gradle/daemon/ 2>/dev/null

echo "[pre-job] Sweep complete."
