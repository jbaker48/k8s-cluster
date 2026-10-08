# RUNBOOK — CR-02: prove the `unscoped` circuit-breaker bucket is actually enforced

**Quick task:** 260812-oje
**Closes:** WINDOWS.md #6 (open, unrun-verify) · 05-UAT.md Test 2
**Repo:** `jbaker48/k8s-cluster`
**Estimated time:** ~20 minutes, including two merges
**Run this LAST** of the four harnesses — it is the only one with a blast-radius window.
**Run this manually.** Nothing here is automated.

---

## Dispatch mechanics — which tests need a merge to `main` (read first)

**You are here: CR-02. This is the ONLY harness that requires a merge, and that merge
is inherent to the test rather than an installation step.**

The governing question for the other three harnesses is *where does GitHub read the
workflow definition from?* For CR-02 it is a different question entirely: *where does
the gate read its **state** from?*

| Test | Merge to `main` needed? | Why |
|---|---|---|
| **CR-01** empty-Flux-list assertion | **No** | `test-health-gate-rbac.yaml` is **already on `main`**, which is what registers its `workflow_dispatch` trigger. Once registered, dispatching against a ref runs **that ref's** version of the file — so the modified copy on the branch is what executes. |
| **CR-03 negative** (`RUNBOOK-CR03-bypass-forgery.md`) | **No** | `exclusion-gate.yaml` fires on `pull_request_target`, which **always** evaluates the workflow definition from the **base** branch (`main`) — never from the PR's head. Commit `21c299d1` is already on `main`, so a throwaway PR from any branch exercises the fixed code. |
| **CR-03 positive** (`cr03-bypass-positive-proof.sh`) | **No** | Same `pull_request_target` reasoning, and the proof is a local script driving the REST API — there is no workflow file to install. |
| **CR-02** (this runbook) | **Yes — PR A only** | `exclusion-gate.yaml:144` reads `circuit-breaker-state.json` **at `github.event.pull_request.base.sha`**. The paused state must therefore already be a committed blob on `main` before PR B is opened. **Merging PR A is the test setup, not a workaround** — see section 1. PR B is never merged, and PR C's merge only restores the original state. |

### Dispatching CR-01 (for reference, since you will likely have run it first)

The branch must be pushed first — `--ref` names a ref that has to exist on the remote:

```bash
git push -u origin chore/phase-05-validation-harnesses
gh workflow run test-health-gate-rbac.yaml --ref chore/phase-05-validation-harnesses
```

Pushing a branch is not merging it; nothing reaches `main`.

