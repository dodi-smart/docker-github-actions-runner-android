#!/bin/bash
# Suggest .env settings for this host. Read-only: it inspects the machine and
# prints a snippet to paste into .env next to docker-compose.yml.
#
#   hosts/sizing.sh [light|large]
#
# Profile = what one runner should get:
#   light  1 CPU, 3 GiB   checks, lint, Next.js/bun builds (default)
#   large  2 CPU, 6 GiB   Gradle/Android and other heavy builds
# Override with RUNNER_CPUS / RUNNER_MEM_GIB. The host keeps HOST_RESERVE_GIB
# (default 2) of memory for itself and the docker daemon.
#
# Linux only (reads /proc and uses GNU df). Run it on the host, not in a
# runner container.
set -euo pipefail

profile="${1:-light}"
case "$profile" in
  light) cpus="${RUNNER_CPUS:-1}" mem="${RUNNER_MEM_GIB:-3}" ;;
  large) cpus="${RUNNER_CPUS:-2}" mem="${RUNNER_MEM_GIB:-6}" ;;
  *) echo "usage: $0 [light|large]" >&2; exit 2 ;;
esac
reserve="${HOST_RESERVE_GIB:-2}"
data_dir="${RUNNER_DATA_DIR:-/var/lib/github-runner}"

nproc=$(nproc)
mem_gib=$(awk '/^MemTotal:/ {printf "%d", $2 / 1048576}' /proc/meminfo)

# Size the disk that will hold the data dir (its nearest existing parent).
probe="$data_dir"
while [ ! -e "$probe" ]; do probe=$(dirname "$probe"); done
read -r disk_bytes avail_bytes < <(df -B1 --output=size,avail "$probe" | awk 'NR==2 {print $1, $2}')

by_cpu=$((nproc / cpus))
by_mem=$(((mem_gib - reserve) / mem))
runners=$((by_cpu < by_mem ? by_cpu : by_mem))
[ "$runners" -ge 1 ] || runners=1

# The pruner's own budget (CACHE_BUDGET_BYTES / CACHE_BUDGET_PCT, honoring
# them when set), sized against this disk. Printed so the per-runner share is
# visible. pruner.sh only defines functions when sourced.
# shellcheck source=SCRIPTDIR/../pruner.sh
source "$(dirname "$0")/../pruner.sh"
budget=$(RUNNER_DATA_DIR="$probe" slot_budget 1)
gib() { awk -v b="$1" 'BEGIN {printf "%.1f", b / 1073741824}'; }

arch=$(uname -m)
kvm=no
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then kvm=yes; fi
docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)

cat <<EOF
# host: $(hostname) ($arch)  cpus=$nproc  mem=${mem_gib}GiB  docker=$docker_version  kvm=$kvm
# data disk ($probe): $(gib "$disk_bytes") GiB, $(gib "$avail_bytes") GiB free
# profile $profile: ${cpus} CPU / ${mem} GiB per runner -> by cpu $by_cpu, by memory $by_mem
RUNNERS=$runners
RUNNER_DATA_DIR=$data_dir
# Per-runner limits keep one job from starving the others; the preflight then
# caps Gradle/cargo/make/cmake workers to RUNNER_CPUS.
RUNNER_CPUS=$cpus
RUNNER_MEMORY=${mem}g
# cache budget: $(gib "$budget") GiB for the host, ~$(gib $((budget / runners))) GiB per slot
EOF
case "$arch" in
  aarch64|arm64)
    echo "# arm64: the Android SDK's build tools are x86_64-only, so use the slim image"
    echo "RUNNER_IMAGE=ghcr.io/dodi-smart/github-runner:slim" ;;
esac
if [ "$runners" -eq 1 ] && [ "$budget" -lt $((10 * 1024 * 1024 * 1024)) ]; then
  echo "# little disk: consider RUNNER_CACHES=off"
fi
