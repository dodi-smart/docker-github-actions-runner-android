#!/bin/bash
# Post-job cleanup script for GitHub Actions runner.
# Invoked automatically via ACTIONS_RUNNER_HOOK_JOB_COMPLETED after each job.
# Removes rebuildable caches that grow unbounded between jobs.
#
# Intentionally not using set -e: individual cleanup failures should not
# prevent other cleanups from running.

echo "[cleanup] Running post-job cleanup..."
BEFORE=$(df -h / | awk 'NR==2 {print $4}')

# Temp files from builds
find /tmp -mindepth 1 -delete 2>/dev/null || true

# Gradle build caches (rebuilt each job from source)
rm -rf /root/.gradle/caches/build-cache-* 2>/dev/null || true
rm -rf /root/.gradle/caches/transforms-* 2>/dev/null || true
rm -rf /root/.gradle/caches/journal-* 2>/dev/null || true

# Gradle daemon logs and state
rm -rf /root/.gradle/daemon/ 2>/dev/null || true

# Bun package cache.
#
# Bun is not in this image — setup-bun installs it per job — but the cache at
# /root/.bun/install/cache survives between jobs in the same container. A job
# killed mid-download leaves a partial tarball there, and every later job on
# this container then fails with:
#
#   error: Fail extracting tarball for "next"
#
# The failure is sticky: re-running does not clear it, and it looks like a
# dependency problem rather than a runner problem. Removing the cache costs a
# cold install and buys determinism.
#
# NOTE: this is only half the fix. Workflows that restore ~/.bun/install/cache
# via actions/cache with restore-keys can re-import a poisoned entry from the
# GitHub cache, which outlives this container. Those workflows should use an
# exact cache key (no restore-keys) so a corrupt entry cannot be carried
# forward across lockfile changes.
rm -rf /root/.bun/install/cache 2>/dev/null || true

# pnpm/npm/yarn stores, same failure mode if those ever get used here
rm -rf /root/.npm/_cacache 2>/dev/null || true
rm -rf /root/.cache/pnpm 2>/dev/null || true
rm -rf /root/.cache/yarn 2>/dev/null || true

# Runner diagnostic logs
find /actions-runner/_diag -name '*.log' -delete 2>/dev/null || true
find /runner-data/_diag -name '*.log' -delete 2>/dev/null || true

AFTER=$(df -h / | awk 'NR==2 {print $4}')
echo "[cleanup] Post-job cleanup complete. Disk free: ${BEFORE} -> ${AFTER}"
