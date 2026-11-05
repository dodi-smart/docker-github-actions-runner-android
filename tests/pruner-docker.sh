#!/bin/bash
# prune_docker against real daemons: keep labels, keep patterns and stopped
# containers carrying a keep label, in the normal and the low-space pass.
#
# Real daemons on purpose. The two image stores disagree on what several
# label!= filters mean, which a fake docker would never show, so every case runs
# on both. Each daemon is a throwaway docker:dind: this test prunes, so it talks
# to nothing else and stops if it finds itself connected to any other daemon.
# Needs GNU date and a docker that may run privileged containers:
#   bash tests/pruner-docker.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

dind_image=docker:29-dind
outer_host="${DOCKER_HOST:-}"
outer() { DOCKER_HOST="$outer_host" docker "$@"; }
export BUILDX_CONFIG="$work/buildx" # no builder state left behind for a daemon that is gone

# Age limits, which need no daemon.
now=$(date +%s)
age=$((now - $(until_epoch 1h30m)))
[ "$age" -ge 5400 ] && [ "$age" -le 5405 ] || fail "1h30m read as ${age}s"
[ "$(until_epoch 2026-11-03T21:00:00Z)" = "$(date -d 2026-11-03T21:00:00Z +%s)" ] || fail "a timestamp misread"
[ -z "$(until_epoch 2d)" ] || fail "2d is no docker duration and must not read as a time"

if ! outer info >/dev/null 2>&1; then
  echo "SKIP: no docker daemon to start docker:dind on"
  exit 0
fi

# start_daemon <name> <dockerd arg>...: a throwaway daemon, which every docker
# call of this test then talks to.
start_daemon() {
  local name="$1" port i
  shift
  at_exit "outer rm -f $name >/dev/null 2>&1"
  outer run -d --rm --privileged --name "$name" --hostname "$name" -p 127.0.0.1::2375 \
    -e DOCKER_TLS_CERTDIR= "$dind_image" --host=tcp://0.0.0.0:2375 --tls=false "$@" >/dev/null
  port=$(outer port "$name" 2375/tcp)
  export DOCKER_HOST="tcp://$port"
  for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    [ "$i" -lt 60 ] || { echo "daemon $name did not start"; exit 1; }
    sleep 1
  done
  if [ "$(docker info --format '{{.Name}}')" != "$name" ]; then
    echo "connected to a daemon other than $name, refusing to prune it"
    exit 1
  fi
}

# mkimage <tag> [<label>...]: a small image, unique through its name label. It
# needs a layer: an image without one has no creation time, so no age to prune by.
# build_epoch=<seconds> sets the build time.
mkdir "$work/context"
touch "$work/context/file"
mkimage() {
  local tag="$1" label
  shift
  {
    echo 'FROM scratch'
    echo 'COPY file /file'
    echo "LABEL fixture=\"$tag\""
    for label in "$@"; do echo "LABEL $label"; done
  } | docker build -q ${build_epoch:+--build-arg "SOURCE_DATE_EPOCH=$build_epoch"} -t "$tag" -f - "$work/context" >/dev/null
}

fixtures() {
  docker system prune -af >/dev/null
  mkimage by-label-a:1 keep.a=1
  mkimage by-label-b:1 keep.b=yes
  mkimage wrong-value:1 keep.b=no
  mkimage variscite:20.04
  mkimage ghcr.io/acme/tools/lint:1
  mkimage ghcr.io/other/lint:1
  mkimage junk:1
  docker tag variscite:20.04 also-tagged:1 # one protected tag keeps the image
  mkimage held-by-kept:1
  docker create --name kept --label keep.a=1 held-by-kept:1 /x >/dev/null
  mkimage held-by-unkept:1
  docker create --name unkept held-by-unkept:1 /x >/dev/null
  sleep 2 # older than an `until` of 0s
}

has_image() { docker image inspect "$1" >/dev/null 2>&1; }
has_container() { docker container inspect "$1" >/dev/null 2>&1; }
image_kept() { has_image "$1" || fail "$backend/$pass: image $1 should survive"; }
image_gone() { if has_image "$1"; then fail "$backend/$pass: image $1 should be pruned"; fi; }

