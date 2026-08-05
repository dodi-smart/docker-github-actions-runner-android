# PR Build Testing + Auto-Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every PR gets a full test build of the container (all JDK variants, no push); dependency PRs from renovate[bot] and the weekly SDK/JDK workflow auto-merge when the build passes.

**Architecture:** A new `build.yml` workflow mirrors deploy.yml's matrix but builds with `push: false`, ending in a single stable gate check named "All builds passed". A branch ruleset on `main` requires that check, which activates Renovate's existing `platformAutomerge`. The SDK/JDK update workflow switches to a fine-grained PAT (so its PRs trigger workflows) and enables GitHub auto-merge on its PRs.

**Tech Stack:** GitHub Actions, docker/build-push-action, gh CLI, GitHub branch rulesets API.

**Spec:** `docs/superpowers/specs/2026-08-04-pr-build-automerge-design.md`

## Global Constraints

- Action versions must match deploy.yml exactly: `actions/checkout@v6`, `docker/setup-buildx-action@v4`, `docker/build-push-action@v7`.
- The gate job's `name:` must be exactly `All builds passed` — the ruleset matches on this string.
- The PAT secret name is exactly `AUTOMERGE_PAT`.
- deploy.yml and renovate.json must not be modified.
- Work happens on branch `feat/pr-build-automerge`. NEVER push to main; the user merges the PR themselves.
- Repo: `compscidr/docker-github-actions-runner-android` (verify with `gh repo view`).

---

### Task 1: Create the PR build workflow

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `matrix.json` (keys `java_versions`, `default_jdk`), Dockerfile ARGs `VERSION`, `JAVA_VERSION`.
- Produces: a check run named `All builds passed` on every PR head SHA (Task 4's ruleset and Task 2's auto-merge depend on this exact name).

- [ ] **Step 1: Write the workflow file**

Create `.github/workflows/build.yml` with exactly this content:

```yaml
name: Build container (PR)
on:
  pull_request:

concurrency:
  group: build-pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  matrix:
    name: Generate build matrix
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.generate.outputs.matrix }}
    steps:
      - uses: actions/checkout@v6

      - name: Generate matrix from matrix.json
        id: generate
        run: |
          DEFAULT_JDK=$(jq -r '.default_jdk' matrix.json)
          MATRIX=$(jq -c --arg default "$DEFAULT_JDK" '{
            "include": [.java_versions[] | {
              "java_version": .,
              "is_default_jdk": (. == $default)
            }]
          }' matrix.json)
          echo "matrix=${MATRIX}" >> $GITHUB_OUTPUT

  build:
    name: Build JDK ${{ matrix.java_version }}
    needs: matrix
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix: ${{ fromJson(needs.matrix.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v6

      - name: Extract versions from Dockerfile
        id: versions
        run: |
          set -euo pipefail
          RUNNER_TAG=$(grep -m1 '^ARG VERSION=' Dockerfile | cut -d= -f2)

          if [ -z "$RUNNER_TAG" ]; then
            echo "::error::Failed to extract versions from Dockerfile"
            exit 1
          fi

          echo "runner_tag=${RUNNER_TAG}" >> $GITHUB_OUTPUT

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v4

      - name: Build (no push)
        uses: docker/build-push-action@v7
        with:
          context: .
          push: false
          build-args: |
            VERSION=${{ steps.versions.outputs.runner_tag }}
            JAVA_VERSION=${{ matrix.java_version }}

  gate:
    name: All builds passed
    needs: [matrix, build]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Check that all required jobs succeeded
        run: |
          if [ "${{ needs.matrix.result }}" != "success" ] || [ "${{ needs.build.result }}" != "success" ]; then
            echo "::error::A required job failed or was cancelled (matrix: ${{ needs.matrix.result }}, build: ${{ needs.build.result }})"
            exit 1
          fi
          echo "All builds succeeded"
```

Notes on intent (do not deviate):
- No registry logins, no metadata action, no tags — this only proves the image builds.
- `if: always()` on the gate plus explicit result checks means cancelled/skipped builds fail the gate; a cancelled run can never satisfy the ruleset.
- Concurrency key uses the PR number so a force-push cancels the superseded run.

- [ ] **Step 2: Validate the workflow syntax**

