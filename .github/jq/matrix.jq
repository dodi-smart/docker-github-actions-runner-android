# Build-matrix building blocks shared by build.yml (PR) and deploy.yml:
#   jq -L .github/jq 'include "matrix"; ...' matrix.json
# The image variants (Dockerfile target), the platforms and the layer cache
# scope live here only, so the two workflows cannot drift apart.

def targets: {std: "runner", ndk: "runner-ndk", slim: "runner-slim"};

def legs: {
  amd64: {platform: "linux/amd64", arch: "amd64", runner: "ubuntu-latest"},
  arm64: {platform: "linux/arm64", arch: "arm64", runner: "ubuntu-24.04-arm"}
};

# One build leg. The standard image keeps the plain per-arch cache scope, the
# other variants their own (they also read the standard one).
def leg($java; $node; $variant; $arch):
  {java_version: $java, node_version: $node, variant: $variant, target: targets[$variant]}
  + legs[$arch]
  | . + {cache_scope: (if $variant == "std" then $arch else "\($variant)-\($arch)" end)};
