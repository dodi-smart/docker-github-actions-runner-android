# docker-github-actions-runner-android
Based off https://github.com/myoung34/docker-github-actions-runner but adds the
android sdk into the container so we don't need to run the setup-android action
every time from: https://github.com/android-actions/setup-android

The Android SDK requires Java, so the container includes a Temurin JDK as well,
which means you can also skip the setup-java action:
https://github.com/actions/setup-java

Node.js LTS is also baked in (see `matrix.json` for available versions), so
`actions/setup-node` is unnecessary for LTS workflows.

Images are published as multi-arch manifests for both `linux/amd64` and
`linux/arm64`, so Apple Silicon Macs (via Docker Desktop / OrbStack) and ARM
Linux hosts run natively without emulation.

To run the container, check out the environment variables from the base image:
https://github.com/myoung34/docker-github-actions-runner#environment-variables

There is also an example docker-compose file which uses .env file to set the
variables.

## Image tags

Images are published to GitHub Container Registry (GHCR):
- `ghcr.io/dodi-smart/github-runner`

### Tag scheme

Each image is built with a specific combination of base runner version, JDK
version, Node major version, and Android SDK level. Tags let you choose how
tightly to pin:

| Tag | Example | What it pins | What floats |
|-----|---------|--------------|-------------|
| `latest` | `latest` | Nothing | Runner, JDK, Node, and SDK all track latest |
| `jdk<VERSION>` | `jdk21` | JDK major version | Runner, Node (default), and SDK track latest |
| `node<VERSION>` | `node22` | Node major version | Runner, JDK (default), and SDK track latest |
| `jdk<JDK>-node<NODE>` | `jdk21-node22` | JDK + Node | Runner and SDK track latest |
| `<RUNNER>-jdk<JDK>-sdk<SDK>-node<NODE>` | `2.332.0-jdk21-sdk36-node22` | Everything | Nothing — fully pinned |

### Which tag should I use?

- **`latest`** — always the newest runner, default JDK, default Node LTS, and
  latest Android SDK. Good for staying current, but builds may break if a new
  SDK introduces incompatibilities.
- **`jdk21`** / **`jdk17`** — pin the JDK version but still get runner, Node,
  and SDK updates automatically. A good balance for most users.
- **`jdk21-node22`** — pin both JDK and Node majors; runner and SDK still
  track latest. Useful when an LTS-pinned Node is part of your build's
  contract.
- **`2.332.0-jdk21-sdk36-node22`** — fully pinned. Use this for reproducible
  builds where you want complete control over when to upgrade. Old pinned tags
  are never overwritten; they remain in the registry from previous builds.

### What's in each image?

Every image includes:
- The [myoung34/github-runner](https://github.com/myoung34/docker-github-actions-runner) base image
- [Temurin JDK](https://adoptium.net/) (the version in the tag)
- [Node.js](https://nodejs.org/) LTS (the version in the tag) — installed
  from NodeSource, replacing the base image's older system Node
- Android SDK platform matching the SDK level in the tag (e.g., `sdk36` = `platforms;android-36`)
- Latest Android build-tools and NDK for that SDK level
- Android SDK command-line tools, platform-tools, and cmake
- Multi-arch manifest covering `linux/amd64` and `linux/arm64`

Projects that need additional SDK platforms (e.g., an older `compileSdk`) can
install them at build time:
```yaml
- run: sdkmanager "platforms;android-28"
```

### Currently available JDK versions

The build matrix is defined in [`matrix.json`](matrix.json). Check that file
for the current list of JDK versions and which one is the default.

### Currently available Node versions

Also defined in [`matrix.json`](matrix.json) — see `node_versions` for the
current LTS majors and `default_node` for the version applied to short tags
like `latest` and `jdk<VERSION>`.

## Automated updates

Versions are kept up to date automatically:

| Component | Mechanism |
|-----------|-----------|
| Base runner image | [Renovate](https://github.com/renovatebot/renovate) tracks `myoung34/github-runner` Docker tags |
| GitHub Actions versions | Renovate (`config:base`) |
| New JDK major versions | Weekly workflow queries the [Adoptium API](https://api.adoptium.net) and opens a PR |
| New Node LTS majors | Weekly workflow queries the [Node Release schedule](https://github.com/nodejs/Release/blob/main/schedule.json) and opens a PR |
| Android SDK platform level | Weekly workflow queries `sdkmanager` and opens a PR |
| Android build-tools | Weekly workflow queries `sdkmanager` and opens a PR |
| Android NDK | Weekly workflow queries `sdkmanager` and opens a PR |

## Building locally

```
docker build -f Dockerfile .
```

Build args can be used to customize the image. See the top of the
[`Dockerfile`](Dockerfile) for the current defaults and available args
(`VERSION`, `JAVA_VERSION`, `NODE_VERSION`, `COMPILE_SDK`, `BUILD_TOOLS`,
`NDK_VERSION`, `SDK_TOOLS`).

Example:
```
docker build --build-arg JAVA_VERSION=17 --build-arg NODE_VERSION=22 --build-arg COMPILE_SDK=35 -f Dockerfile .
```

## Inspiration
- https://github.com/kriskda/docker-github-action-android-container (comes with emulator which we don't need)
- https://github.com/jordond/docker-android-github-runner (desire more configurability - re:version of myoung34 container, etc)
