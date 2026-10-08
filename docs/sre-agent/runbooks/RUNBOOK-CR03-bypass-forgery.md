# RUNBOOK — CR-03 negative proof: a forged bypass must be REFUSED

**Quick task:** 260812-oje
**Closes:** WINDOWS.md #6 (open, unrun-verify) · 05-UAT.md Test 2
**Repo:** `jbaker48/k8s-cluster`
**Estimated time:** ~10 minutes, mostly waiting on one workflow run
**Run this manually.** Nothing in this runbook is automated, and nothing in it merges anything.

---

## Dispatch mechanics — which tests need a merge to `main` (read first)

**You are here: CR-03 negative. It needs NO merge.**

The single question that governs all four harnesses is *where does GitHub read the
workflow definition from?* The answer differs per trigger, and it decides whether a
test can run from an unmerged branch.

| Test | Merge to `main` needed? | Why |
|---|---|---|
| **CR-01** empty-Flux-list assertion | **No** | `test-health-gate-rbac.yaml` is **already on `main`**, which is what registers its `workflow_dispatch` trigger. Once registered, dispatching against a ref runs **that ref's** version of the file — so your modified copy on the branch is what executes. |
| **CR-03 negative** (this runbook) | **No** | `exclusion-gate.yaml` fires on `pull_request_target`, which **always** evaluates the workflow definition from the **base** branch (`main`) — never from the PR's head. Commit `21c299d1` is already on `main`, so a throwaway PR from any branch exercises the fixed code. |
| **CR-03 positive** (`cr03-bypass-positive-proof.sh`) | **No** | Same `pull_request_target` reasoning. The proof is a local script driving the REST API, so there is no workflow file to install at all. |
| **CR-02** circuit breaker | **Yes — PR A only** | Not a workflow-definition issue. `exclusion-gate.yaml:144` reads `circuit-breaker-state.json` **at `github.event.pull_request.base.sha`**, so the paused state must already be a committed blob on `main` before the test PR is opened. Merging PR A *is* the test setup. |

### Dispatching CR-01

The branch must be pushed first — `--ref` names a ref that has to exist on the remote:

```bash
git push -u origin chore/phase-05-validation-harnesses
gh workflow run test-health-gate-rbac.yaml --ref chore/phase-05-validation-harnesses
gh run list --repo jbaker48/k8s-cluster --workflow test-health-gate-rbac.yaml --limit 3
```

> Pushing the branch is not merging it. Nothing reaches `main`.
>
> If `gh workflow run` reports it cannot find the workflow, fall back to the REST
> dispatch endpoint, which takes the same ref:
>
> ```bash
> gh api --method POST \
>   repos/jbaker48/k8s-cluster/actions/workflows/test-health-gate-rbac.yaml/dispatches \
>   -f ref=chore/phase-05-validation-harnesses
> ```

