#!/bin/bash
# The JOB_STARTED hook runs under `bash -e`, as the runner invokes it, and must
# exit 0 whatever the caches look like: no bun cache, a bun cache with no
# @scope folder, and one with leftovers to sweep. A non-zero exit fails the job
# before its first step.
#   bash tests/pre-job.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/harness.sh
source "$here/harness.sh"

hook() { env -u RUNNER_SLOT_DIR HOME="$1" bash -e "$root/pre-job.sh" >/dev/null 2>&1; }

home="$work/empty"
mkdir -p "$home"
hook "$home" || fail "exit $? with no bun cache"

home="$work/noscope"
mkdir -p "$home/.bun/install/cache/pkg"
hook "$home" || fail "exit $? with a bun cache and no @scope folder"

home="$work/leftovers"
cache="$home/.bun/install/cache"
mkdir -p "$cache/pkg" "$cache/@scope/pkg" "$cache/.tmp"
touch "$cache/x.tmp" "$cache/y.part" "$cache/@scope/z.tmp" "$cache/pkg/keep.tmp"
hook "$home" || fail "exit $? with leftovers to sweep"
gone "$cache/x.tmp"
gone "$cache/y.part"
gone "$cache/@scope/z.tmp"
kept "$cache/pkg/keep.tmp"

finish "pre-job exits 0 under bash -e and sweeps only partial extractions"
