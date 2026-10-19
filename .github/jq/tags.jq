# Image tags of deploy.yml, one list per matrix entry:
#   jq -L .github/jq 'include "matrix"; include "tags"; ...' matrix.json
# $v holds the Dockerfile versions: runner_version, compile_sdk, build_tools,
# ndk_version. $dj / $dn are the default JDK / Node major from matrix.json.

# The fully pinned tag, baked into the image as RUNNER_IMAGE_TAG; it never
# changes meaning.
def image_tag($v):
  if .variant == "slim" then "\($v.runner_version)-jdk\(.java_version)-node\(.node_version)-slim"
  else "\($v.runner_version)-jdk\(.java_version)-sdk\($v.compile_sdk)-node\(.node_version)\(if .variant == "ndk" then "-ndk" else "" end)"
  end;

# Every tag the merged manifest list is published under.
def tags($v; $dj; $dn):
  . as $e
  | "\($v.runner_version)-jdk\($e.java_version)-sdk\($v.compile_sdk)" as $sdk
  | if $e.variant == "std" then
      [ (if $e.node_version == $dn then "jdk\($e.java_version)" else empty end),
        (if $e.java_version == $dj then "node\($e.node_version)" else empty end),
        "jdk\($e.java_version)-node\($e.node_version)",
        "\($sdk)-node\($e.node_version)",
        # Every Gradle-pinnable SDK component in the tag (compileSdk, build-tools), so
        # consumers can let Renovate derive them from the image pin.
        "\($sdk)-bt\($v.build_tools)-node\($e.node_version)",
        (if $e.java_version == $dj and $e.node_version == $dn then "latest" else empty end) ]
    elif $e.variant == "ndk" then
      # Only the ndk variant ships an NDK, so only it spells the NDK version out
      # (upstream's -sdk-ndk- and -sdk-bt-ndk- tags; Gradle ndkVersion via Renovate).
      [ "ndk",
        "\($sdk)-node\($e.node_version)-ndk",
        "\($sdk)-ndk\($v.ndk_version)-node\($e.node_version)",
        "\($sdk)-bt\($v.build_tools)-ndk\($v.ndk_version)-node\($e.node_version)" ]
    else
      ["slim", ($e | image_tag($v))]
    end;
