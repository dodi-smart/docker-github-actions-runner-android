#!/bin/bash
# Preflight wrapper around the upstream myoung34 entrypoint.
#
# When CONFIGURED_ACTIONS_RUNNER_FILES_DIR is set, the upstream entrypoint
# copies the persisted config into /actions-runner and skips registration
# whenever a .runner file exists — with no validation of the stored
# credentials and no fallback to ACCESS_TOKEN. If the runner was meanwhile
# removed server-side (pruned by GitHub after being offline too long, deleted
# manually, etc), the stored credentials are dead and the container
# crash-loops forever without ever re-registering, even though a perfectly
# good ACCESS_TOKEN is sitting in the environment.
#
# This preflight asks GitHub whether the persisted runner still exists. Only
# a definitive 404 wipes the persisted registration, which makes the upstream
# entrypoint fall through to a fresh ACCESS_TOKEN registration (and store the
# new credentials back into the persist dir). Transient errors, missing
# variables, or unparseable state leave everything untouched, so behavior is
# never worse than upstream's.
#
# Intentionally not using set -e: preflight must never block runner startup.

log() { echo "[preflight] $*"; }

preflight() {
  local dir="${CONFIGURED_ACTIONS_RUNNER_FILES_DIR:-}"
  [ -n "$dir" ] || return 0
  [ -f "$dir/.runner" ] || return 0
  if [ -z "${ACCESS_TOKEN:-}" ]; then
    log "ACCESS_TOKEN not set; cannot validate persisted registration, leaving as-is"
    return 0
  fi

  # .runner is JSON written by the runner itself; it may carry a UTF-8 BOM.
  local agent_id
  agent_id=$(sed '1s/^\xEF\xBB\xBF//' "$dir/.runner" | jq -r '.agentId // empty' 2>/dev/null)
  if [ -z "$agent_id" ]; then
    log "could not read agentId from $dir/.runner; leaving as-is"
    return 0
  fi

  local github_host="${GITHUB_HOST:-github.com}"
  local api_base
  if [ "$github_host" = "github.com" ]; then
    api_base="https://api.github.com"
  else
    api_base="https://${github_host}/api/v3"
  fi

  local api_path
  case "${RUNNER_SCOPE:-repo}" in
    org)
      if [ -z "${ORG_NAME:-}" ]; then
        log "RUNNER_SCOPE=org but ORG_NAME unset; leaving as-is"
        return 0
      fi
      api_path="orgs/${ORG_NAME}/actions/runners/${agent_id}"
      ;;
    ent*)
      log "enterprise scope validation not implemented; leaving as-is"
      return 0
      ;;
    *)
      # repo scope: REPO_URL looks like https://<host>/<owner>/<repo>
      local repo_path="${REPO_URL#*://*/}"
      if [ -z "$repo_path" ] || [ "$repo_path" = "${REPO_URL:-}" ]; then
        log "cannot parse REPO_URL; leaving as-is"
        return 0
      fi
      api_path="repos/${repo_path}/actions/runners/${agent_id}"
      ;;
  esac

  # Bounded timeouts so a DNS/TLS/network stall can't block runner startup;
  # a timeout falls into the default case below and leaves the config as-is.
  local status
  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 15 \
    -H "Authorization: token ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${api_base}/${api_path}" 2>/dev/null)

  case "$status" in
    200)
      log "persisted runner agentId=${agent_id} still registered; reusing stored credentials"
      ;;
    404)
      log "persisted runner agentId=${agent_id} no longer exists on ${github_host};" \
        "wiping persisted registration to force fresh ACCESS_TOKEN registration"
      rm -f "$dir/.runner" "$dir/.credentials" "$dir/.credentials_rsaparams"
      ;;
    *)
      log "could not validate persisted runner (HTTP ${status:-none}); leaving as-is"
      ;;
  esac
}

preflight
exec /entrypoint.sh "$@"
