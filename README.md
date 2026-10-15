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

[`docker-compose.yml`](docker-compose.yml) is the X64 layout (beelink by
default; hetzner uses the same file with its own `.env`) — three ephemeral
runners, each with its own work **and** cache volumes, plus a nightly
`pruner`. Per-host `.env` examples with the target labels are in
[`hosts/`](hosts/). After pulling a new image on a host:

```
docker compose pull && docker compose up -d
```

Existing named `runner-work*` volumes keep their data; new cache volumes
start empty and warm on first jobs. Do not share one bun/gradle/mise volume
across the three containers: concurrent jobs would corrupt the same tree.

## Runner pools and labels

Jobs pick runners by capability label, never by machine name. Each host's
`.env` sets `LABELS` (the runner binary adds `self-hosted`, the OS and the
architecture itself):

| Pool | `.env` example | `LABELS` | Caches |
|------|----------------|----------|--------|
| hetzner (X64) | [`hosts/hetzner.env.example`](hosts/hetzner.env.example) | `self-hosted,Linux,X64,docker,x86,light,agent,hetzner` | all volumes |
| beelink (X64) | [`hosts/beelink.env.example`](hosts/beelink.env.example) | `self-hosted,Linux,X64,docker,x86,large,light,beelink` | all volumes |
| rpi5 (ARM64) | [`hosts/rpi5.env.example`](hosts/rpi5.env.example) | `self-hosted,Linux,ARM64,docker,agent,rpi5` | work only |

| Capability label | Meaning |
|------------------|---------|
| `light` | default checks, release, deploy steps (X64 only: no rpi5) |
| `large` | heavy jobs: Gradle/Android, Next.js builds (beelink) |
| `agent` | review, triage, assist (hetzner and rpi5) |

The rpi5 pool is an agent/utility pool: it has no `light` label and must not
mount the heavy cache volumes. Its `.env` example sets
`COMPOSE_FILE=docker-compose.yml:hosts/rpi5.compose.yml`, which layers
[`hosts/rpi5.compose.yml`](hosts/rpi5.compose.yml) over the base file so each
runner keeps only `docker.sock` and its work volume (and the pruner only
prunes Docker).

### Rolling out a label change

Runners are ephemeral and re-register on their next job, so changing labels is
a `.env` edit plus a recreate:

1. Copy the host's `hosts/<host>.env.example` values into its `.env` (keep the
   real `APP_*` values). On rpi5 also keep the `COMPOSE_FILE` line.
2. `docker compose pull && docker compose up -d`.
3. Check the pool in the org's runner list (Settings, Actions, Runners): each
   runner should show the labels above. `docker compose ps` shows `healthy`
   once `Runner.Listener` is up.

## Ephemeral runners

`EPHEMERAL` is `"true"` in the compose file. The upstream entrypoint
(`myoung34/github-runner`) only tests `[ -n "${EPHEMERAL}" ]` (and the same for
`DISABLE_AUTO_UPDATE`), so any non-empty value, `"false"` included, passes
`--ephemeral` to `config.sh`. The previous `EPHEMERAL: "false"` therefore
never kept runners persistent: they have always been ephemeral, one job per
container, restarted by `restart: unless-stopped`. The compose file now says
what actually happens. Each job gets a clean container; the caches survive on
the named volumes below.

`DISABLE_AUTO_UPDATE` is empty by default. Set it to any non-empty value in
`.env` to disable runner self-update (`false` disables it too).

## Health check

Each runner reports healthy while `Runner.Listener` is alive
(`pgrep -f Runner.Listener`, exec form: under `CMD-SHELL` the wrapping
`sh -c` would match its own command line). The container restarts after each
ephemeral job; `start_period` (120 s) keeps the re-registration from counting
as failures.

## Image identity

