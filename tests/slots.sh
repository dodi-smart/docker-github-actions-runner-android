#!/bin/bash
# Slot claim, cache links and the job hooks (preflight-entrypoint.sh,
# pre-job.sh, cleanup.sh) against a throwaway RUNNER_DATA_DIR:
#   - concurrent claims get distinct slots; a released slot is reused;
#   - RUNNER_<id>_LABELS applies to its slot only; control slots are c<n>;
#   - cache paths link into the slot (replacing what was there), not with
#     RUNNER_CACHES=off;
#   - pre-job marks the slot busy, waits for a pruner holding .prune.lock,
#     and sweeps top-level bun leftovers only after a crashed job; cleanup
#     clears busy and /tmp but never the work dir;
#   - every linked cache store is one the pruner bounds.
# Needs flock and GNU find (Linux, or `docker run ubuntu`):
#   bash tests/slots.sh
# Each ( ... ) group stands for one runner container, so the runner env it
# sets is meant to stay inside it:
# shellcheck disable=SC2030,SC2031,SC2034
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

data="$work/data"
home="$work/home"
mkdir -p "$data" "$home"

# Run setup_slot in a child that holds its slot for $2 seconds and reports
# "<id> <labels> <workdir>" to file $1.
claim() {
  local out="$1" hold="$2"
  (
    # shellcheck source=SCRIPTDIR/../preflight-entrypoint.sh
    source "$here/preflight-entrypoint.sh"
    CACHE_LINKS=("bun:$home/.bun" "pnpm/store:$home/.local/share/pnpm" "toolcache:$home/toolcache")
    RUNNER_DATA_DIR="$data" setup_slot >/dev/null
    echo "$RUNNER_SLOT $LABELS $RUNNER_WORKDIR" >"$out"
    sleep "$hold"
  )
}

# --- concurrent claims -------------------------------------------------------
export LABELS=docker,light RUNNER_2_LABELS=docker,light,large
for i in 1 2 3 4; do claim "$work/claim.$i" 3 & done
sleep 1
ids=$(cut -d' ' -f1 "$work"/claim.* | sort -n | tr '\n' ' ')
[ "$ids" = "1 2 3 4 " ] || fail "concurrent claims got '$ids', want '1 2 3 4 '"
for f in "$work"/claim.*; do
  read -r id labels wd <"$f"
  [ "$wd" = "$data/slots/$id/work" ] || fail "slot $id workdir $wd"
  [ -d "$wd" ] || fail "slot $id workdir missing"
  if [ "$id" = 2 ]; then
    [ "$labels" = docker,light,large ] || fail "slot 2 labels $labels"
  else
    [ "$labels" = docker,light ] || fail "slot $id labels $labels"
  fi
done
wait
unset RUNNER_2_LABELS

# Released slots are claimed again from the lowest id.
claim "$work/again" 0
[ "$(cut -d' ' -f1 "$work/again")" = 1 ] || fail "after release, claim got $(cat "$work/again")"

# --- cache links ---------------------------------------------------------------
[ "$(readlink "$home/.bun")" = "$data/slots/1/cache/bun" ] || fail "bun link: $(readlink "$home/.bun")"
[ "$(readlink "$home/.local/share/pnpm")" = "$data/slots/1/cache/pnpm/store" ] || fail "pnpm store link"
[ -d "$data/slots/1/cache/toolcache" ] || fail "toolcache store not created"

# An existing directory at a cache path (the writable layer) is replaced.
rm "$home/toolcache" && mkdir -p "$home/toolcache/stale"
claim "$work/replace" 0
[ -L "$home/toolcache" ] || fail "existing dir not replaced by a link"
[ -e "$data/slots/1/cache/toolcache/stale" ] && fail "stale layer content leaked into the slot"

# RUNNER_CACHES=off leaves the paths alone.
rm "$home/.bun"
(
  # shellcheck source=SCRIPTDIR/../preflight-entrypoint.sh
  source "$here/preflight-entrypoint.sh"
  CACHE_LINKS=("bun:$home/.bun")
  RUNNER_CACHES=off
  RUNNER_DATA_DIR="$data" setup_slot >/dev/null
)
[ -e "$home/.bun" ] && fail "RUNNER_CACHES=off still linked caches"

# Control runners claim c<n> slots and keep their LABELS.
(
  # shellcheck source=SCRIPTDIR/../preflight-entrypoint.sh
  source "$here/preflight-entrypoint.sh"
  CACHE_LINKS=()
  RUNNER_SLOT_PREFIX=c LABELS=control RUNNER_1_LABELS=nope
  RUNNER_DATA_DIR="$data" setup_slot >/dev/null
  echo "$RUNNER_SLOT $LABELS" >"$work/control"
)
[ "$(cat "$work/control")" = "c1 control" ] || fail "control claim: $(cat "$work/control")"

# No RUNNER_DATA_DIR: no slot, nothing exported (the image outside compose).
(
  # shellcheck source=SCRIPTDIR/../preflight-entrypoint.sh
  source "$here/preflight-entrypoint.sh"
  unset RUNNER_DATA_DIR
  setup_slot
  [ -z "${RUNNER_SLOT:-}" ] || echo "slot without data dir" >"$work/noslot"
)
[ -e "$work/noslot" ] && fail "claimed a slot without RUNNER_DATA_DIR"

