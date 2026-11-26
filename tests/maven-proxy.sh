#!/bin/bash
# Host-wide Maven proxy (issue #45): the maven-proxy service of
# docker-compose.yml, its init script and the preflight that installs it.
#   - the preflight installs maven-proxy/maven-proxy.gradle into
#     ~/.gradle/init.d and replaces a stale copy;
#   - the proxy, started from the real compose file against a fake upstream,
#     serves Maven Central, Google Maven and the Plugin Portal from their own
#     prefixes, fetches a file once however often and however concurrently it
#     is asked for, follows the portal's redirects into its cache, and never
#     caches a 429;
#   - with gradle on PATH: the init script redirects only the three upstream
#     repositories (and Robolectric), resolves through the proxy, and leaves
#     everything as declared when the proxy is down or MAVEN_PROXY=off.
# The proxy part needs docker, the last part gradle and java; each is skipped,
# with a note, when missing.
#   bash tests/maven-proxy.sh
# shellcheck disable=SC2030,SC2031  # ( ... ) groups are runner containers

# shellcheck source=tests/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

home="$work/home"
init="$home/.gradle/init.d/maven-proxy.gradle"

# install_init [VAR=value...]: run setup_maven_proxy as the preflight would.
install_init() {
  (
    # shellcheck source=SCRIPTDIR/../preflight-entrypoint.sh
    source "$root/preflight-entrypoint.sh"
    MAVEN_PROXY_INIT_SRC="$root/maven-proxy/maven-proxy.gradle"
    for assignment in "$@"; do export "${assignment?}"; done
    HOME="$home" setup_maven_proxy
  )
}

# --- preflight ---------------------------------------------------------------
install_init >/dev/null
cmp -s "$root/maven-proxy/maven-proxy.gradle" "$init" || fail "init script not installed into ~/.gradle/init.d"
echo stale >"$init"
install_init >/dev/null
cmp -s "$root/maven-proxy/maven-proxy.gradle" "$init" || fail "a stale init script was not replaced"
install_init MAVEN_PROXY_INIT_SRC="$work/missing" >/dev/null || fail "a missing source failed the preflight"

if ! docker info >/dev/null 2>&1; then
  echo "SKIP: no docker; the proxy itself is not tested"
  finish "maven-proxy: preflight install"
  exit 0
fi

