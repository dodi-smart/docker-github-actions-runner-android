# PR Build Testing + Auto-Merge for Dependency PRs

**Date:** 2026-08-04
**Status:** Approved

## Problem

Dependency PRs (Renovate base-image bumps and the weekly SDK/JDK update PRs)
receive no CI. The container is only built after merge, on push to `main`
(deploy.yml), so a broken update is discovered post-merge. Renovate is already
configured with `automerge: true` / `platformAutomerge: true`, but with no
required status checks on `main`, GitHub auto-merge is unavailable and every PR
is merged manually.

## Goal

Every PR gets a full test build of the container (all JDK variants, no push).
When the build passes, dependency PRs from both bots (renovate[bot] and the
SDK/JDK update workflow) merge automatically. A failed build leaves the PR open
and unmerged, and nothing deploys.

## Design

### 1. New workflow: `.github/workflows/build.yml`

- **Trigger:** `pull_request` (all PRs, no path filter — a required check must
  report on every PR or merges block forever).
- **Structure:** mirrors deploy.yml:
  - `matrix` job: generates the JDK matrix from `matrix.json` (same jq logic).
  - `build` job: per-JDK; extracts `VERSION` from the Dockerfile, sets up
    Buildx, runs `docker/build-push-action` with `push: false`, same
    `build-args` as deploy. No registry logins. (`COMPILE_SDK` is not
    extracted: deploy.yml only needs it to compose image tags, and the PR
    build produces no tags — the Docker build itself consumes `COMPILE_SDK`
    from the Dockerfile's ARG default, so a broken value still fails the
    build.)
  - `fail-fast: false` so every broken JDK variant is visible.
- **Concurrency:** group keyed on the PR ref with `cancel-in-progress: true`
  so superseded runs are cancelled.
- **Gate job:** a final job named **"All builds passed"** with `if: always()`
  and `needs: [matrix, build]` that fails unless every needed job succeeded.
  Matrix check names ("Build JDK 17", …) change as matrix.json evolves; the
  gate gives the ruleset one stable check name.

### 2. Branch ruleset on `main`

- Created via `gh api` (POST `/repos/{owner}/{repo}/rulesets`).
- Targets `main`; single rule: required status check **"All builds passed"**.
- Bypass: repository admin (so the owner can push to main in an emergency).
- Effect: GitHub auto-merge becomes available, so Renovate's existing
  `platformAutomerge: true` works with no config change. Renovate merges still
  trigger deploy.yml because renovate[bot] is a GitHub App, not the repo's
  `GITHUB_TOKEN`.

### 3. check-sdk-updates.yml changes (requires a PAT)

PRs created and pushes made with the default `GITHUB_TOKEN` never trigger other
workflows, so the build would never run on the SDK/JDK PRs and auto-merge would
hang; a GITHUB_TOKEN-enabled merge also wouldn't trigger deploy.yml.

- The owner creates a fine-grained PAT scoped to this repo with
  **contents: write** and **pull-requests: write**, saved as repo secret
  `AUTOMERGE_PAT`.
- The workflow uses `AUTOMERGE_PAT` for checkout/push and `gh` PR operations.
- After `gh pr create`, add `gh pr merge --auto --merge` so the PR merges once
  the required check passes.
- If the secret is missing, the workflow should fail loudly rather than
  silently creating a PR that can never auto-merge.

### 4. Unchanged

- deploy.yml (still builds and pushes on merge to main).
- renovate.json (automerge settings already correct).

## Error handling

- Any JDK build failure → gate check fails → PR stays open, unmerged; no
  deploy. Owner investigates manually.
- Gate job treats cancelled/skipped needed jobs as failure (`if: always()` +
  explicit result check) so a cancelled run can never satisfy the ruleset.

## Testing / verification

- The implementation PR itself triggers build.yml, self-validating the
  workflow before merge (merged manually one last time).
- After merge: run check-sdk-updates via `workflow_dispatch` (or wait for the
  next Renovate PR) and confirm the build runs, the PR auto-merges, and
  deploy.yml fires on the merge.

## Out of scope

- Docker layer caching for PR builds (repo GHA cache is far smaller than the
  Android SDK layers; revisit only if build times become a problem).
- Refactoring deploy.yml/build.yml to share the matrix job.