# A file a keep pattern would expand to, were it ever globbed against the cwd.
cd "$work"
touch variscite:from-cwd

check_store() {
  backend="$1"
  DOCKER_PRUNE_KEEP_LABELS='keep.a keep.b=yes'
  DOCKER_PRUNE_KEEP_IMAGES='variscite:* ghcr.io/acme/*'

  # Everything is too young for the age limit: the keep path must not remove it.
  pass=young
  fixtures
  # Built long ago, arrived just now, like a pull: save and load sets that apart.
  build_epoch=1000000000 mkimage built-long-ago:1
  docker save built-long-ago:1 -o "$work/image.tar"
  docker image rm built-long-ago:1 >/dev/null
  docker load -q -i "$work/image.tar" >/dev/null
  DOCKER_PRUNE_UNTIL=1h
  out=$(prune_docker)
  image_kept junk:1
  image_kept held-by-unkept:1
  has_container unkept || fail "$backend/$pass: young stopped container removed"
  # Image age is the daemon's: from the build on overlay2, from arrival on containerd.
  if [ "$backend" = overlay2 ]; then image_gone built-long-ago:1; else image_kept built-long-ago:1; fi

  DOCKER_PRUNE_UNTIL=0s
  DOCKER_PRUNE_UNTIL_LOW=0s
  for pass in normal low; do
    fixtures
    if [ "$pass" = low ]; then
      # Only the low-space age may let this pass remove anything.
      out=$(DOCKER_PRUNE_UNTIL=1h prune_docker low)
    else
      out=$(prune_docker)
    fi
    image_kept by-label-a:1
    image_kept by-label-b:1
    image_kept variscite:20.04
    image_kept also-tagged:1
    image_kept ghcr.io/acme/tools/lint:1
    image_kept held-by-kept:1
    has_container kept || fail "$backend/$pass: stopped container with a keep label removed"
    image_gone wrong-value:1
    image_gone ghcr.io/other/lint:1
    image_gone junk:1
    image_gone held-by-unkept:1
    if has_container unkept; then fail "$backend/$pass: stopped container without a keep label survived"; fi
    grep -Eq 'kept image .*variscite:20\.04.* [0-9.]+[kMG]?B' <<<"$out" ||
      fail "$backend/$pass: no log line with the kept image and its size"
    grep -q 'kept image .*held-by-kept:1' <<<"$out" ||
      fail "$backend/$pass: no log line for the image held by a kept container"
    grep -q 'kept container kept' <<<"$out" || fail "$backend/$pass: no log line for the kept container"
    if grep -q 'docker system prune' <<<"$out"; then
      fail "$backend/$pass: system prune cannot honour keep settings"
    fi
  done

  # A failing listing must never read as "nothing is protected".
  pass=listing-fails
  fixtures
  out=$(
    docker() { case "$*" in 'image ls -q --no-trunc --filter label='*) return 1 ;; esac; command docker "$@"; }
    prune_docker
  )
  image_kept by-label-a:1
  image_kept junk:1
  grep -q 'skipping docker prune' <<<"$out" || fail "$backend/$pass: no log line for the skipped prune"

  # Empty settings: today's call, and nothing is protected.
  pass=empty
  fixtures
  DOCKER_PRUNE_KEEP_LABELS=' '
  DOCKER_PRUNE_KEEP_IMAGES=''
  out=$(prune_docker)
  grep -q 'docker system prune -af --filter until=0s' <<<"$out" || fail "$backend/$pass: not a plain system prune"
  image_gone by-label-a:1
  image_gone variscite:20.04
  if has_container kept; then fail "$backend/$pass: container survived with no keep settings"; fi
}

# The image store fresh installs get, and the one upgraded hosts stay on.
start_daemon "pruner-test-containerd-$$"
check_store containerd
outer rm -f "pruner-test-containerd-$$" >/dev/null

start_daemon "pruner-test-overlay2-$$" --storage-driver=overlay2 --feature containerd-snapshotter=false
check_store overlay2

finish "docker prune keeps labelled and matching images and containers, on both image stores"
