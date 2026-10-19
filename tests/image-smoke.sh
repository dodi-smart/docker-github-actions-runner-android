#!/bin/bash
# Smoke test for a built runner image: the toolchain a job relies on must be
# present and runnable, with the entrypoint bypassed so no runner registers.
#   bash tests/image-smoke.sh <image> [expected-jdk-major] [expected-node-major] [std|ndk|slim]
# Variants: std (runner) and ndk (runner-ndk) must carry the Android SDK; slim
# (runner-slim) must carry java/node/tools but no Android SDK.
# The check snippets are single-quoted on purpose: they expand inside the image.
# shellcheck disable=SC2016
set -euo pipefail

image="${1:?usage: tests/image-smoke.sh <image> [jdk-major] [node-major] [std|ndk|slim]}"
want_jdk="${2:-}"
want_node="${3:-}"
variant="${4:-std}"
case "$variant" in
  std | ndk | slim) ;;
  *) echo "unknown variant '$variant' (want std, ndk or slim)" >&2; exit 2 ;;
esac

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
sdkmanager='"$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_SDK_ROOT" --list_installed'
if [ "$variant" = slim ]; then
  # The slim image must not ship any part of the Android SDK.
  check "no sdkmanager on PATH" '! command -v sdkmanager'
  check "no Android SDK directories" \
    'for d in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" /usr/local/lib/android/sdk; do
       [ -z "$d" ] && continue
       for sub in platforms build-tools ndk cmdline-tools; do
         if [ -e "$d/$sub" ]; then echo "found $d/$sub"; exit 1; fi
       done
     done'
else
  check "sdkmanager lists the platform" "$sdkmanager" 'platforms;android-'
  check "sdkmanager lists build-tools" "$sdkmanager" 'build-tools;'
fi
if [ "$variant" = ndk ]; then
  check "NDK is installed" 'ls -d "$ANDROID_SDK_ROOT"/ndk/*/ >/dev/null'
fi
for tool in xxd flock jq git rustup-init; do
  check "$tool is on PATH" "command -v $tool"
done

if [ "$fails" -gt 0 ]; then
  echo "$fails smoke check(s) failed for $image"
  exit 1
fi
echo "image smoke passed for $image"