Run:
```bash
docker run --rm -v /home/jason/dev/docker-github-actions-runner-android:/repo -w /repo rhysd/actionlint:latest -color
```
Expected: no output for build.yml (exit 0). If docker/actionlint is unavailable, fall back to:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml'))" && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "Add PR build workflow with 'All builds passed' gate check

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Switch check-sdk-updates.yml to the PAT and enable auto-merge

**Files:**
- Modify: `.github/workflows/check-sdk-updates.yml` (checkout step ~line 17, "Create pull request" step ~lines 177-238)

**Interfaces:**
- Consumes: repo secret `AUTOMERGE_PAT` (fine-grained PAT, contents: write + pull-requests: write; created by the user in Task 5).
- Produces: SDK/JDK PRs whose creation triggers build.yml and which have GitHub auto-merge enabled.

- [ ] **Step 1: Add a fail-loudly guard as the first step of the job**

In `.github/workflows/check-sdk-updates.yml`, insert this as the FIRST step of the `check-updates` job, BEFORE `- uses: actions/checkout@v6` (before checkout so a missing secret fails with this clear message instead of a confusing checkout auth error):

```yaml
      - name: Verify AUTOMERGE_PAT is configured
        env:
          AUTOMERGE_PAT: ${{ secrets.AUTOMERGE_PAT }}
        run: |
          if [ -z "$AUTOMERGE_PAT" ]; then
            echo "::error::AUTOMERGE_PAT secret is not configured. Create a fine-grained PAT scoped to this repo with contents:write and pull-requests:write, and save it as a repository secret named AUTOMERGE_PAT. PRs created with the default GITHUB_TOKEN never trigger the build workflow, so they could never auto-merge."
            exit 1
          fi
```

- [ ] **Step 2: Make checkout (and therefore git push) use the PAT**

Change:
```yaml
      - uses: actions/checkout@v6
```
to:
```yaml
      - uses: actions/checkout@v6
        with:
          token: ${{ secrets.AUTOMERGE_PAT }}
```
(Only the checkout step inside check-sdk-updates.yml — no other workflow.)

- [ ] **Step 3: Make gh use the PAT and enable auto-merge**

In the "Create pull request" step, change the env from:
```yaml
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```
to:
```yaml
        env:
          GH_TOKEN: ${{ secrets.AUTOMERGE_PAT }}
```

Then, at the end of that step's `run:` block (after the `if [ -z "$EXISTING" ] ... fi` create-or-update logic), append:

```bash
          # Enable auto-merge so the PR merges once "All builds passed" succeeds.
          # Runs for both new and force-updated existing PRs; idempotent.
          gh pr merge --auto --merge "$BRANCH"
```

- [ ] **Step 4: Validate the workflow syntax**

