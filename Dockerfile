ARG VERSION=2.338.2-ubuntu-noble
ARG JAVA_VERSION=21
ARG NODE_VERSION=24
ARG COMPILE_SDK=37.2
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
# core: everything every runner target shares (and, as is, runner-slim)
# base image from https://github.com/myoung34/docker-github-actions-runner
# - the tag-independent apt packages first, then the JDK, then Node
################################################################################
FROM myoung34/github-runner:$VERSION AS core
# Packages that do not depend on JAVA_VERSION/NODE_VERSION, so this layer is
# shared by every tag too.
#   - iproute2: ip tools
#   - cmake, build-essential, swig: native builds
#   - xxd: not in the base image
#   - pigz: parallel gzip, used by tar/docker when available
RUN apt-get -qq update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    iproute2 cmake build-essential swig xxd pigz \
  && rm -rf /var/lib/apt/lists/*

# rustup-init only, no toolchain: ~/.cargo and ~/.rustup are links into the
# runner's slot, so anything installed there at build time would be hidden.
# The preflight runs it once per slot (`--default-toolchain none`, offline), so
# `rustup` is on PATH and the toolchains a job installs (dtolnay/rust-toolchain,
# rust-toolchain.toml) land in the warm slot cache. The checksum comes from the
# same versioned archive.
ARG RUSTUP_VERSION=1.29.1
# TARGETARCH is set automatically by Buildx (e.g. amd64, arm64). It also matches
# the arch suffix Temurin uses on its apt-installed JDK directory (JAVA_HOME).
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) triple=x86_64-unknown-linux-gnu ;; \
      arm64) triple=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported arch $TARGETARCH" >&2; exit 1 ;; \
    esac \
  && url="https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${triple}/rustup-init" \
  && curl -fsSL --retry 3 -o /usr/local/bin/rustup-init "$url" \
  && echo "$(curl -fsSL --retry 3 "$url.sha256" | cut -d' ' -f1)  /usr/local/bin/rustup-init" | sha256sum -c - \
  && chmod 755 /usr/local/bin/rustup-init
ENV PATH="/root/.cargo/bin:${PATH}"

# JAVA_VERSION and NODE_VERSION are declared only now, below the layers every tag
# shares: a build arg is part of the cache key of each RUN that follows its ARG,
# so declaring them at the top would rebuild (and re-hash) those layers per tag.
ARG JAVA_VERSION
ARG NODE_VERSION

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
# the tools' own defaults made explicit: the preflight links each of them into
# the runner's slot (see preflight-entrypoint.sh). Link the specific
# directories, never ~/.cache as a whole, or it would shadow ~/.cache/pnpm.
#   - mise: tool installs (data) and downloads (cache). jdx/mise-action and
#     `mise install` fill these.
#   - hk: HK_CACHE_DIR is its config/tool cache. HK_PKL_CACHE_DIR defaults to
#     ~/.cache/pklr, a sibling of ~/.cache/hk, so it is pinned underneath
#     HK_CACHE_DIR to live on the same volume.
ENV MISE_DATA_DIR=/root/.local/share/mise \
    MISE_CACHE_DIR=/root/.cache/mise \
    HK_CACHE_DIR=/root/.cache/hk \
    HK_PKL_CACHE_DIR=/root/.cache/hk/pklr

# Job hooks: JOB_STARTED marks the slot busy (and sweeps up after a killed
# job); JOB_COMPLETED is the tidy-up. Neither wipes package / Gradle caches.
# The scripts themselves come from the `scripts` stage, copied last into each
# target (see there).
ENV ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/bin/pre-job.sh \
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/cleanup.sh

# preflight-entrypoint.sh claims the runner's slot, links its caches, then
# validates a persisted registration before handing off to the upstream
# entrypoint (see the script for details).
ENTRYPOINT ["/usr/local/bin/preflight-entrypoint.sh"]
# Declaring ENTRYPOINT resets the CMD inherited from the base image, so the
# base image's CMD is restated here. See
# https://github.com/myoung34/docker-github-actions-runner#environment-variables
# for how to use the image
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]

################################################################################
# scripts: this repo's runtime scripts, the files edited most often. Every
# target copies them as its LAST layer before the identity, so editing one
# never invalidates (or re-pushes) the SDK and NDK layers below.
# - pruner.sh is not a hook: the `pruner` compose service runs it (cache
#   budgets + docker prune), keeping those scans off the job path
# - --chmod sets the mode in the COPY layer itself
################################################################################
FROM scratch AS scripts
COPY --chmod=755 preflight-entrypoint.sh pre-job.sh cleanup.sh pruner.sh /usr/local/bin/

################################################################################
# runner-slim (`--target runner-slim`): core without the Android SDK
# - for arm64 hosts (Android's build tools are x86_64-only), JS/JVM-only pools
#   and small disks
################################################################################
FROM core AS runner-slim
COPY --from=scripts / /
# Image identity. deploy.yml passes the image tag and the commit it was built
# from; jobs read them (e.g. the runner report) to tell which image they ran
# on. They default to "dev" for local builds. Declared last in every target
# (the same three lines close runner-ndk and runner): the values change on
# every build, so anything after them would never hit the layer cache.
ARG RUNNER_IMAGE_TAG=dev
ARG RUNNER_IMAGE_REVISION=dev
ENV RUNNER_IMAGE_TAG=$RUNNER_IMAGE_TAG \
    RUNNER_IMAGE_REVISION=$RUNNER_IMAGE_REVISION

################################################################################
# android: core + the Android SDK, the base of runner and runner-ndk
# - the SDK sits on top of the JDK/Node layers: the weekly SDK bump then only
#   replaces this layer, and hosts keep the JDK/Node layers they already have.
#   Its blob is the same for every JDK/Node tag (the sdk stage never sees
#   JAVA_VERSION/NODE_VERSION), so the registry stores and CI builds it once.
################################################################################
FROM core AS android
ARG ANDROID_ROOT
COPY --from=sdk ${ANDROID_ROOT} ${ANDROID_ROOT}
# Set env variable for SDK Root (https://developer.android.com/studio/command-line/variables)
# ANDROID_HOME is deprecated, but older versions of Gradle rely on it
ENV ANDROID_SDK_ROOT=$ANDROID_ROOT/sdk \
    ANDROID_HOME=$ANDROID_ROOT/sdk \
    PATH="${PATH}:${ANDROID_ROOT}/sdk/platform-tools/"

################################################################################
# runner-ndk (opt-in, `--target runner-ndk`): android + NDK + the SDK's cmake
# - the NDK and cmake;3.22.1 are several GB that most consumers never use
################################################################################
FROM android AS runner-ndk
ARG ANDROID_ROOT
COPY --from=sdk-ndk /ndk-sdk/ndk ${ANDROID_ROOT}/sdk/ndk
COPY --from=sdk-ndk /ndk-sdk/cmake ${ANDROID_ROOT}/sdk/cmake
COPY --from=scripts / /
ARG RUNNER_IMAGE_TAG=dev
ARG RUNNER_IMAGE_REVISION=dev
ENV RUNNER_IMAGE_TAG=$RUNNER_IMAGE_TAG \
    RUNNER_IMAGE_REVISION=$RUNNER_IMAGE_REVISION

################################################################################
# runner (default, MUST stay the last stage so a plain `docker build` makes it)
################################################################################
FROM android AS runner
COPY --from=scripts / /
ARG RUNNER_IMAGE_TAG=dev
ARG RUNNER_IMAGE_REVISION=dev
ENV RUNNER_IMAGE_TAG=$RUNNER_IMAGE_TAG \
    RUNNER_IMAGE_REVISION=$RUNNER_IMAGE_REVISION