> **TRAP:** the `--ref` matters. A dispatch runs **that ref's** copy of the workflow,
> and the CR-01 step exists only on the feature branch — so dispatching against `main`
> runs the old five-step version and goes green without testing CR-01 at all. Run
> [31583783942](https://github.com/jbaker48/k8s-cluster/actions/runs/31583783942)
> (2026-08-12T09:37:50Z, against `main`) is exactly this case and should be disregarded.
> Confirm the correct version by its step list: 6 steps, the last named
> `CR-01 regression assertion - ...`. See `RUNBOOK-CR03-bypass-forgery.md` for details.

### Run order

**CR-01 → CR-03 negative → CR-03 positive → CR-02 (this one).**

The first three are free: no merge, no change to `main`, fully reversible by closing a
PR. **This runbook is last precisely because it is the only one that writes to `main`**
and opens a window that affects other open PRs. Collect every no-cost verdict first —
if CR-03 positive already failed, you have your Phase 6 blocker and may not want to
open this window at all today.

---

## 1. What is being proven

`.github/workflows/exclusion-gate.yaml` resolves which app "buckets" a PR touches, then
checks each against the circuit-breaker state. Before commit `21c299d1` the resolver
produced `[]` for any PR touching zero `kubernetes/apps/**` paths, so the pause loop at
lines 176–183 iterated **zero times** — a genuinely paused `unscoped` bucket was never
enforced for exactly the PRs it was meant to catch (05-REVIEW.md **CR-02**).

`21c299d1` added the fallback that mirrors `health-gate.yaml`'s own bucket resolution:

```bash
# exclusion-gate.yaml lines 163-165
if [ "${BUCKETS}" = "[]" ]; then
  BUCKETS='["unscoped"]'
fi
```

**This runbook proves that fallback is enforced end-to-end**, not just present in the file.

### Why three PRs and not one

`exclusion-gate.yaml` line 144 fetches the circuit-breaker state from the **base branch**:

```bash
gh api ".../contents/.github/health-gate/circuit-breaker-state.json?ref=${{ github.event.pull_request.base.sha }}"
```

The paused state must therefore **already be on `main`** before the test PR is opened. A
single PR that both pauses the breaker and tries to trip it cannot work — it would read
its own base (`{}`, unpaused) and pass. Hence: **PR A** pauses, **PR B** tests, **PR C**
resets.

---

## 2. Read this before you start

> ### WARNING — PR A opens a real blast-radius window on `main`
>
> While PR A's paused state sits on `main`, **every** PR touching zero
> `kubernetes/apps/**` paths that receives an `opened` / `reopened` / `synchronize` event
> gets the `gate/human-required` label plus a "circuit breaker paused" comment.
>
> **Keep the window as short as possible.** Do PR A → PR B → PR C back to back. Do not
> pause for lunch in the middle.
>
> **Actual blast radius, measured 2026-08-12** (30 open PRs, all Renovate). Only these 6
> resolve to the `unscoped` bucket:
>
> | PR | Files touched | Already labelled? |
> |---|---|---|
> | #1065 | `kubernetes/bootstrap/helmfile.yaml` | yes — matches `kubernetes-core` |
> | #1060 | `kubernetes/bootstrap/talos/talenv.yaml` | yes — matches `talos` + `kubernetes-core` |
> | #1054 | `kubernetes/bootstrap/talos/talconfig.yaml`, `talenv.yaml` | yes — matches `talos` + `kubernetes-core` |
> | #1046 | `kubernetes/bootstrap/talos/talconfig.yaml`, `talenv.yaml` | yes — matches `talos` + `kubernetes-core` |
> | #1043 | `.github/workflows/flux-diff.yaml` | **NO — this is the only one that would newly gain a label** |
> | #1041 | `kubernetes/bootstrap/helmfile.yaml` | yes — matches `kubernetes-core` |
>
> Two things shrink this further:
>
> 1. Five of the six **already** carry `gate/human-required` from the exclusion gate, so
>    the circuit breaker adds no new state to them. Only **#1043** is genuinely at risk of
>    a new label.
> 2. The exclusion gate's trigger is `pull_request_target` with default activity types
>    (`opened`, `reopened`, `synchronize`) — **not** a schedule. Those six PRs are not
>    re-evaluated at all unless Renovate pushes to one during your window.
>
> **Mandatory pre-flight** — re-measure, because Renovate may have opened new PRs since:
>
> ```bash
> gh pr list --repo jbaker48/k8s-cluster --state open --json number,title --jq '.[] | "#\(.number) \(.title)"'
>
> # For each open PR, show which resolve to the unscoped bucket (zero apps/ paths):
> for n in $(gh pr list --repo jbaker48/k8s-cluster --state open --json number --jq '.[].number'); do
>   B=$(gh api "repos/jbaker48/k8s-cluster/pulls/$n/files" --paginate --jq '.[].filename' \
>       | awk -F/ '$1=="kubernetes" && $2=="apps" && NF>=4 {print $3"/"$4}' | sort -u | wc -l | tr -d ' ')
>   [ "$B" = "0" ] && echo "unscoped: #$n"
> done
> ```
>
> Either wait for those to land, or accept the noise and re-check them after PR C.
>
> **Practical severity:** comment + label only. This repo has no branch protection and
> auto-merge is not live until Phase 6, so nothing is actually *blocked* from a human
> merge. But the noise is real and the labels must be cleaned up.

> ### Do not edit the state file on the harness branch
>
> `.github/health-gate/circuit-breaker-state.json` must stay `{}` on
> `chore/phase-05-validation-harnesses`. The JSON below is carried here as text for you
> to apply **inside PR A and PR C only**.

---

## 3. PR A — put a paused `unscoped` bucket on `main`

Set `.github/health-gate/circuit-breaker-state.json` to **exactly**:

```json
{"unscoped":{"reverts":[],"paused":true}}
```

This matches the schema `health-gate.yaml` itself writes (lines 432–438):
`{ <bucket>: { reverts: [ISO8601...], paused: bool } }`.

```bash
git fetch origin main
git worktree add /tmp/cb-pr-a origin/main -b chore/cb-pause-unscoped
printf '%s\n' '{"unscoped":{"reverts":[],"paused":true}}' \
  > /tmp/cb-pr-a/.github/health-gate/circuit-breaker-state.json
git -C /tmp/cb-pr-a add .github/health-gate/circuit-breaker-state.json
git -C /tmp/cb-pr-a commit -m "test: pause unscoped circuit breaker for CR-02 verification"
git -C /tmp/cb-pr-a push origin chore/cb-pause-unscoped
git worktree remove /tmp/cb-pr-a

gh pr create --repo jbaker48/k8s-cluster \
  --base main --head chore/cb-pause-unscoped \
  --title 'test: pause unscoped circuit breaker (CR-02 verification, PR A of 3)' \
  --body 'Temporary: pauses the unscoped bucket so CR-02 can be proven live. PR C resets it to {}. Merge this.'
```

> A disposable `git worktree` is used so your unrelated dirty
> `kubernetes/bootstrap/talos/talconfig.yaml` is never checked out, stashed, or restored.

**Then MERGE PR A.**

**Why PR A does not block itself:** it touches only `.github/**`, which matches none of
`talos` / `kubernetes-core` / `cilium`, so the exclusion gate passes it. And at PR A's own
`base.sha` the state file is still `{}`, so `.["unscoped"].paused // false` evaluates to
`false` — verified locally. PR A sails through; the pause only takes effect for PRs
*based on* the merge.

---

## 4. PR B — the actual test

PR B must touch a path that is **outside `kubernetes/apps/**` AND outside all three
exclusion categories**. That isolation is the whole point: if PR B also matched an
exclusion category, you could not tell a circuit-breaker label apart from an
exclusion label.

**`README.md` qualifies** — checked against `.github/exclusion-gate.yaml`'s globs
(`kubernetes/bootstrap/talos/**`, `kubernetes/bootstrap/**`, `kubernetes/flux/**`,
`kubernetes/components/**`, `kubernetes/templates/**`,
`kubernetes/apps/kube-system/cilium/**`, `kubernetes/flux/repositories/helm/cilium.yaml`):
it matches none of them, and it is not under `kubernetes/apps/`.

**Create PR B only AFTER PR A is merged**, so its `base.sha` includes the paused state.

```bash
git fetch origin main
git worktree add /tmp/cb-pr-b origin/main -b test/cb-unscoped-trip
printf '\n<!-- CR-02 circuit-breaker verification marker - do not merge -->\n' \
  >> /tmp/cb-pr-b/README.md
git -C /tmp/cb-pr-b add README.md
git -C /tmp/cb-pr-b commit -m "test: CR-02 circuit-breaker trip marker (do not merge)"
git -C /tmp/cb-pr-b push origin test/cb-unscoped-trip
git worktree remove /tmp/cb-pr-b

gh pr create --repo jbaker48/k8s-cluster \
  --base main --head test/cb-unscoped-trip \
  --title 'TEST ARTIFACT - DO NOT MERGE: CR-02 unscoped circuit-breaker trip' \
  --body 'Touches only README.md (zero kubernetes/apps/ paths, no exclusion category). Expect the circuit breaker to gate it via the unscoped bucket. DO NOT MERGE - close when verified.'
```

### Read the verdict

```bash
gh pr view --repo jbaker48/k8s-cluster test/cb-unscoped-trip --json labels,comments \
  --jq '{labels: [.labels[].name], comments: [.comments[].body]}'
```

#### PASS — CR-02's fix is enforced

- The `gate/human-required` label **is applied**.
- A comment beginning **"Human merge required"** — specifically *"circuit breaker paused
  for one or more app buckets this PR touches"* — is present, and its reasons list names
  the **`unscoped`** bucket:

  ```text
  - `unscoped`: 0 revert(s) recorded, paused pending human re-enable
  ```

  > **"0 revert(s)" is expected, not a bug.** The comment's count comes from
  > `.["unscoped"].reverts | length`, and PR A deliberately set `reverts` to `[]` — the
  > pause was applied by hand rather than accumulated from three real reverts. Verified
  > locally against the gate's exact jq. The `paused` flag is what is under test here,
  > not the counter.

- The **exclusion** comment ("*this PR touches cluster-critical infrastructure*") is
  **absent** — confirming the label came from the circuit breaker and nothing else.

#### FAIL — regression, CR-02 is not enforced

- No `gate/human-required` label, and
- no circuit-breaker comment.

That means the `["unscoped"]` fallback is not taking effect and a paused breaker can be
walked straight past by any non-app-path PR.

#### Step-level confirmation

In the Exclusion Gate run for PR B, open **"Resolve touched app buckets"** and confirm its
output is `buckets=["unscoped"]` (not `[]`). Then **"Evaluate circuit-breaker pause state"**
should set `paused=true`.

### Clean up PR B immediately

```bash
gh pr edit --repo jbaker48/k8s-cluster test/cb-unscoped-trip --remove-label gate/human-required
gh pr close --repo jbaker48/k8s-cluster test/cb-unscoped-trip --delete-branch
```

**Never merge PR B.**

---

## 5. PR C — reset the breaker (closes the window)

Set `.github/health-gate/circuit-breaker-state.json` back to **exactly**:

```json
{}
```

```bash
git fetch origin main
git worktree add /tmp/cb-pr-c origin/main -b chore/cb-reset-unscoped
printf '%s\n' '{}' > /tmp/cb-pr-c/.github/health-gate/circuit-breaker-state.json
git -C /tmp/cb-pr-c add .github/health-gate/circuit-breaker-state.json
git -C /tmp/cb-pr-c commit -m "chore: reset circuit-breaker state after CR-02 verification"
git -C /tmp/cb-pr-c push origin chore/cb-reset-unscoped
git worktree remove /tmp/cb-pr-c

gh pr create --repo jbaker48/k8s-cluster \
  --base main --head chore/cb-reset-unscoped \
  --title 'chore: reset circuit-breaker state after CR-02 verification (PR C of 3)' \
  --body 'Resets circuit-breaker-state.json to {} after CR-02 live verification. Expect this PR to be labelled gate/human-required by its own paused base state - that is correct behaviour. Merge it (human merge is exactly what the gate asks for), then remove the label.'
```

> ### Expected side effect on PR C — this is CORRECT, not a failure
>
> PR C touches only `.github/**` → zero `kubernetes/apps/**` paths → `unscoped` bucket.
> At PR C's `base.sha`, PR A's paused state is **still on `main`**. So **PR C will itself
> be labelled `gate/human-required` with a circuit-breaker comment.**
>
> That is the gate working as designed: it is asking for a human merge, and you are a
> human. **Merge it anyway**, then remove the label.

**Then MERGE PR C**, and:

```bash
gh pr edit --repo jbaker48/k8s-cluster chore/cb-reset-unscoped --remove-label gate/human-required
```

---

## 6. Post-run checklist

```bash
# 1. State file back to {} on main.
gh api repos/jbaker48/k8s-cluster/contents/.github/health-gate/circuit-breaker-state.json?ref=main \
  --jq '.content' | base64 -d
# must print exactly: {}

# 2. No leftover gate/human-required labels on PRs that should not have them.
gh pr list --repo jbaker48/k8s-cluster --state open --label gate/human-required \
  --json number,title --jq '.[] | "#\(.number) \(.title)"'

# 3. Test branches gone.
git ls-remote --heads origin 'test/cb-unscoped-trip' 'chore/cb-pause-unscoped' 'chore/cb-reset-unscoped'
# must print nothing

# 4. Your unrelated dirty file survived untouched.
git status --short   # expect exactly:  M kubernetes/bootstrap/talos/talconfig.yaml
```

- [ ] `circuit-breaker-state.json` is `{}` on `main`
- [ ] PR A merged, PR C merged
- [ ] PR B closed **without merging**, branch deleted
- [ ] All three test branches deleted
- [ ] `gate/human-required` removed from PR C and from any PR that gained it during the window
- [ ] Any Renovate PR caught in the window re-checked (especially **#1043**, the one PR
      identified as newly at risk)

---

## 7. Record the outcome

- `.planning/phases/05-post-merge-health-gate-auto-revert/05-UAT.md` → **Test 2**
  (note PR numbers A/B/C, the run URL for PR B, and the `buckets=` value you observed).
- `.planning/WINDOWS.md` → entry **#6**. Resolve it only once CR-01, CR-02 **and** both
  halves of CR-03 are proven.
