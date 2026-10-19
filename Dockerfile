ARG VERSION=2.338.0-ubuntu-noble
ARG JAVA_VERSION=21
ARG NODE_VERSION=24
ARG COMPILE_SDK=36.1
ARG BUILD_TOOLS=37.0.0
ARG NDK_VERSION=30.0.16248370
ARG SDK_TOOLS=8512546_latest
ARG ANDROID_ROOT=/usr/local/lib/android
# JDK that sdkmanager runs on in the sdk stages. Fixed on purpose and independent
# of JAVA_VERSION: the SDK layer must come out identical for every JDK/Node tag,
# so it is shared in the registry and on hosts instead of stored once per tag.
ARG SDK_JAVA_VERSION=21

################################################################################
# sdk: the Android SDK, built once for every tag
# - runs on a fixed JDK (SDK_JAVA_VERSION), never on JAVA_VERSION/NODE_VERSION
# - only the build args below reach this stage, so a JDK or Node bump does not
#   invalidate it
################################################################################
FROM eclipse-temurin:${SDK_JAVA_VERSION}-jdk-noble AS sdk
ARG COMPILE_SDK
ARG BUILD_TOOLS
ARG SDK_TOOLS
ARG ANDROID_ROOT

RUN apt-get -qq update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends unzip wget \
  && rm -rf /var/lib/apt/lists/*

# sdkmanager has no download retry: a truncated download from dl.google.com
# surfaces as "Archive is not a ZIP archive" and fails the whole build. It is
# idempotent (already-installed packages are skipped), so retry the whole
# command a few times, clearing its download scratch dir between attempts.
# Usage: sdk-install <sdk_root> <package>...
RUN cat > /usr/local/bin/sdk-install <<'EOF' && chmod +x /usr/local/bin/sdk-install
#!/bin/sh
set -u
sdk_root=$1
shift
attempt=1
until echo "y" | "${ANDROID_ROOT}/sdk/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk_root" "$@"; do
  if [ "$attempt" -ge 3 ]; then
    echo "sdkmanager failed after $attempt attempts" >&2
    exit 1
  fi
  echo "sdkmanager attempt $attempt failed, retrying in 15s..." >&2
  rm -rf "$sdk_root/.temp"
  attempt=$((attempt + 1))
  sleep 15
done
EOF

# download android tools and use it to install the SDK
WORKDIR /tmp
RUN mkdir -p ${ANDROID_ROOT}/sdk/cmdline-tools/latest \
  && wget -q -O android-sdk.zip https://dl.google.com/android/repository/commandlinetools-linux-$SDK_TOOLS.zip \
  && unzip -q android-sdk.zip \
  && cp -r ./cmdline-tools/* ${ANDROID_ROOT}/sdk/cmdline-tools/latest \
  && rm -rf android-sdk.zip cmdline-tools
RUN ${ANDROID_ROOT}/sdk/cmdline-tools/latest/bin/sdkmanager --licenses >/dev/null

# Install latest Android SDK components only. Older versions are not needed since
# build-tools are backward compatible, and you only need the platform matching
# your project's compileSdk. Projects needing older platforms can install them at
# build time via sdkmanager. The NDK and cmake live in the opt-in sdk-ndk stage.
RUN sdk-install ${ANDROID_ROOT}/sdk \
    "platform-tools" \
    "platforms;android-${COMPILE_SDK}" \
    "build-tools;${BUILD_TOOLS}" \
  && rm -rf ${ANDROID_ROOT}/sdk/.temp

################################################################################
# sdk-ndk: NDK and the SDK's own cmake, for the opt-in runner-ndk target
# - installed into a separate sdk root, so the final image gets only the delta
#   (ndk/ and cmake/) instead of a second full copy of the SDK
################################################################################
FROM sdk AS sdk-ndk
ARG NDK_VERSION
ARG ANDROID_ROOT

RUN mkdir -p /ndk-sdk && cp -r ${ANDROID_ROOT}/sdk/licenses /ndk-sdk/licenses
RUN sdk-install /ndk-sdk \
    "ndk;${NDK_VERSION}" \
    "cmake;3.22.1" \
  && rm -rf /ndk-sdk/.temp

################################################################################
# core: everything both runner targets share
# base image from https://github.com/myoung34/docker-github-actions-runner
# - the SDK comes first, straight on top of the base image, so its layer chain is
#   identical for every JDK/Node tag
# - then the tag-independent apt packages, then the JDK, then Node
################################################################################
FROM myoung34/github-runner:$VERSION AS core
ARG ANDROID_ROOT

COPY --from=sdk /usr/local/lib/android /usr/local/lib/android

# Set env variable for SDK Root (https://developer.android.com/studio/command-line/variables)
# ANDROID_HOME is deprecated, but older versions of Gradle rely on it
ENV ANDROID_SDK_ROOT=$ANDROID_ROOT/sdk
ENV ANDROID_HOME=$ANDROID_ROOT/sdk
ENV PATH="${PATH}:/usr/local/lib/android/sdk/platform-tools/"

# Packages that do not depend on JAVA_VERSION/NODE_VERSION, so this layer is
# shared by every tag too.
#   - iproute2: ip tools
#   - cmake, build-essential, swig: native builds
#   - xxd: not in the base image (https://github.com/compscidr/docker-github-actions-runner-android/issues/84)
#   - pigz: parallel gzip, used by tar/docker when available
RUN apt-get -qq update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    iproute2 cmake build-essential swig xxd pigz \
  && rm -rf /var/lib/apt/lists/*

# JAVA_VERSION and NODE_VERSION are declared only now, below the layers every tag
# shares: a build arg is part of the cache key of each RUN that follows its ARG,
# so declaring them at the top would rebuild (and re-hash) those layers per tag.
ARG JAVA_VERSION
ARG NODE_VERSION
# TARGETARCH is set automatically by Buildx (e.g. amd64, arm64) and matches the
# arch suffix Temurin uses on its apt-installed JDK directory.
ARG TARGETARCH

# https://adoptium.net/installation/linux
# add the gpg key and apt repo, then install the temurin jdk
RUN mkdir -p /etc/apt/keyrings \
  && wget -qO /etc/apt/keyrings/adoptium.asc https://packages.adoptium.net/artifactory/api/gpg/key/public \
  && echo "deb [signed-by=/etc/apt/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" > /etc/apt/sources.list.d/adoptium.list \
  && apt-get -qq update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends temurin-$JAVA_VERSION-jdk \
  && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/temurin-$JAVA_VERSION-jdk-$TARGETARCH

# install nodejs from NodeSource. Replaces the base image's Ubuntu-default node
# (currently node 18 on noble) with a current LTS that user workflows can rely
# on without an extra setup-node step.
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /actions-runner
LABEL maintainer="asen.lekov@dodi.li"

# Jobs run as root here, and GNU tar run as root keeps the owner ids stored in an
# archive. Toolchains that setup actions unpack into /opt/hostedtoolcache (the
# Flutter SDK, via subosito/flutter-action's `tar xf`) then belong to an unknown
# uid, and because the Flutter SDK is a git checkout that the flutter tool runs
# git on, git refuses it ("detected dubious ownership") and every flutter command
# exits 128. --no-same-owner makes root extract as root, which is what a
# non-root runner (GitHub-hosted) gets anyway. It stays global rather than a
# safe.directory entry, because the image's git (2.43) has no prefix match and
# the only other option, `safe.directory=*`, turns the check off for everything.
ENV TAR_OPTIONS=--no-same-owner

# Tool caches that outlive a job. Jobs run as root (HOME=/root), so these are
# the tools' own defaults made explicit: docker-compose.yml mounts one named
# volume on each of them. Mount the specific directories, never ~/.cache as a
# whole, or it would shadow the pnpm volume at ~/.cache/pnpm.
#   - mise: tool installs (data) and downloads (cache). jdx/mise-action and
#     `mise install` fill these.
#   - hk: HK_CACHE_DIR is its config/tool cache. HK_PKL_CACHE_DIR defaults to
#     ~/.cache/pklr, a sibling of ~/.cache/hk, so it is pinned underneath
#     HK_CACHE_DIR to live on the same volume.
ENV MISE_DATA_DIR=/root/.local/share/mise \
    MISE_CACHE_DIR=/root/.cache/mise \
    HK_CACHE_DIR=/root/.cache/hk \
    HK_PKL_CACHE_DIR=/root/.cache/hk/pklr

# Job hooks: JOB_STARTED is the poison sweep (covers OOM / killed runner);
# JOB_COMPLETED is the tidy-up. Neither wipes package / Gradle caches.
# pruner.sh is not a hook: the `pruner` compose service runs it nightly
# (LRU cache caps + docker prune), keeping those scans off the job path.
# --chmod sets the mode in the COPY layer itself, so no separate chmod layer
# holds a second copy of the scripts.
COPY --chmod=755 pre-job.sh /usr/local/bin/pre-job.sh
COPY --chmod=755 cleanup.sh /usr/local/bin/cleanup.sh
COPY --chmod=755 pruner.sh /usr/local/bin/pruner.sh
ENV ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/bin/pre-job.sh
ENV ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/cleanup.sh

# Preflight entrypoint: validates the persisted runner registration against
# GitHub before handing off to the upstream entrypoint. Upstream reuses
# CONFIGURED_ACTIONS_RUNNER_FILES_DIR credentials unconditionally, which
# crash-loops the container when the runner was removed server-side; the
# preflight wipes provably-dead registrations so a fresh ACCESS_TOKEN
# registration happens instead. See preflight-entrypoint.sh for details.
COPY --chmod=755 preflight-entrypoint.sh /usr/local/bin/preflight-entrypoint.sh

################################################################################
# runner-ndk (opt-in, `--target runner-ndk`): core + NDK + the SDK's cmake
# - the NDK and cmake;3.22.1 are several GB that most consumers never use
################################################################################
FROM core AS runner-ndk
ARG ANDROID_ROOT
COPY --from=sdk-ndk /ndk-sdk/ndk ${ANDROID_ROOT}/sdk/ndk
COPY --from=sdk-ndk /ndk-sdk/cmake ${ANDROID_ROOT}/sdk/cmake

# Image identity. deploy.yml passes the image tag and the commit it was built
# from; jobs read them (e.g. the runner report) to tell which image they ran
# on. They default to "dev" for local builds. Declared last: the values change
# on every build, so anything after them would never hit the layer cache.
ARG RUNNER_IMAGE_TAG=dev
ARG RUNNER_IMAGE_REVISION=dev
ENV RUNNER_IMAGE_TAG=$RUNNER_IMAGE_TAG \
    RUNNER_IMAGE_REVISION=$RUNNER_IMAGE_REVISION

ENTRYPOINT ["/usr/local/bin/preflight-entrypoint.sh"]
# Declaring ENTRYPOINT resets the CMD inherited from the base image, so the
# base image's CMD is restated here. See
# https://github.com/myoung34/docker-github-actions-runner#environment-variables
# for how to use the image
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]

################################################################################
# runner (default, MUST stay the last stage so a plain `docker build` makes it)
################################################################################
FROM core AS runner
ARG RUNNER_IMAGE_TAG=dev
ARG RUNNER_IMAGE_REVISION=dev
ENV RUNNER_IMAGE_TAG=$RUNNER_IMAGE_TAG \
    RUNNER_IMAGE_REVISION=$RUNNER_IMAGE_REVISION

ENTRYPOINT ["/usr/local/bin/preflight-entrypoint.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