> ### TRAP — dispatching against `main` silently proves nothing
>
> The `--ref` is not a formality. Because the dispatched run executes **that ref's**
> copy of the workflow, and the CR-01 step exists **only on the feature branch**,
> dispatching against `main` runs the *old* five-step version. It will very likely go
> green — and that green means nothing about CR-01.
>
> **This already happened once:** run
> [31583783942](https://github.com/jbaker48/k8s-cluster/actions/runs/31583783942) was
> dispatched at 2026-08-12T09:37:50Z against `main` (sha `767a4871`), whose workflow
> has no CR-01 step. Disregard that run for CR-01 purposes.
>
> **How to confirm you ran the right version** — check the step list, not the colour:
>
> ```bash
> gh run view <run-id> --repo jbaker48/k8s-cluster \
>   --json headBranch,jobs --jq '{ref: .headBranch, steps: [.jobs[].steps[].name]}'
> ```
>
> | You ran | Steps | Verdict |
> |---|---|---|
> | `main` | 5 steps, none mentioning CR-01 | wrong version — no CR-01 verdict |
> | `chore/phase-05-validation-harnesses` | 6 steps, last is `CR-01 regression assertion - genuinely empty Flux list must never classify as healthy` | correct version |
>
> Note also that this workflow runs on the self-hosted `k8s-cluster-ci` ARC runner, so
> a run can legitimately sit in `queued` for a while until a runner scales up. Queued
> is not failed (see WINDOWS.md #1 for a prior episode where an outage stranded runs
> in `queued` indefinitely).

> **Why the original positive-proof workflow was deleted.** A `workflow_dispatch`
> trigger only becomes available once the workflow file exists on the **default
> branch**. A brand-new test workflow on a feature branch is therefore undispatchable
> — it would have had to be merged into `main` first, which is an unacceptable price
> for a throwaway test. `cr03-bypass-positive-proof.sh` sidesteps this entirely.

### Run order

**CR-01 → CR-03 negative → CR-03 positive → CR-02.**

The first three are free: no merge, no change to `main`, fully reversible by closing a
PR. **CR-02 is last because it is the only one that writes to `main`** and opens a
blast-radius window affecting other PRs. Get every no-cost verdict in hand before
taking on the one with a cost.

---

## 1. What is being proven

`.github/workflows/exclusion-gate.yaml` lines 46–52 decide whether a PR gets the
`automated-revert` bypass, which skips **all** exclusion and AI-review evaluation:

```bash
if [[ "$HEAD_REF" == auto-revert/* ]] \
   && [[ "$HAS_LABEL" == "true" ]] \
   && [[ "$HEAD_REPO" == "$BASE_REPO" ]] \
   && [[ "$PR_AUTHOR_TYPE" == "Bot" ]] \
   && [[ "$PR_AUTHOR_LOGIN" == "k8s-cluster-revert-bot[bot]" ]]; then
  IS_BYPASS="true"
fi
```

The first three conditions are **forgeable by any collaborator with ordinary push and
label rights**: anyone can name a branch `auto-revert/anything` and self-apply the
`automated-revert` label. Before commit `21c299d1` those three were the *entire* check,
so that forgery bought a total bypass of the cluster-critical path gate — including
Talos and Cilium (05-REVIEW.md **CR-03**). `21c299d1` added the last two conditions.

**This runbook proves the negative half of CR-03:** a PR with the right branch prefix,
the right label, and same-repo origin, but authored by a **human**, must NOT bypass.

> The **positive** half — that a genuine `k8s-cluster-revert-bot[bot]` revert still
> *does* bypass — is proven separately by the local script
> `cr03-bypass-positive-proof.sh` in this same directory. Run that one first; it is
> the higher-risk check, since a false-negative there silently disables auto-revert.

---

## 2. Read this before you touch anything

> ### WARNING — your working tree has an unrelated dirty file
>
> `kubernetes/bootstrap/talos/talconfig.yaml` currently has an **uncommitted local
> change** (it removes a `nodeTaints: dedicated: "frigate:NoSchedule"` block). It has
> nothing to do with this test.
>
> **Do NOT** create the test branch by committing that local file, and **do NOT**
> `git checkout` / `git stash` / `git restore` it to get out of the way. Every step
> below is written so the dirty file is never touched. Step 4 uses a disposable
> `git worktree` precisely because a plain `git checkout` of another branch would be
> refused (or would drag the dirty file along).

> ### This PR must NEVER be merged
>
> It deliberately attempts a privilege escalation against your own gate. Close it
> without merging (step 6).

---

## 3. Create the forgery branch and PR — without touching your local dirty file

The branch must be `auto-revert/`-prefixed (to satisfy the forgeable branch condition)
and must touch a **cluster-critical excluded path** so that a bypass failure is
unmistakable.

**Path choice:** `kubernetes/bootstrap/talos/talconfig.yaml` matches **both** the
`talos` (`kubernetes/bootstrap/talos/**`) and `kubernetes-core`
(`kubernetes/bootstrap/**`) categories in `.github/exclusion-gate.yaml`. Two independent
reasons means the expected gate comment is unambiguous.

### Option A (recommended) — create the branch server-side via `gh api`

Never involves your local checkout at all, so the dirty file cannot leak in.

```bash
# 1. Branch off current main, server-side.
MAIN_SHA=$(gh api repos/jbaker48/k8s-cluster/git/ref/heads/main --jq '.object.sha')
gh api --method POST repos/jbaker48/k8s-cluster/git/refs \
  -f ref='refs/heads/auto-revert/forgery-test' \
  -f sha="$MAIN_SHA"

# 2. Fetch talconfig.yaml AS IT EXISTS ON main (not your dirty local copy),
#    append a comment line, and PUT it back on the test branch only.
gh api "repos/jbaker48/k8s-cluster/contents/kubernetes/bootstrap/talos/talconfig.yaml?ref=main" \
  --jq '.content' | base64 -d > /tmp/forgery-talconfig.yaml
FILE_SHA=$(gh api "repos/jbaker48/k8s-cluster/contents/kubernetes/bootstrap/talos/talconfig.yaml?ref=main" --jq '.sha')
printf '\n# CR-03 forgery test marker - do not merge (quick task 260812-oje)\n' \
  >> /tmp/forgery-talconfig.yaml

gh api --method PUT \
  repos/jbaker48/k8s-cluster/contents/kubernetes/bootstrap/talos/talconfig.yaml \
  -f message='test: CR-03 forgery marker (do not merge)' \
  -f branch='auto-revert/forgery-test' \
  -f sha="$FILE_SHA" \
  -f content="$(base64 -i /tmp/forgery-talconfig.yaml | tr -d '\n')"
```

### Option A′ — zero talconfig.yaml exposure

If you would rather not put `talconfig.yaml` in a PR diff at all, add a throwaway
**new** file under the same directory instead. It matches the same two categories, and
needs no `sha` (it is a create, not an update):

```bash
gh api --method PUT \
  repos/jbaker48/k8s-cluster/contents/kubernetes/bootstrap/talos/FORGERY-TEST-MARKER.md \
  -f message='test: CR-03 forgery marker (do not merge)' \
  -f branch='auto-revert/forgery-test' \
  -f content="$(printf 'CR-03 forgery test marker - do not merge (quick task 260812-oje).\n' | base64 | tr -d '\n')"
```

A `.md` file here is inert: `talhelper` reads only `talconfig.yaml` / `talenv.yaml` /
`talsecret*`, and `kubernetes/bootstrap/` sits outside Flux's reconciled tree.

### Option B — GitHub web editor

Browse to the file on GitHub, click edit, add the comment line, and choose
**"Create a new branch for this commit"**, naming it exactly
`auto-revert/forgery-test`. Equivalent to Option A and equally safe.

### Then open the PR — as yourself

```bash
gh pr create --repo jbaker48/k8s-cluster \
  --base main --head auto-revert/forgery-test \
  --title 'TEST ARTIFACT - DO NOT MERGE: CR-03 forged bypass attempt' \
  --body 'Forged bypass attempt (quick task 260812-oje). Right branch prefix, right label, same-repo origin, but authored by a HUMAN. The exclusion gate MUST refuse the bypass. DO NOT MERGE - close when verified.'
```

**Authoring this PR as yourself is the forgery.** Do not use any bot token here.

---

## 4. THE GOTCHA — label first, then force a `synchronize`

> `exclusion-gate.yaml`'s trigger is a bare `pull_request_target:` (with
> `branches: ["main"]`). A bare trigger means GitHub's **default activity types**:
> `opened`, `reopened`, `synchronize`. **`labeled` is NOT among them.**
>
> Therefore **applying the label does not retrigger the workflow.** The run that fired
> on `opened` evaluated `HAS_LABEL` as `false` and is worthless as a forgery test —
> it would have declined the bypass for the *wrong reason*.

