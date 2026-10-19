# docker-github-actions-runner-android

A self-hosted GitHub Actions runner image, plus a Docker Compose setup for
running it at scale. The image builds on
[myoung34/github-runner](https://github.com/myoung34/docker-github-actions-runner)
and adds:

- a Temurin JDK, the Android SDK and Node.js LTS, so jobs can skip
  `setup-java`, `setup-android` and `setup-node`;
- multi-arch images (`linux/amd64`, `linux/arm64`).

The Compose setup adds:

- ephemeral runners with persistent cache volumes;
- a `pruner` service that does the maintenance;
- a local action archive cache that avoids GitHub's download rate limits.

## Quick start

1. Create a GitHub App for runner registration. See the
   [base image docs](https://github.com/myoung34/docker-github-actions-runner#environment-variables).
2. Copy [`.env.example`](.env.example) to `.env` and set `APP_ID`,
   `APP_PRIVATE_KEY` and `APP_LOGIN`.
3. Start the runners:
   ```bash
   docker compose up -d
   ```

[`docker-compose.yml`](docker-compose.yml) starts three runners and a `pruner`.
Each runner is **ephemeral**: it takes one job, then restarts and registers
again with a clean container. Only the named volumes survive between jobs.

To update a host, run `docker compose pull && docker compose up -d`.

## Fit it to your setup

**One host or many.** Run the same Compose file on every host and change only
`.env`. To run more or fewer runners per host, add or remove `runner-N`
services, along with their volumes.

**Different kinds of machines.** Give each host the capability labels your
workflows select on, through `LABELS` in its `.env`. For example, `build` for
general jobs and `heavy` for memory-hungry ones. Workflows then ask for
`runs-on: [self-hosted, Linux, build]`. Label by what a machine can do, not by
its name. A host can carry several labels, so a large machine labelled
`build,heavy` also picks up general jobs when the others are busy.

**One runner in another pool.** `RUNNER_<N>_LABELS` (for `runner`, `runner-2`,
`runner-3`) replaces `LABELS` for that runner alone. A host whose runners are
`light` can let one of them also build, with
`RUNNER_3_LABELS=docker,x86,light,large`, without a second host file.

**Coordination runners.** `COMPOSE_PROFILES=control` adds two runners that
carry only `CONTROL_LABELS` (default `control`). Point the short jobs a merge
waits on at them, such as a picker or a required summary job, so those never
queue behind long builds. They hold no `docker.sock` and no tool cache, so keep
jobs that check out and build code off them.

**Small hosts.** Boards such as a Raspberry Pi have little disk. Layer
[`hosts/no-caches.compose.yml`](hosts/no-caches.compose.yml) by setting
`COMPOSE_FILE` in `.env`. Those runners skip the per-runner cache volumes.

**Repository or enterprise runners.** The Compose file registers runners for
an organization (`RUNNER_SCOPE: org`). For other scopes, change the runner
environment to what the
[base image](https://github.com/myoung34/docker-github-actions-runner#environment-variables)
supports.

**Your own image.** Set `RUNNER_IMAGE` to use a fork or a pinned tag. See
[Image tags](#image-tags).

## Caches

Each runner gets its own volume for these caches:

- bun, npm and pnpm
- Gradle
- Cargo and rustup
- Kotlin/Native
- mise and hk

The image sets `MISE_DATA_DIR`, `MISE_CACHE_DIR` and `HK_CACHE_DIR` so those
tools write there.

- **Never share a cache volume between runners.** Concurrent jobs would
  corrupt it.
- **Keep the default cache locations in workflows.** If a job moves
  `GRADLE_USER_HOME` or `BUN_INSTALL_CACHE_DIR` into `$RUNNER_TEMP`, the
  volumes go unused.
- **Turn off the GitHub cache where a volume replaces it.** For example, use
  `cache: false` on `jdx/mise-action`.
- **Don't put `/tmp` on tmpfs.** The job workspace is `/tmp/runner/work`.

## Action archive cache

Ephemeral runners download every `uses:` action on every job. Several runners
behind one IP address soon hit `429 Too Many Requests` in "Set up job".

The runner can read action archives from a local directory before it downloads
anything. Set `ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE` to that directory. Here it
is `/opt/actionarchivecache`, mounted read-only into every runner. The runner
never writes this directory itself, so the `pruner` fills it every hour. It
uses the GitHub App's token, so the downloads count against the App's rate
limit rather than your IP address. It fetches:

- every `uses:` found in the repositories listed in `PREFETCH_SOURCES`, such as
  the repo that holds your reusable workflows;
- the actions listed in `PREFETCH_EXTRA`.

With neither variable set, the cache stays empty and jobs download as usual. A
cache miss always falls back to a normal download.

To fill the cache straight away:

```bash
docker compose run --rm pruner prefetch
```

To confirm it works, re-run a job with debug logging. "Set up job" then shows
`Copied action archive '/opt/actionarchivecache/...'`.

## Maintenance

The `pruner` service ([`pruner.sh`](pruner.sh)) keeps slow work off the job
path:

- **Nightly:** trims the Gradle, bun, mise and hk caches to `CACHE_CAP_BYTES`
  each (default 20 GiB), least recently used first. The bun cache drops whole
  package folders (`install/cache/<pkg>@<ver>@@@1`, by the atime of their
  `package.json`) and never `bin/`: bun reuses a package folder as complete
  whenever it exists, so a single evicted file would go missing from every
  later install. mise tool versions are dropped whole too; the Gradle, mise
  download and hk caches drop single files. It then
  runs `docker system prune --filter until=24h` and
  `docker builder prune --filter until=72h`. Named volumes are never pruned.
- **Hourly:** fills the action archive cache, capped at 2 GiB.

After each job, [`cleanup.sh`](cleanup.sh) does only a quick tidy-up: `/tmp`,
Gradle daemons and locks, and runner logs.

To run the nightly pass once by hand:

```bash
docker compose run --rm -e PRUNE_RUN_ONCE=true pruner
```

## Image tags

Images are published to `ghcr.io/dodi-smart/github-runner`.

| Tag | Pins |
|---|---|
| `latest` | Nothing |
| `jdk21` | JDK major |
| `node22` | Node major |
| `jdk21-node22` | JDK and Node majors |
| `2.338.0-jdk21-sdk36-node24` | Everything: runner, JDK, SDK and Node. Never overwritten |

[`matrix.json`](matrix.json) lists the available JDK and Node versions and the
defaults. Each image sets `RUNNER_IMAGE_TAG` and `RUNNER_IMAGE_REVISION`, so a
job can tell which image it ran on.

To use another Android platform, install it in the job:
`sdkmanager "platforms;android-28"`.

## Notes

- `EPHEMERAL` and `DISABLE_AUTO_UPDATE` count as set for any non-empty value,
  `"false"` included. The upstream entrypoint only checks whether they are
  empty.
- [`preflight-entrypoint.sh`](preflight-entrypoint.sh) wipes a stored runner
  registration only after GitHub confirms that runner is gone (`404`). A
  removed runner then registers again instead of crash-looping.

## Development

[`build.yml`](.github/workflows/build.yml) builds every pull request. Its
`All builds passed` check is the one to require.

Renovate keeps the base image and the actions up to date; `forkProcessing` is
on because this repo is a fork. A weekly workflow opens pull requests for new
JDK, Node LTS, Android SDK, build-tools and NDK versions.

To build locally:

```bash
docker build --build-arg JAVA_VERSION=17 --build-arg NODE_VERSION=22 .
```

The build args and their defaults are at the top of the
[`Dockerfile`](Dockerfile).