# --- parallelism under a CPU limit ----------------------------------------------
# cpu_quota reads the cgroup; stub it with what a 1.5-CPU limit gives.
(
  # shellcheck source=SCRIPTDIR/../preflight-entrypoint.sh
  source "$here/preflight-entrypoint.sh"
  cpu_quota() { echo 2; }
  unset CARGO_BUILD_JOBS CMAKE_BUILD_PARALLEL_LEVEL MAKEFLAGS
  GRADLE_OPTS="-Xmx1g" MAKEFLAGS="-j9"
  tune_parallelism >/dev/null
  echo "$RUNNER_CPU_LIMIT|$CARGO_BUILD_JOBS|$CMAKE_BUILD_PARALLEL_LEVEL|$MAKEFLAGS|$GRADLE_OPTS" >"$work/tuned"
)
[ "$(cat "$work/tuned")" = "2|2|2|-j9|-Xmx1g -Dorg.gradle.workers.max=2" ] ||
  fail "cpu limit tuned to: $(cat "$work/tuned")"
(
  source "$here/preflight-entrypoint.sh"
  cpu_quota() { return 1; } # unlimited
  unset CARGO_BUILD_JOBS
  tune_parallelism >/dev/null
  echo "${CARGO_BUILD_JOBS:-unset}" >"$work/tuned"
)
[ "$(cat "$work/tuned")" = unset ] || fail "no cpu limit still tuned: $(cat "$work/tuned")"

# --- pre-job ---------------------------------------------------------------
slot="$data/slots/1"
cache="$home/.bun/install/cache"
bun_leftovers() {
  mkdir -p "$cache/.tmp/x" "$cache/next@16.3.8@@@1" "$cache/@scope/pkg@1@@@1"
  : >"$cache/next@16.3.8@@@1/chunk.tmp" # package content that ends in .tmp
  : >"$cache/react@19.part"
  : >"$cache/@scope/pkg@2.tmp"
}

# A clean previous job (no busy marker): mark busy, sweep nothing.
bun_leftovers
rm -f "$slot/busy"
HOME="$home" RUNNER_SLOT_DIR="$slot" bash "$here/pre-job.sh" >/dev/null
[ -e "$slot/busy" ] || fail "pre-job did not mark the slot busy"
[ -e "$cache/react@19.part" ] || fail "pre-job swept after a job that finished"

# A crashed previous job left busy behind: sweep the leftovers. A pruner
# holding .prune.lock delays the job, up to PRUNE_WAIT_SECONDS.
(exec 8>"$slot/.prune.lock"; flock 8; sleep 2) &
sleep 0.3
start=$(date +%s)
HOME="$home" RUNNER_SLOT_DIR="$slot" PRUNE_WAIT_SECONDS=10 bash "$here/pre-job.sh" >/dev/null
waited=$(($(date +%s) - start))
wait
[ "$waited" -ge 1 ] || fail "pre-job did not wait for the pruner (${waited}s)"
[ -e "$cache/.tmp" ] && fail "bun .tmp scratch dir survived"
[ -e "$cache/react@19.part" ] && fail "top-level .part survived"
[ -e "$cache/@scope/pkg@2.tmp" ] && fail "scoped .tmp survived"
[ -e "$cache/next@16.3.8@@@1/chunk.tmp" ] || fail "pre-job deleted package content"

# Bounded: a pruner that never lets go does not block the job.
(exec 8>"$slot/.prune.lock"; flock 8; sleep 4) &
sleep 0.3
start=$(date +%s)
HOME="$home" RUNNER_SLOT_DIR="$slot" PRUNE_WAIT_SECONDS=1 bash "$here/pre-job.sh" >/dev/null
waited=$(($(date +%s) - start))
[ "$waited" -le 3 ] || fail "pre-job waited ${waited}s past PRUNE_WAIT_SECONDS=1"
wait

# --- cleanup ---------------------------------------------------------------
tmp="$work/tmp"
mkdir -p "$tmp/junk/deep" "$slot/work/repo/repo"
: >"$tmp/file"
: >"$slot/work/repo/repo/keep"
(
  # shellcheck source=SCRIPTDIR/../cleanup.sh
  source "$here/cleanup.sh"
  set +eu # cleanup.sh runs without -e on purpose: one failed step must not stop the rest
  clean_tmp "$tmp"
  clean_tmp() { :; } # the real /tmp is not ours to wipe
  HOME="$home" RUNNER_SLOT_DIR="$slot" cleanup >/dev/null
)
left=$(find "$tmp" -mindepth 1 -maxdepth 1 -printf '%f ')
[ -z "$left" ] || fail "cleanup left ${left}in tmp"
[ -d "$tmp" ] || fail "cleanup removed tmp itself"
[ -e "$slot/work/repo/repo/keep" ] || fail "cleanup touched the work dir"
[ -e "$slot/busy" ] && fail "cleanup did not clear busy"

# --- store lists ------------------------------------------------------------
# Every store the preflight links must be one the pruner bounds.
(
  # shellcheck source=SCRIPTDIR/../pruner.sh
  source "$here/pruner.sh"
  pruned=" $(slot_stores | tr '\n' ' ')"
  source "$here/preflight-entrypoint.sh"
  for pair in "${CACHE_LINKS[@]}"; do
    store="${pair%%:*}"
    store="${store%%/*}"
    case "$pruned" in *" $store "*) ;; *) echo "$store" ;; esac
  done
) >"$work/unpruned"
[ -s "$work/unpruned" ] && fail "linked but never pruned: $(tr '\n' ' ' <"$work/unpruned")"

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "slots: all checks passed"
