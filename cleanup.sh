#!/bin/bash
# Post-job cleanup script for GitHub Actions runner.
# Invoked automatically via ACTIONS_RUNNER_HOOK_JOB_COMPLETED after each job.
#
# Only the CHEAP tidy-up that has to happen after every job. The size caps
# live in pruner.sh, run by the `pruner` compose service (issue #16: they used
# to cost 21-39 s per job here). JOB_STARTED (pre-job.sh) sweeps up after a
# job whose runner was killed before this hook ran.
#
# Intentionally not using set -e: individual cleanup failures should not
# prevent other cleanups from running.
#
# KEEP: the slot caches (see preflight-entrypoint.sh) and the work dir, which
#       lives in the slot (RUNNER_DATA_DIR/slots/<id>/work), not under /tmp.
# DELETE: /tmp contents, Gradle daemon/journals/locks, runner _diag logs.

# Empty dir $1 (/tmp), keeping the dir itself.
clean_tmp() {
  find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
}

cleanup() {
  local before after
  echo "[cleanup] Running post-job cleanup..."
  before=$(df -h / | awk 'NR==2 {print $4}')

  clean_tmp /tmp

  # Gradle daemon / journals / locks only. Keep modules-2, build-cache-*,
  # transforms-*. $HOME covers both the root (default) and RUN_AS_ROOT=false
  # (/home/runner) runner users.
  rm -rf "$HOME"/.gradle/daemon/ "$HOME"/.gradle/caches/journal-* 2>/dev/null
  # Shallow on purpose: Gradle's lock files sit at most three levels under
  # caches/, and a find over the whole (multi-GB) tree is what made this slow.
  find "$HOME"/.gradle/caches -maxdepth 3 -name '*.lock' -delete 2>/dev/null

  # Runner diagnostic logs
  find /actions-runner/_diag -name '*.log' -delete 2>/dev/null

  # The job is over: the pruner may trim this slot again.
  if [ -n "${RUNNER_SLOT_DIR:-}" ]; then rm -f "$RUNNER_SLOT_DIR/busy"; fi

  after=$(df -h / | awk 'NR==2 {print $4}')
  echo "[cleanup] Post-job cleanup complete. Disk free: ${before} -> ${after}"
}

# Sourced (tests/): define the functions only.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
cleanup
