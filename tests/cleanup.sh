#!/bin/bash
# The JOB_COMPLETED hook runs under `bash -e`, as the runner invokes it, and must
# exit 0 and clear the slot's `busy` marker whatever the home looks like: no
# Gradle cache at all (control runners, a runner that never ran Gradle), or a
# Gradle cache with daemon state to drop. A non-zero exit fails the job in
# "Complete runner"; a marker left behind makes every later job look like a
# crash recovery. /tmp is not wiped here: clean_tmp is stubbed out.
#   bash tests/cleanup.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/harness.sh
source "$here/harness.sh"

# Run cleanup.sh's main path under bash -e, with clean_tmp stubbed so the real
# /tmp is left alone.
hook() {
  local home="$1" slot="$2"
  HOME="$home" RUNNER_SLOT_DIR="$slot" bash -e -c '
    source "$1"
    clean_tmp() { :; }
    cleanup
  ' _ "$root/cleanup.sh" >/dev/null 2>&1
}

slot="$work/slot"
mkdir -p "$slot"

home="$work/empty"
mkdir -p "$home"
touch "$slot/busy"
hook "$home" "$slot" || fail "exit $? with no gradle cache"
gone "$slot/busy"

home="$work/gradle"
mkdir -p "$home/.gradle/daemon/8.10" "$home/.gradle/caches/journal-1" "$home/.gradle/caches/modules-2/files-2.1"
touch "$home/.gradle/caches/modules-2/modules-2.lock" "$home/.gradle/caches/modules-2/files-2.1/keep.jar"
touch "$slot/busy"
hook "$home" "$slot" || fail "exit $? with a gradle cache"
gone "$slot/busy"
gone "$home/.gradle/daemon"
gone "$home/.gradle/caches/journal-1"
gone "$home/.gradle/caches/modules-2/modules-2.lock"
kept "$home/.gradle/caches/modules-2/files-2.1/keep.jar"

finish "cleanup exits 0 under bash -e and always clears busy"