The image carries `RUNNER_IMAGE_TAG` (the fully pinned tag, e.g.
`2.338.0-jdk21-sdk36-node24`) and `RUNNER_IMAGE_REVISION` (the commit it was
built from) as environment variables, set from build args by `deploy.yml`
(`build.yml` sets `pr-<number>` and the head SHA). Jobs can print them to tell
which image they ran on. Local builds default to `dev`.

## X64 cache volumes

This compose is for the **X64** class (`beelink`, `hetzner`). The `LABELS`
default is the beelink set; hosts override it in `.env` (see the table above).
The runners are ephemeral, but the volumes survive between containers and
jobs.

Each runner gets its own:

| Mount | Volume (runner / runner-2 / runner-3) | Why | Capped by pruner |
|-------|----------------------------------------|-----|------------------|
| `/tmp/runner/work` | `runner-work*` | Job workspace. Cleanup spares `$RUNNER_WORKDIR`. | no |
| `/root/.bun` | `runner-bun*` | Bun install cache | yes |
| `/root/.npm` | `runner-npm*` | npm cache | no |
| `/root/.cache/pnpm` | `runner-pnpm*` | pnpm store | no |
| `/root/.gradle` | `runner-gradle*` | Gradle modules, build-cache, transforms | yes |
| `/root/.cargo` | `runner-cargo*` | Cargo registry | no |
| `/root/.rustup` | `runner-rustup*` | Rust toolchains (issue #8) | no |
| `/root/.konan` | `runner-konan*` | Kotlin/Native toolchain and dependencies | no |
| `/root/.local/share/mise` | `runner-mise-data*` | mise tool installs (`MISE_DATA_DIR`) | yes, whole tool versions |
| `/root/.cache/mise` | `runner-mise-cache*` | mise downloads (`MISE_CACHE_DIR`) | yes |
| `/root/.cache/hk` | `runner-hk*` | hk cache, incl. pkl (`HK_CACHE_DIR`, `HK_PKL_CACHE_DIR`) | yes |

The Dockerfile sets `MISE_DATA_DIR`, `MISE_CACHE_DIR`, `HK_CACHE_DIR` and
`HK_PKL_CACHE_DIR` so the tools write where the volumes are mounted. The
`~/.cache` directory is never mounted as a whole: that would shadow the pnpm
volume, so each subdirectory has its own volume. `jdx/mise-action` should use
`cache: false` on these runners; the volumes replace its GitHub-cache step.

Budget ~20 GB per capped cache directory (enforced by the nightly pruner with
LRU, not a wipe). The remaining volumes (npm, pnpm, cargo, rustup, konan) are
not capped yet (issue #7 tracks the bun/gradle-only caps; hard-linked stores
need care). ARM64 / Pi hosts should **not** mount these cache volumes — those
runners isolate to `RUNNER_TEMP`, see `hosts/rpi5.compose.yml`.

## Maintenance: per-job cleanup and the nightly pruner

`cleanup.sh` (the `JOB_COMPLETED` hook) only does the cheap tidy-up after each
job: `/tmp` outside the workdir, Gradle daemon/journals/locks, runner `_diag`
logs. The expensive scans used to run there on every job and cost 21–39 s each
(issue #16). They now run once a day in the `pruner` compose service, which
uses the same image with [`pruner.sh`](pruner.sh) as its entrypoint and
mounts only the capped cache volumes plus `docker.sock`:

- LRU size caps (`CACHE_CAP_BYTES`, default 20 GiB) on gradle, bun, the mise
  cache and the hk cache, evicting by last access time; mise installs are
  evicted as whole `tool/version` directories so a tool is never left half
  deleted (`MISE_DATA_CAP_BYTES`).
- `docker system prune -af --filter until=24h`
- `docker builder prune -af --filter until=72h`

Named volumes are never pruned. The first run is 5 minutes after start
(`PRUNE_INITIAL_DELAY`), then every `PRUNE_INTERVAL_SECONDS` (86400). Run it
once by hand with
`docker compose run --rm -e PRUNE_RUN_ONCE=true pruner`.

Do **not** tmpfs `/tmp`. `RUNNER_WORKDIR` is `/tmp/runner/work`; a tmpfs
or a blanket `find /tmp -delete` hides or wipes the work volume.

### Workflows must use the volume homes

Named volumes are unused if the job relocates the caches. On these X64
self-hosted runners, workflows must **not** isolate `GRADLE_USER_HOME` or
`BUN_INSTALL_CACHE_DIR` (or `npm_config_cache` / `CARGO_HOME` /
`MISE_DATA_DIR` / `MISE_CACHE_DIR` / `HK_CACHE_DIR`) to
`$RUNNER_TEMP`. That is the `setup-stack` local-home mode in
`dodi-smart/.github` — `deps-verify` stays isolated; `pr-checks` uses the
default homes so the volumes are actually read.

The other half of cache poison is GitHub `actions/cache` with
`restore-keys` re-importing a partial bun tarball. Use an exact key, or
do not upload the bun install cache at all.

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
| GitHub Actions versions | Renovate (`config:recommended`) |
| New JDK major versions | Weekly workflow queries the [Adoptium API](https://api.adoptium.net) and opens a PR |
| New Node LTS majors | Weekly workflow queries the [Node Release schedule](https://github.com/nodejs/Release/blob/main/schedule.json) and opens a PR |
| Android SDK platform level | Weekly workflow queries `sdkmanager` and opens a PR |
| Android build-tools | Weekly workflow queries `sdkmanager` and opens a PR |
| Android NDK | Weekly workflow queries `sdkmanager` and opens a PR |

Every pull request is validated by [`build.yml`](.github/workflows/build.yml),
which builds each JDK against the default Node, each Node against the default
JDK, and one `linux/arm64` build of the default pair. Its `All builds passed`
job is the single check to require in branch protection.

Because this repository is a fork, `renovate.json` sets
`"forkProcessing": "enabled"`. The Mend-hosted Renovate App leaves fork
processing disabled for org-wide ("All repositories") installations, so without
that flag Renovate silently skips the repository and the base image is never
bumped.

The weekly SDK/JDK/Node workflow opens its PR with `GITHUB_TOKEN`, which means
GitHub does not run `build.yml` on it. Upstream solves this with an
`AUTOMERGE_PAT` secret and `gh pr merge --auto`; this fork does not, so those
PRs are merged manually and the builds run on merge.

## Runner registration preflight

The image wraps the base entrypoint with
[`preflight-entrypoint.sh`](preflight-entrypoint.sh). When
`CONFIGURED_ACTIONS_RUNNER_FILES_DIR` is set, the upstream entrypoint reuses
persisted registration credentials without checking them, so a runner that was
removed on GitHub's side crash-loops forever instead of re-registering. The
preflight asks GitHub whether the persisted runner still exists and wipes the
stored registration only on a definitive `404`, letting a fresh `ACCESS_TOKEN`
registration take over. Timeouts, missing variables, and unparseable state all
leave the configuration untouched.

## Building locally

```
docker build -f Dockerfile .
```

Build args can be used to customize the image. See the top of the
[`Dockerfile`](Dockerfile) for the current defaults and available args
(`VERSION`, `JAVA_VERSION`, `NODE_VERSION`, `COMPILE_SDK`, `BUILD_TOOLS`,
`NDK_VERSION`, `SDK_TOOLS`, `RUNNER_IMAGE_TAG`, `RUNNER_IMAGE_REVISION`).

Example:
```
docker build --build-arg JAVA_VERSION=17 --build-arg NODE_VERSION=22 --build-arg COMPILE_SDK=35 -f Dockerfile .
```

## Inspiration
- https://github.com/kriskda/docker-github-action-android-container (comes with emulator which we don't need)
- https://github.com/jordond/docker-android-github-runner (desire more configurability - re:version of myoung34 container, etc)
