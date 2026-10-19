#!/bin/bash
# Smoke test for a built runner image: the toolchain a job relies on must be
# present and runnable, with the entrypoint bypassed so no runner registers.
#   bash tests/image-smoke.sh <image> [expected-jdk-major] [expected-node-major]
# The check snippets are single-quoted on purpose: they expand inside the image.
# shellcheck disable=SC2016
set -euo pipefail

image="${1:?usage: tests/image-smoke.sh <image> [jdk-major] [node-major]}"
want_jdk="${2:-}"
want_node="${3:-}"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "ok:   $*"; }
indent() { printf '      %s\n' "${1//$'\n'/$'\n      '}"; }

# in_image <script>: run a bash snippet inside the image.
in_image() { docker run --rm --entrypoint bash "$image" -c "$1"; }

# check <description> <script> [grep pattern for the output]
check() {
  local what="$1" script="$2" pattern="${3:-}" out
  if ! out="$(in_image "$script" 2>&1)"; then
    fail "$what"
    indent "$out"
    return
  fi
  if [ -n "$pattern" ] && ! grep -Eq "$pattern" <<<"$out"; then
    fail "$what (output did not match /$pattern/)"
    indent "$out"
    return
  fi
  pass "$what"
}

jdk_pattern=""
[ -n "$want_jdk" ] && jdk_pattern="version \"${want_jdk}[.\"]"
node_pattern=""
[ -n "$want_node" ] && node_pattern="^v${want_node}\."

check "java -version" 'java -version' "$jdk_pattern"
check "JAVA_HOME is a JDK" 'test -n "$JAVA_HOME" && test -x "$JAVA_HOME/bin/java" && test -x "$JAVA_HOME/bin/javac"'
check "node -v" 'node -v' "$node_pattern"
check "sdkmanager lists the platform" \
  '"$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_SDK_ROOT" --list_installed' \
  'platforms;android-'
check "sdkmanager lists build-tools" \
  '"$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_SDK_ROOT" --list_installed' \
  'build-tools;'
for tool in xxd flock jq git; do
  check "$tool is on PATH" "command -v $tool"
done

if [ "$fails" -gt 0 ]; then
  echo "$fails smoke check(s) failed for $image"
  exit 1
fi
echo "image smoke passed for $image"