Order is mandatory: **apply the label first, then push an empty commit** to fire
`synchronize` so the gate re-evaluates with the label present.

```bash
# 4a. Apply the forged label (self-applied, as your human identity — that IS the forgery).
gh pr edit --repo jbaker48/k8s-cluster auto-revert/forgery-test \
  --add-label automated-revert

# 4b. Retrigger via synchronize, using a DISPOSABLE WORKTREE so your dirty
#     talconfig.yaml is never checked out, stashed, or restored.
git fetch origin auto-revert/forgery-test
git worktree add /tmp/forgery-test auto-revert/forgery-test
git -C /tmp/forgery-test commit --allow-empty -m "chore: retrigger exclusion-gate"
git -C /tmp/forgery-test push origin auto-revert/forgery-test
git worktree remove /tmp/forgery-test
```

Confirm your local tree is untouched — this must still show `talconfig.yaml` as
modified and unstaged:

```bash
git status --short   # expect exactly:  M kubernetes/bootstrap/talos/talconfig.yaml
```

---

## 5. Read the verdict

Watch the run that fired on the **empty commit** (the `synchronize` event), not the
original `opened` run:

```bash
gh pr checks --repo jbaker48/k8s-cluster auto-revert/forgery-test
gh run list --repo jbaker48/k8s-cluster --workflow "Exclusion Gate" --limit 3
```