Run:
```bash
docker run --rm -v /home/jason/dev/docker-github-actions-runner-android:/repo -w /repo rhysd/actionlint:latest -color
```
Expected: exit 0, no findings for check-sdk-updates.yml. Fallback if unavailable:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/check-sdk-updates.yml'))" && echo OK
```
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/check-sdk-updates.yml
git commit -m "Use AUTOMERGE_PAT in SDK update workflow and enable auto-merge

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Push branch, open PR, verify the build check reports

**Files:** none (git/GitHub operations only)

**Interfaces:**
- Consumes: branch `feat/pr-build-automerge` with Tasks 1-2 committed (plus the already-committed spec and this plan).
- Produces: an open PR whose head SHA has a green `All builds passed` check (Task 4 must not run until this is verified).

- [ ] **Step 1: Verify branch and push**

```bash
git branch --show-current
```
Expected: `feat/pr-build-automerge`. Then:
```bash
git push -u origin feat/pr-build-automerge
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "Add PR build testing and auto-merge for dependency PRs" --body "## Summary
- New \`build.yml\` workflow: builds all JDK variants from matrix.json on every PR (\`push: false\`), gated by a single stable check named **All builds passed**
- \`check-sdk-updates.yml\` now uses the \`AUTOMERGE_PAT\` secret (default \`GITHUB_TOKEN\` PRs never trigger workflows) and enables auto-merge on its PRs
- Design: \`docs/superpowers/specs/2026-08-04-pr-build-automerge-design.md\`

## Follow-up (manual, after this merges)
- A branch ruleset on \`main\` requires **All builds passed** (created via API as part of this work)
- @compscidr must create a fine-grained PAT (this repo only; contents: write, pull-requests: write) and save it as repo secret \`AUTOMERGE_PAT\`

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 3: Confirm build.yml triggered on the PR**

```bash
gh pr checks feat/pr-build-automerge
```
Expected: pending/running checks including `Build JDK 17` ... `Build JDK 26` and `All builds passed`. If no checks appear within ~2 minutes, investigate (`gh run list --workflow=build.yml`) before proceeding.

- [ ] **Step 4: Wait for the full matrix to finish and the gate to pass**

Poll until done (builds are heavyweight — expect 30-60+ minutes; poll every ~5 minutes, do not busy-wait):
```bash
gh pr checks feat/pr-build-automerge
```
Expected final state: `All builds passed` = pass. If any JDK build fails, STOP: debug the workflow (this is exactly what the gate exists to catch), fix, commit, push, and re-verify. Do not proceed to Task 4 with a red gate.

---

### Task 4: Create the branch ruleset on main

**Files:** none (GitHub API operation)

**Interfaces:**
- Consumes: a green `All builds passed` check on the open PR (Task 3).
- Produces: active branch ruleset on `main` requiring status check `All builds passed`, with repository-admin bypass.

- [ ] **Step 1: Create the ruleset**

`actor_id: 5` is the built-in Repository Admin role; `integration_id: 15368` is the GitHub Actions app, ensuring only Actions can satisfy the check. `strict_required_status_checks_policy: false` deliberately does NOT require branches to be up to date with main — strict mode would stall auto-merge behind constant rebases.

```bash
gh api repos/compscidr/docker-github-actions-runner-android/rulesets -X POST --input - <<'EOF'
{
  "name": "main-requires-build",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] }
  },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "All builds passed", "integration_id": 15368 }
        ]
      }
    }
  ]
}
EOF
```
Expected: JSON response containing `"enforcement": "active"` and an `id`.

- [ ] **Step 2: Verify the ruleset applies to main**

```bash
gh api repos/compscidr/docker-github-actions-runner-android/rules/branches/main
```
Expected: array containing a `required_status_checks` rule whose contexts include `All builds passed`.

- [ ] **Step 3: Verify the open PR is still mergeable via auto-merge path**

```bash
gh pr view feat/pr-build-automerge --json mergeStateStatus,statusCheckRollup --jq '{state: .mergeStateStatus, gate: [.statusCheckRollup[] | select(.name == "All builds passed") | .conclusion]}'
```
Expected: gate contains `SUCCESS`; state is `CLEAN` (or `UNSTABLE`/`BLOCKED` only if unrelated checks are still running — the green gate is what matters).

---

### Task 5: User actions and end-to-end verification

**Files:** none

**Interfaces:**
- Consumes: merged PR from Task 3, ruleset from Task 4.
- Produces: verified hands-off dependency-update pipeline.

- [ ] **Step 1: Ask the user to create the PAT and secret (blocked on user)**

Tell the user exactly this — the executor cannot do it:
1. Create a fine-grained PAT at https://github.com/settings/personal-access-tokens/new — Resource owner: compscidr; Repository access: only `docker-github-actions-runner-android`; Permissions: Contents = Read and write, Pull requests = Read and write. Set a long expiry and note the renewal date.
2. Add it as a repository secret: `gh secret set AUTOMERGE_PAT` (paste the token when prompted), or via repo Settings → Secrets and variables → Actions.

- [ ] **Step 2: Ask the user to merge the PR**

The user merges `feat/pr-build-automerge` themselves (per their git rules). This is the last manual dependency-PR-era merge.

- [ ] **Step 3: End-to-end test of the SDK/JDK path (after Steps 1-2)**

```bash
gh workflow run check-sdk-updates.yml
```
Then watch:
```bash
gh run list --workflow=check-sdk-updates.yml --limit 1
```
- If no updates exist upstream, the run succeeds without creating a PR — the PAT guard passing is still a valid partial test.
- If a PR is created: confirm build.yml triggers on it (`gh pr checks automated/sdk-jdk-updates`), auto-merge is enabled (PR page shows "Auto-merge enabled"), and after the gate passes the PR merges and deploy.yml fires on main (`gh run list --workflow=deploy.yml --limit 1`).

- [ ] **Step 4: Confirm the Renovate path**

Nothing to configure (renovate.json already has `automerge: true` + `platformAutomerge: true`). On the next Renovate PR, confirm: build.yml runs, Renovate enables auto-merge, the PR merges on green, and deploy.yml fires. If Renovate does not enable auto-merge, check the Renovate dashboard issue for errors before changing any config.
