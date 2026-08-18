#!/bin/bash
# Pre-job hook for GitHub Actions runner.
# Invoked via ACTIONS_RUNNER_HOOK_JOB_STARTED before each job.
#
# JOB_COMPLETED does not run when the runner process dies (OOM). This sweep
# covers that case: delete incomplete/poison entries only. Do not rm -rf
# cache trees — named volumes are the warm cache.
#
# Intentionally not using set -e: individual prune failures should not
# prevent the job from starting.
#
# NOTE: this is only half the fix. Workflows that restore ~/.bun/install/cache
# via actions/cache with restore-keys can re-import a poisoned entry from the
# GitHub cache, which outlives this container. Those workflows should use an
# exact cache key (no restore-keys) so a corrupt entry cannot be carried
# forward across lockfile changes.

echo "[pre-job] Surgical prune of incomplete cache entries..."

# Bun: a killed job leaves partial tarballs (*.tmp / *.part). The next job
# then fails with "Fail extracting tarball for ..." and it looks like a
# dependency problem rather than a runner problem.
find /root/.bun/install/cache \( -name '*.tmp' -o -name '*.part' \) -delete 2>/dev/null || true

# Gradle: leftover lock / journal / daemon state from a killed compile.
# Keep modules-2, build-cache-*, and transforms-*.
rm -f /root/.gradle/caches/modules-2/modules-2.lock 2>/dev/null || true
rm -rf /root/.gradle/caches/journal-* 2>/dev/null || true
rm -rf /root/.gradle/daemon/ 2>/dev/null || true

echo "[pre-job] Prune complete."