### PASS — the bypass was REFUSED (CR-03's fix holds)

- The PR carries a comment beginning **"Human merge required"** — specifically
  *"this PR touches cluster-critical infrastructure"* — listing **two** reasons: the
  `talos` node-OS reason and the `kubernetes-core` cluster-wide GitOps reason.
- The **`gate/human-required`** label is applied.
- The bypass comment **"Automated health-gate revert recognized"** is **absent**.

### FAIL — regression, the forgery succeeded

- The comment **"Automated health-gate revert recognized"** appears, and
- no `gate/human-required` label is applied, and
- no exclusion comment appears.

A FAIL means any collaborator can bypass the cluster-critical path gate at will.
Stop and fix before Phase 6 (auto-merge go-live).

### Second, trigger-independent discriminator (use this to be certain)

Comments can be confusing to read across two runs. Open the `synchronize` run's job and
check **step execution status** instead. Every step below is conditioned on
`steps.bypass.outputs.is_bypass != 'true'`, so:

| Post-bypass step | If bypass REFUSED (pass) | If bypass TAKEN (fail) |
|---|---|---|
| Fetch exclusion config from base branch | **executed** | skipped |
| Build paths-filter map | **executed** | skipped |
| Evaluate path filters | **executed** | skipped |
| Compute excluded flag and reasons | **executed** | skipped |
| Fetch circuit-breaker state from base branch | **executed** | skipped |
| Resolve touched app buckets | **executed** | skipped |
| Evaluate circuit-breaker pause state | **executed** | skipped |

**If those steps show as skipped, the bypass was taken — that is a FAIL**, regardless of
what any comment says.

---

## 6. Cleanup (mandatory)

```bash
# Close WITHOUT merging. This PR must never be merged.
gh pr close --repo jbaker48/k8s-cluster auto-revert/forgery-test --delete-branch

# Verify it is gone and was NOT merged.
gh pr view --repo jbaker48/k8s-cluster auto-revert/forgery-test --json state,mergedAt

# Confirm your local dirty file survived the whole exercise untouched.
git status --short   # expect exactly:  M kubernetes/bootstrap/talos/talconfig.yaml
```

Also remove `/tmp/forgery-talconfig.yaml` if you used Option A.

---

## 7. Record the outcome

- `.planning/phases/05-post-merge-health-gate-auto-revert/05-UAT.md` → **Test 2**
  (note the PR number, the run URL, and which discriminator you used).
- `.planning/WINDOWS.md` → entry **#6**. Mark it resolved only once **both** CR-03
  halves are proven: this negative test **and** the positive test from
  `cr03-bypass-positive-proof.sh`.