# --- proxy ---------------------------------------------------------------------
# The real compose file, its maven-proxy service pointed at an `upstream` nginx
# that the override adds and publishes nothing. RUNNER_DATA_DIR holds the cache.
export RUNNER_DATA_DIR="$work/data"
export MAVEN_CENTRAL_URL=http://upstream/maven2
export GOOGLE_MAVEN_URL=http://upstream/google
export GRADLE_PLUGIN_PORTAL_URL=http://upstream/plugins
proxy_image=$(awk '/^  maven-proxy:/{s=1} s && /image:/{print $2; exit}' "$root/docker-compose.yml")
mkdir -p "$RUNNER_DATA_DIR/maven-proxy" "$work/srv"
cat >"$work/upstream.conf" <<'EOF'
server {
    listen 80;
    root /srv;
    location /maven2/limited/ { return 429; }
    location = /plugins/redir/a/1.0/a-1.0.jar { return 302 http://upstream/files/a-1.0.jar; }
    location = /plugins/redir/b/1.0/b-1.0.jar { absolute_redirect off; return 302 /files/b-1.0.jar; }
    location /maven2/slow/ { limit_rate 2m; }
}
EOF
cat >"$work/test.compose.yml" <<EOF
services:
  maven-proxy:
    ports: ["127.0.0.1::8080"]
  upstream:
    image: $proxy_image
    volumes:
      - $work/upstream.conf:/etc/nginx/conf.d/default.conf:ro
      - $work/srv:/srv:ro
EOF
artifact() { mkdir -p "$(dirname "$work/srv/$1")" && head -c "$2" /dev/urandom >"$work/srv/$1"; }
artifact maven2/org/ex/lib/1.0/lib-1.0.jar 100000
cat >"$work/srv/maven2/org/ex/lib/1.0/lib-1.0.pom" <<'EOF'
<project><modelVersion>4.0.0</modelVersion><groupId>org.ex</groupId><artifactId>lib</artifactId><version>1.0</version></project>
EOF
echo '<metadata/>' >"$work/srv/maven2/org/ex/lib/maven-metadata.xml"
artifact maven2/slow/big/1.0/big-1.0.jar 8000000 # 4 s at the upstream's 2 MB/s
artifact google/com/g/lib/1.0/lib-1.0.jar 1000
artifact plugins/p/lib/1.0/lib-1.0.jar 1000
artifact files/a-1.0.jar 1000
artifact files/b-1.0.jar 1000
chmod -R a+rX "$work/srv"

# compose <args>: the test project. The App variables are unset here, and
# compose warns about each; the rest of stderr is kept.
compose() {
  local rc=0
  docker compose --progress quiet --project-directory "$root" -p "maven-proxy-test-$$" \
    -f "$root/docker-compose.yml" -f "$work/test.compose.yml" "$@" 2>"$work/compose.err" || rc=$?
  grep -v 'variable is not set' "$work/compose.err" >&2 || true
  return "$rc"
}
# nginx hands the cache dir to its own user; give it back so $work can go.
teardown() {
  compose exec -T maven-proxy sh -c \
    "rm -rf /var/cache/maven-proxy/* && chown -R $(id -u):$(id -g) /var/cache/maven-proxy" >/dev/null 2>&1
  compose down -v >/dev/null 2>&1
}
at_exit teardown
compose up -d maven-proxy upstream >/dev/null
port=$(compose port maven-proxy 8080 | cut -d: -f2)
proxy="http://127.0.0.1:$port"
for _ in $(seq 1 50); do
  curl -fs "$proxy/healthz" >/dev/null 2>&1 && break
  sleep 0.2
done
[ "$(curl -s "$proxy/healthz")" = ok ] || fail "healthz does not answer ok"

# get <path>: "<status> <cache status> <sha256>" of a request through the proxy.
get() {
  local headers body status cache
  headers=$(mktemp "$work/headers.XXXXXX")
  body=$(mktemp "$work/body.XXXXXX")
  status=$(curl -s -D "$headers" -o "$body" -w '%{http_code}' "$proxy$1")
  cache=$(tr -d '\r' <"$headers" | awk -F': ' 'tolower($1) == "x-cache-status" {print $2}')
  echo "$status ${cache:--} $(sha256sum <"$body" | cut -d' ' -f1)"
  rm -f "$headers" "$body"
}
sha() { sha256sum <"$work/srv/$1" | cut -d' ' -f1; }
# upstream_hits <path>: how often the upstream was asked for <path>.
upstream_hits() { compose logs --no-log-prefix upstream 2>/dev/null | grep -c "\"GET $1 " || true; }

# Each prefix reaches its repository; the second request is a cache hit.
for p in maven2/org/ex/lib/1.0/lib-1.0.jar google/com/g/lib/1.0/lib-1.0.jar plugins/p/lib/1.0/lib-1.0.jar; do
  first=$(get "/$p")
  [ "$first" = "200 MISS $(sha "$p")" ] || fail "/$p first: $first"
  second=$(get "/$p")
  [ "$second" = "200 HIT $(sha "$p")" ] || fail "/$p second: $second"
  [ "$(upstream_hits "/$p")" = 1 ] || fail "/$p fetched upstream $(upstream_hits "/$p") times, want 1"
done

# Concurrent misses for one large file: one upstream download, five copies.
p=maven2/slow/big/1.0/big-1.0.jar
for i in 1 2 3 4 5; do get "/$p" >"$work/concurrent.$i" & done
wait
for i in 1 2 3 4 5; do
  read -r status _ digest <"$work/concurrent.$i"
  [ "$status $digest" = "200 $(sha "$p")" ] || fail "concurrent request $i: $(cat "$work/concurrent.$i")"
done
[ "$(upstream_hits "/$p")" = 1 ] || fail "concurrent misses fetched upstream $(upstream_hits "/$p") times, want 1"

# The portal's redirect is followed inside the proxy and cached under the
# requested path: the client sees a 200, and the second request stays local.
p=plugins/redir/a/1.0/a-1.0.jar
first=$(get "/$p")
[ "${first%% *} ${first##* }" = "200 $(sha files/a-1.0.jar)" ] || fail "redirect first: $first"
second=$(get "/$p")
[ "$second" = "200 HIT $(sha files/a-1.0.jar)" ] || fail "redirect second: $second"
[ "$(upstream_hits "/$p")" = 1 ] || fail "redirect asked upstream $(upstream_hits "/$p") times, want 1"
[ "$(upstream_hits /files/a-1.0.jar)" = 1 ] || fail "redirect target fetched $(upstream_hits /files/a-1.0.jar) times, want 1"
# A redirect to a path alone is followed on the same upstream.
p=plugins/redir/b/1.0/b-1.0.jar
first=$(get "/$p")
[ "${first%% *} ${first##* }" = "200 $(sha files/b-1.0.jar)" ] || fail "relative redirect: $first"

# A 429 passes through and is not cached: the next request asks again.
p=/maven2/limited/x/1.0/x-1.0.jar
[ "$(get "$p" | cut -d' ' -f1)" = 429 ] || fail "429 not passed through"
[ "$(get "$p" | cut -d' ' -f1)" = 429 ] || fail "429 not passed through the second time"
[ "$(upstream_hits "$p")" = 2 ] || fail "429 was cached ($(upstream_hits "$p") upstream requests, want 2)"

# Metadata is cached too (briefly); a missing file is a 404; other paths never
# reach upstream.
p=maven2/org/ex/lib/maven-metadata.xml
get "/$p" >/dev/null
[ "$(get "/$p")" = "200 HIT $(sha "$p")" ] || fail "metadata not cached"
[ "$(get /maven2/org/ex/none/1.0/none-1.0.jar | cut -d' ' -f1)" = 404 ] || fail "missing artifact is not a 404"
[ "$(get /elsewhere/x.jar | cut -d' ' -f1)" = 404 ] || fail "unknown prefix is not a 404"
[ "$(upstream_hits /elsewhere/x.jar)" = 0 ] || fail "unknown prefix reached upstream"

# --- gradle ----------------------------------------------------------------------
if ! command -v gradle >/dev/null 2>&1 || ! command -v java >/dev/null 2>&1; then
  echo "SKIP: no gradle/java on PATH; the init script is not run"
  finish "maven-proxy: preflight install, proxy cache"
  exit 0
fi
install_init >/dev/null
project="$work/project"
mkdir -p "$project"
echo "rootProject.name = 'probe'" >"$project/settings.gradle"
cat >"$project/build.gradle" <<'EOF'
plugins { id 'java' }
repositories {
    mavenCentral()
    google()
    gradlePluginPortal()
    maven { url = 'https://repo.example.com/maven2' }
}
configurations { probe }
dependencies { probe 'org.ex:lib:1.0' }
tasks.register('repos') {
    def urls = repositories.collect { it.url.toString() }
    def robolectric = tasks.named('test').get().systemProperties['robolectric.dependency.repo.url']
    doLast {
        println "repos: ${urls.join(' ')}"
        println "robolectric: ${robolectric}"
    }
}
tasks.register('resolve') {
    def files = configurations.probe
    doLast { println "resolved: ${files.files*.name.join(' ')}" }
}
EOF
# run_gradle <task> [VAR=value...]: gradle in the project, with the slot's home.
run_gradle() {
  local task="$1"
  shift
  env HOME="$home" "$@" gradle --no-daemon --console=plain -g "$home/.gradle" -p "$project" "$task" 2>&1
}
# repos_of <gradle output>: the repository URLs it printed, without trailing /.
repos_of() { grep '^repos:' <<<"$1" | sed 's|/ | |g; s|/$||; s/^repos: //'; }
declared="https://repo.maven.apache.org/maven2 https://dl.google.com/dl/android/maven2 https://plugins.gradle.org/m2 https://repo.example.com/maven2"

out=$(run_gradle repos MAVEN_PROXY_URL="$proxy") || fail "gradle failed with the proxy up: $out"
[ "$(repos_of "$out")" = "$proxy/maven2 $proxy/google $proxy/plugins https://repo.example.com/maven2" ] ||
  fail "with the proxy up, repos: $(grep '^repos:' <<<"$out" || echo "$out")"
grep -qx "robolectric: $proxy/maven2" <<<"$out" || fail "robolectric repo not redirected: $(grep '^robolectric:' <<<"$out")"
out=$(run_gradle resolve MAVEN_PROXY_URL="$proxy") || fail "gradle failed resolving: $out"
grep -qx 'resolved: lib-1.0.jar' <<<"$out" || fail "resolving through the proxy: $out"
[ "$(upstream_hits /maven2/org/ex/lib/1.0/lib-1.0.pom)" = 1 ] || fail "gradle did not fetch the pom through the proxy"

# Down (nothing listens there): a warning, and the repositories as declared.
out=$(run_gradle repos MAVEN_PROXY_URL=http://127.0.0.1:9) || fail "gradle failed with the proxy down: $out"
grep -q 'maven-proxy: http://127.0.0.1:9 does not answer' <<<"$out" || fail "no warning with the proxy down"
[ "$(repos_of "$out")" = "$declared" ] ||
  fail "with the proxy down, repos: $(grep '^repos:' <<<"$out")"
grep -qx 'robolectric: null' <<<"$out" || fail "robolectric redirected with the proxy down"

# A job that opts out.
out=$(run_gradle repos MAVEN_PROXY_URL="$proxy" MAVEN_PROXY=off) || fail "gradle failed with MAVEN_PROXY=off: $out"
[ "$(repos_of "$out")" = "$declared" ] ||
  fail "with MAVEN_PROXY=off, repos: $(grep '^repos:' <<<"$out")"

finish "maven-proxy: preflight install, proxy cache, gradle init script"
