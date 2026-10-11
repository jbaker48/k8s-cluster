# Live verification runbook: health-gate close-out (October 2026)

**Beads:** k8s-zdb.5.3 (CR-01/02/03), k8s-zdb.5.4 (merge-commit revert, conflict abort+notify), k8s-zdb.5.5 (V-4 to V-8). Recommendation for k8s-zdb.5.6 is a Beads comment on that issue.
**Repo:** `jbaker48/k8s-cluster`. **Owner decision 2026-10-11:** agents prepare, the owner runs. Every command here is for the owner's terminal. No agent lane runs, merges or dispatches anything in this document.
**Supersedes for execution:** `RUNBOOK-CR02-circuit-breaker.md` and `RUNBOOK-CR03-bypass-forgery.md` stay as background reading. Where they disagree with this file (branch names, PR numbers, ordering), follow this file.

## 0. Read first

### 0.1 Test artifacts

| Test | Artifact | Merge? |
|---|---|---|
| CR-01 | draft PR #1137 (`test/hg-cr01-empty-flux-list`) | never; dispatch only |
| CR-02 PR A | draft PR #1135 (`test/hg-cr02-a-pause-unscoped`) | **yes, as setup**, then reverted by PR C |
| CR-02 PR B | branch `test/hg-cr02-b-unscoped-trip` (pushed; owner opens the PR after PR A merges) | never |
| CR-03 negative | draft PR #1133 (`auto-revert/cr03-forgery-test-202610`) | never |
| CR-03 positive | `docs/sre-agent/runbooks/cr03-bypass-positive-proof.sh` (local script, App credentials) | never |
| 5.4 harness | draft PR #1138 (`test/hg-zdb54-revert-conflict-harness`) | never; dispatch only |
| V-4, V-6/V-7 | none: `workflow_dispatch` of production `health-gate.yaml` on `main` with a test input | n/a |
| V-5 | draft PR #1139 (`test/hg-v5-poll-kubectl-failure-harness`) | never; dispatch only |
| V-8 (+ 5.4 live `-m 1`) | draft PR #1134 (`test/hg-v8-bazarr-induced-failure`) | **yes, with a merge commit**, after 5.2 |

All test PRs carry the `hold` label and a title starting `test(health-gate): DO NOT MERGE without runbook`. Local worktrees for each branch are under `/Users/jbaker/Development/k8s-cluster-worktrees/hg-*`.

### 0.2 Ordering against k8s-zdb.5.2 (race fix, option B, in progress)

k8s-zdb.5.2 rewrites the poll classification, adds revision freshness/supersession checks, and changes attribution and serialisation of the revert path. Results from tests that exercise those parts of `health-gate.yaml` before 5.2 merges describe code that is about to be replaced.

| Test | Wait for 5.2? | Why |
|---|---|---|
| CR-03 negative, CR-03 positive | No | `exclusion-gate.yaml` only; 5.2 does not touch it |
| CR-02 | No, but needs a healthy baseline | `exclusion-gate.yaml` only. PR A and PR C merges trigger push health-gate runs, and before 5.2 a stale Stalled resource can make the gate revert the wrong commit (WINDOWS #4) |
| V-4 (window 0) | No; re-run after 5.2 | window 0 means the poll loop never runs, so no classification and no revert. Re-run after 5.2 to prove the notification path survived the rewrite |
| V-6/V-7 (backstop) | No; re-run after 5.2 **only after the seam check in 4.1** | backstop step is not in 5.2's scope, but the seam depends on how the poll step reads the window input |
| CR-01 | **Yes** | tests the classifier, which 5.2 rewrites. The harness reads the classifier from `main` at run time, so run it after 5.2 merges |
| V-5 | **Yes** | tests the poll loop, which 5.2 rewrites |
| 5.4 harness | **Yes** | tests the revert step, which 5.2's attribution/serialisation work touches |
| V-8 + 5.4 live `-m 1` | **Yes, and after 5.2's own live proof** | an unhealthy-path merge before 5.2 hits the race: the push run can call the merge healthy before Flux starts, or revert the revert (run 31170751825) |

### 0.3 Suggested execution order

1. Now: B0 baseline → CR-03 negative → CR-03 positive → V-4 → V-6/V-7 → CR-02 (A, B, C back to back).
2. After 5.2 merges and its live proof passes: B0 → CR-01 → V-5 → 5.4 harness → V-4 and V-6/V-7 re-run → V-8 (+ 5.4 live `-m 1`) → section 11 cleanup.

### 0.4 Global safety rules

- **Only one health-gate-affecting test at a time.** `test-health-gate-rbac.yaml` has a workflow-wide concurrency group with `cancel-in-progress: true`: a second dispatch cancels the first.
- **Never dispatch `health-gate.yaml` with a non-zero `window_override_seconds` or with no override** unless you intend a real poll. If any Flux resource is Stalled/RetriesExceeded at that moment, the gate reverts `main`'s **current HEAD**, whatever it is.
- **Merge freeze** during CR-02 and V-8: no other merges to `main`, including Renovate. (Renovate has no automerge configured in `.github/renovate.json5` at d54dd599; re-check before V-8.)
- Slack evidence arrives via Robusta, which forwards only four Event reasons: `HealthGateAutoRevert`, `HealthGateInconclusive`, `HealthGateRevertFailed`, `HardExclusionBlocked`. Robusta titles the Slack finding with the Event's `metadata.name`. If the Event exists in-cluster but Slack shows nothing, that is the pre-existing gap G-05-1 (Robusta/Slack delivery), not a regression of the step under test; record it.
- Event names include the GitHub run id, so `RUN` below is always the run's `databaseId`.
- **Start each verification test with a fresh trigger.** For tests triggered by `workflow_dispatch`, always use a fresh `gh workflow run` dispatch; never use GitHub's “Re-run jobs” for any verification test. For event-triggered tests, create the fresh PR, push, or merge event prescribed by that section. Event names include the GitHub run id, so `RUN` below is always the run's `databaseId`. A rerun preserves that id, so a second `kubectl create` of the same Event fails with `AlreadyExists` and produces a false FAIL. (V-5 review on PR #1139.)

### 0.5 B0: baseline (run before every section)

```bash
cd /Users/jbaker/git/k8s-cluster
export KUBECONFIG=$PWD/kubeconfig
flux get ks -A | grep -v True          # expect the header line only
flux get hr -A | grep -v True          # expect the header line only
kubectl get pods -n arc-systems | grep k8s-cluster-ci-.*-listener   # 1/1 Running
gh api 'repos/jbaker48/k8s-cluster/contents/.github/health-gate/circuit-breaker-state.json?ref=main' --jq .content | base64 -d   # {}
git ls-remote origin refs/heads/main   # note the SHA
gh run list --workflow health-gate.yaml --limit 3   # nothing in progress
```

Stop if anything is not Ready, the listener is down, the breaker state is not `{}`, or a health-gate run is in progress.

Helper used below:

```bash
latest_run() { gh run list --workflow "$1" --limit 1 --json databaseId --jq '.[0].databaseId'; }
events() { kubectl get events -A --field-selector reason="$1" -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,MSG:.message --sort-by=.lastTimestamp | tail -n 5; }
```

## 1. CR-03 negative: a forged bypass must be refused (k8s-zdb.5.3)

**Proves:** a PR with the `auto-revert/` branch prefix, the `automated-revert` label and same-repo origin, authored by a human, does not get the revert-bot bypass (commit 21c299d1).
**Failure-inducing change:** draft PR #1133 adds the inert file `kubernetes/bootstrap/talos/FORGERY-TEST-MARKER.md` (matches `talos` and `kubernetes-core`). The forgery is the label you add in step 2.
**Preconditions:** B0. PR #1133 open. When the PR was opened, Exclusion Gate already ran on `opened` with no label: it labelled `gate/human-required`, commented, and `notify-exclusion` emitted `HardExclusionBlocked`. That run is **not** the verdict.

```bash
PR=1133
BR=auto-revert/cr03-forgery-test-202610
# 1. Clear the label from the opened run, so the verdict run must re-apply it.
gh pr edit $PR --remove-label gate/human-required
# 2. The forgery: self-apply the bypass label as your human account.
gh pr edit $PR --add-label automated-revert
# 3. Labels do not trigger pull_request_target; push an empty commit to fire synchronize.
git -C /Users/jbaker/Development/k8s-cluster-worktrees/hg-cr03 pull --ff-only
git -C /Users/jbaker/Development/k8s-cluster-worktrees/hg-cr03 commit --allow-empty -m "chore: retrigger exclusion-gate (CR-03 verdict run)"
git -C /Users/jbaker/Development/k8s-cluster-worktrees/hg-cr03 push origin HEAD:$BR
# 4. Watch the synchronize run.
sleep 20; RUN=$(gh run list --workflow "Exclusion Gate" --branch $BR --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch $RUN --exit-status
gh run view $RUN --json jobs --jq '.jobs[] | .name as $j | .steps[] | "\($j) | \(.name): \(.conclusion)"'
gh pr view $PR --json labels,comments --jq '{labels:[.labels[].name], comments:[.comments[] | .body[0:80]]}'
events HardExclusionBlocked
```

**Expected:** Actions: Exclusion Check succeeds; every post-bypass step (Fetch exclusion config from base branch, Build paths-filter map, Evaluate path filters, Compute excluded flag and reasons, Fetch circuit-breaker state from base branch, Resolve touched app buckets, Evaluate circuit-breaker pause state) shows `success`; "Comment on bypassed PR" shows `skipped`; "Notify hard exclusion" job succeeds. PR: `gate/human-required` is back; the "Human merge required … cluster-critical infrastructure" comment lists the talos and kubernetes-core reasons; there is no "Automated health-gate revert recognized" comment. Flux: nothing. Slack: a `hard-exclusion-blocked-<RUN>` finding.
**PASS:** post-bypass steps executed and the label was re-applied. **FAIL:** post-bypass steps `skipped` or the bypass comment appears. FAIL blocks k8s-zdb.6: any collaborator could skip the cluster-critical gate.
**Side evidence:** if "Notify hard exclusion" fails with an i/o timeout to `10.20.0.250:6443`, WINDOWS #13 (runner cannot reach the API VIP) is still open. Record it; it does not change the CR-03 verdict.
**Cleanup:** `gh pr close $PR --delete-branch`; `git worktree remove /Users/jbaker/Development/k8s-cluster-worktrees/hg-cr03`.
**Beads:** comment on k8s-zdb.5.3 with PR, RUN and the step table.

## 2. CR-03 positive: a real revert-bot PR still bypasses (k8s-zdb.5.3)

**Proves:** a PR actually authored by `k8s-cluster-revert-bot[bot]` (type Bot) gets the bypass. If this fails, every automatic revert PR is gated as human-required and auto-revert is silently disabled.
**Failure-inducing change:** the script creates branch `auto-revert/bypass-positive-test` and a PR authored by the App, then commits the inert `kubernetes/bootstrap/talos/BYPASS-POSITIVE-TEST-MARKER.md`.
**Preconditions:** B0; CR-03 negative done; revert-bot App credentials (owner-only, from Doppler).

```bash
cd /Users/jbaker/git/k8s-cluster
export REVERT_BOT_APP_ID="$(doppler secrets get REVERT_BOT_APP_ID --plain)"
export REVERT_BOT_APP_PRIVATE_KEY="$(doppler secrets get REVERT_BOT_APP_PRIVATE_KEY --plain)"
docs/sre-agent/runbooks/cr03-bypass-positive-proof.sh --dry-run
docs/sre-agent/runbooks/cr03-bypass-positive-proof.sh
unset REVERT_BOT_APP_PRIVATE_KEY
```

**Expected:** the script prints RUN 1 (baseline, not the verdict) and RUN 2 (verdict). In RUN 2, "Comment on bypassed PR" ran, every post-bypass step is `skipped`, and no `gate/human-required` label is applied even though a talos path is in the diff. No Flux change. No Slack (no exclusion is computed, so no `HardExclusionBlocked`).
**PASS:** RUN 2 took the bypass. **FAIL:** RUN 2 evaluated exclusions. Stop and file a P1 bug on k8s-zdb.5; k8s-zdb.6 cannot go live.
**Cleanup:** run the teardown commands the script prints (close the PR without merging, delete the branch).
**Beads:** comment on k8s-zdb.5.3 with PR number and both run URLs.

## 3. V-4: inconclusive path with no poll data (k8s-zdb.5.5)

**Proves:** the inconclusive notification fires and is honest when the gate has no Flux data (fix 1698128d, empty-list branch), and the run never reaches the revert path.
**Failure-inducing change:** none in git. Input `window_override_seconds=0` makes the poll deadline equal to now, so the loop never iterates, `outcome=inconclusive`, and `not_ready_items=[]`. No poll means no classification, so no revert is possible.
**Preconditions:** B0.

```bash
gh workflow run health-gate.yaml --ref main -f window_override_seconds=0
sleep 15; RUN=$(latest_run health-gate.yaml)
gh run watch $RUN --exit-status
gh run view $RUN --json jobs --jq '.jobs[].steps[] | "\(.name): \(.conclusion)"'
gh run view $RUN --log | grep -E 'outcome=|event/|WARNING'
events HealthGateInconclusive
```

**Expected:** Actions: run `success`; poll prints `outcome=inconclusive` with no WARNING; "Emit inconclusive notification" `success` and prints `event/health-gate-inconclusive-<RUN> created`; every unhealthy-branch step and the backstop `skipped`. Flux: no change. Slack: finding `health-gate-inconclusive-<RUN>` on `flux-system/cluster-apps` whose message says the merge is **UNWATCHED** and does **not** say "still reconciling".
**PASS:** all of the above. **FAIL:** a red run, a poll step with zero stdout (G-05-2 regression), a namespace `null` error, the notification step skipped, or any revert-path step not skipped.
**Populated-list variant:** the inconclusive message listing real resources is observed for free in section 9 if the V-8 push run's window ends before bazarr stalls. It is not induced separately, because any non-zero window on `main` with an unhealthy cluster reverts `main`'s HEAD.
**Cleanup:** none (Events expire after the cluster's event TTL).
**Beads:** comment on k8s-zdb.5.5 with RUN.

## 4. V-6 and V-7: backstop fires and reaches Slack (k8s-zdb.5.5)

**Proves:** when a step dies after auth, the `if: failure()` backstop (6860c787) still emits the `::error::` annotation, the job-summary entry and the `health-gate-backstop-no-verdict-<RUN>` Event (V-6), and Robusta delivers it to Slack (V-7).
**Failure-inducing change:** none in git. Input `window_override_seconds=INDUCE_BACKSTOP` makes the poll step's first line `$(( $(date +%s) + WINDOW_SECONDS ))` reference an unset variable under `set -u`, so the poll step dies before any kubectl call (verified locally: `INDUCE_BACKSTOP: unbound variable`, exit 1). With no `outcome`, every later conditional step is skipped and only the backstop runs.

### 4.1 Seam check (mandatory before every run, especially after 5.2)

```bash
git fetch origin main
git show origin/main:.github/workflows/health-gate.yaml | grep -n -E 'WINDOW_OVERRIDE|WINDOW_SECONDS=|DEADLINE_EPOCH=|set -uo pipefail' | head
```

Run section 4 only if the "Resolve observation window" step still copies the raw override into `WINDOW_SECONDS` and the poll step still evaluates `$(( ... + WINDOW_SECONDS ))` under `set -u` before its first kubectl call. If 5.2 validates the input or falls back to 900 seconds, **do not run**: the run would do a real 15-minute poll and could revert `main`'s HEAD. Ask for a new seam instead.

```bash
gh workflow run health-gate.yaml --ref main -f window_override_seconds=INDUCE_BACKSTOP
sleep 15; RUN=$(latest_run health-gate.yaml)
gh run watch $RUN --exit-status; echo "exit=$? (non-zero expected)"
gh run view $RUN --json jobs --jq '.jobs[].steps[] | "\(.name): \(.conclusion)"'
gh run view $RUN            # shows the annotation "Health gate did not reach a verdict"
gh run view $RUN --log | grep -E 'unbound variable|backstop|event/'
events HealthGateInconclusive | grep backstop
```

**Expected:** Actions: run conclusion `failure`; "Poll Flux conditions and classify" `failure` with `INDUCE_BACKSTOP: unbound variable`; inconclusive and all unhealthy-branch steps `skipped`; "Backstop - guarantee an operator-facing signal on failure" `success`; annotation and job summary "Health gate did not reach a verdict … UNWATCHED … Last recorded poll outcome: 'none'"; log `event/health-gate-backstop-no-verdict-<RUN> created`. Flux: no change. Slack (V-7): finding titled `health-gate-backstop-no-verdict-<RUN>`.
**PASS:** V-6 = red run + annotation + summary + Event. V-7 = the Slack finding. **FAIL:** silence (no annotation), backstop `skipped`, or the backstop log says it could not create the Event (RBAC or API reachability; compare WINDOWS #13). Event present and no Slack is G-05-1: record it against V-7, not as a backstop regression.
**Residual:** the early-bootstrap variant (kubectl never installed) is covered only by the offline harness in 6860c787. Inducing it live needs a broken `HEALTH_GATE_KUBECONFIG` secret, which cannot be read back. Accept it or decide otherwise in the Beads comment.
**Cleanup:** none.
**Beads:** comment on k8s-zdb.5.5 with RUN, separate V-6 and V-7 verdicts.

## 5. CR-02: a paused `unscoped` circuit breaker is enforced (k8s-zdb.5.3)

**Proves:** a PR touching zero `kubernetes/apps/**` paths resolves to the `unscoped` bucket and is gated when that bucket is paused (commit 21c299d1).
**Failure-inducing change:** PR #1135 sets `.github/health-gate/circuit-breaker-state.json` to `{"unscoped":{"reverts":[],"paused":true}}`. This is the one test PR you merge, because `exclusion-gate.yaml` reads the state at the PR's `base.sha`.
**Blast radius while PR A is on `main`:** every open PR touching zero `kubernetes/apps/**` paths gets `gate/human-required` and a breaker comment on its next `opened`/`reopened`/`synchronize` event. Comment and label only; nothing merges automatically. Keep A → B → C back to back.
**Preconditions:** B0 all Ready (PR A and PR C merges trigger push health-gate runs; before 5.2 a stale Stalled resource could make the gate revert the wrong commit). Merge freeze. Measure the unscoped PRs now so you can re-check them afterwards:

```bash
for n in $(gh pr list --state open --json number --jq '.[].number'); do
  B=$(gh api "repos/jbaker48/k8s-cluster/pulls/$n/files" --paginate --jq '.[].filename' \
      | awk -F/ '$1=="kubernetes" && $2=="apps" && NF>=4 {print $3"/"$4}' | sort -u | wc -l | tr -d ' ')
  [ "$B" = "0" ] && echo "unscoped: #$n"
done
```

```bash
# PR A: merge as setup.
gh pr ready 1135 && gh pr merge 1135 --merge
A_SHA=$(gh pr view 1135 --json mergeCommit --jq .mergeCommit.oid)
sleep 20; RUN_A=$(gh run list --workflow health-gate.yaml --commit $A_SHA --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch $RUN_A --exit-status && gh run view $RUN_A --log | grep 'outcome='   # healthy

# PR B: open only now, so its base.sha includes the paused state.
gh pr create --draft --base main --head test/hg-cr02-b-unscoped-trip --label hold \
  --title 'test(health-gate): DO NOT MERGE without runbook — CR-02 PR B unscoped breaker trip' \
  --body 'CR-02 PR B (k8s-zdb.5.3). Touches only README.md. Expect the paused unscoped breaker to gate it. Never merge; close after the verdict.'
PRB=$(gh pr view test/hg-cr02-b-unscoped-trip --json number --jq .number)
sleep 20; RUN_B=$(gh run list --workflow "Exclusion Gate" --branch test/hg-cr02-b-unscoped-trip --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch $RUN_B --exit-status
gh run view $RUN_B --log | grep -E 'buckets=|paused='
gh pr view $PRB --json labels,comments --jq '{labels:[.labels[].name], comments:[.comments[].body[0:120]]}'
```

**Expected:** Actions: "Resolve touched app buckets" logs `buckets=["unscoped"]` and "Evaluate circuit-breaker pause state" sets `paused=true`; "Comment on circuit-breaker-paused PR" and "Apply gate label for circuit breaker" run; "Comment on excluded PR" is `skipped`. PR B: `gate/human-required` label; comment "circuit breaker paused for one or more app buckets" listing `` `unscoped`: 0 revert(s) recorded `` (0 is expected: PR A set `reverts: []`). No exclusion comment. Flux: no change (health-gate push run for PR A healthy). Slack: none.
**PASS:** label and breaker comment on PR B, `buckets=["unscoped"]`, `paused=true`. **FAIL:** no label and no breaker comment: a paused breaker can be walked past by any non-app PR.

```bash
# Close the window: close B, then revert A through PR C.
gh pr close $PRB --delete-branch
git -C /Users/jbaker/git/k8s-cluster fetch origin main
git -C /Users/jbaker/git/k8s-cluster worktree add /Users/jbaker/Development/k8s-cluster-worktrees/hg-cr02c -b test/hg-cr02-c-reset origin/main
printf '{}\n' > /Users/jbaker/Development/k8s-cluster-worktrees/hg-cr02c/.github/health-gate/circuit-breaker-state.json
git -C /Users/jbaker/Development/k8s-cluster-worktrees/hg-cr02c commit -am "chore(health-gate): reset circuit breaker after CR-02 live verification (PR C)"
git -C /Users/jbaker/Development/k8s-cluster-worktrees/hg-cr02c push -u origin test/hg-cr02-c-reset
gh pr create --base main --head test/hg-cr02-c-reset \
  --title 'chore(health-gate): reset circuit breaker after CR-02 live verification (PR C)' \
  --body 'Resets circuit-breaker-state.json to {} (k8s-zdb.5.3). This PR is itself gated by the paused base state; that is correct. Human merge.'
gh pr merge test/hg-cr02-c-reset --merge --delete-branch
gh pr edit 1135 --remove-label gate/human-required 2>/dev/null || true
```

PR C will itself get `gate/human-required` and a breaker comment: correct behaviour, merge it anyway.
**Cleanup:** state file is `{}` on `main` (B0 command); health-gate push run for PR C is healthy; remove `gate/human-required` from any PR from the pre-flight list that gained it during the window; `git ls-remote --heads origin 'test/hg-cr02-*'` prints nothing; remove worktrees `hg-cr02a`, `hg-cr02b`, `hg-cr02c`.
**Beads:** comment on k8s-zdb.5.3 with PR A/B/C numbers, RUN_B, observed `buckets=`.

---

**Stop here until k8s-zdb.5.2 has merged and its own live proof has passed.** Then re-run B0.

## 6. CR-01: an empty Flux list never classifies healthy (k8s-zdb.5.3)

**Proves:** the production classifier returns `all_ready=false` with zero stalled entries for a genuine HTTP 200 empty list (2477e4b5).
**Failure-inducing change:** draft PR #1137 adds a step to `test-health-gate-rbac.yaml` (branch copy only) that queries `kube-public` (no Flux resources) through the real health-gate ServiceAccount and runs **main's** classifier, extracted from `health-gate.yaml` at run time, over the response. Read-only verbs only.
**Preconditions:** B0; `kubectl get ks,hr -n kube-public` returns nothing; no other `test-health-gate-rbac.yaml` run in progress.

```bash
gh workflow run test-health-gate-rbac.yaml --ref test/hg-cr01-empty-flux-list
sleep 15; RUN=$(latest_run test-health-gate-rbac.yaml)
gh run view $RUN --json headBranch --jq .headBranch    # must be test/hg-cr01-empty-flux-list
gh run watch $RUN --exit-status
gh run view $RUN --json jobs --jq '.jobs[].steps[].name'
gh run view $RUN --log | grep -E 'PASS|FAIL|PREMISE'
```

**Expected:** run `success`; step list includes the checkout-main and yq steps and ends with `CR-01 regression assertion …`; log `PASS: CR-01 holds`. Flux and Slack: nothing.
**PASS:** the PASS banner on a run whose `headBranch` is the test branch. **FAIL:** `REGRESSION FAILURE: CR-01 REGRESSION DETECTED`. **PREMISE FAILURE** is a harness problem (for example 5.2 renamed the step or restructured `JQ_CLASSIFY`): no verdict, ask for the harness to be updated. A dispatch against `main` (5 steps; for example run 31583783942) proves nothing.
**Cleanup:** `gh pr close 1137 --delete-branch`; remove worktree `hg-cr01`.
**Beads:** comment on k8s-zdb.5.3 with RUN.

## 7. V-5: the poll survives a dead API (k8s-zdb.5.5)

**Proves:** with every kubectl call failing, main's poll step keeps polling with WARNINGs, ends `outcome=inconclusive` with an empty not-ready list, and main's inconclusive notification then emits the UNWATCHED Event (0e0fba68, 1698128d).
**Failure-inducing change:** draft PR #1139 adds harness steps to the branch copy of `test-health-gate-rbac.yaml`. They run main's "Poll Flux conditions and classify" body with a dead kubeconfig (`https://127.0.0.1:1`) and a 90-second window, then main's "Emit inconclusive notification" body with the real kubeconfig. This is a harness, not the production job: the only difference from production is the poll's kubeconfig. It avoids overwriting the `HEALTH_GATE_KUBECONFIG` secret, which cannot be read back.
**Preconditions:** B0; no other rbac-test run in progress.

```bash
gh workflow run test-health-gate-rbac.yaml --ref test/hg-v5-poll-kubectl-failure-harness
sleep 15; RUN=$(latest_run test-health-gate-rbac.yaml)
gh run view $RUN --json headBranch --jq .headBranch
gh run watch $RUN --exit-status
gh run view $RUN --log | grep -E 'WARNING: kubectl poll failed|outcome=|event/|PASS|FAIL|PREMISE|REGRESSION'
events HealthGateInconclusive | grep $RUN
```

**Expected:** at least two `WARNING: kubectl poll failed; retrying in 30s`, then `outcome=inconclusive`, then `event/health-gate-inconclusive-<RUN> created`, then the PASS banner; run `success`. The V-5 harness overrides `GITHUB_SHA` for the notification body only, so the Event message reads `Merge HARNESS-TEST-not-a-merge-<sha7> to main ...`. Slack: `health-gate-inconclusive-<RUN>` with the UNWATCHED wording.
**PASS:** as above. **FAIL:** the poll body exits non-zero or prints nothing (G-05-2 regressed), or the notification body fails. PREMISE: harness needs updating after 5.2.
**Cleanup:** `gh pr close 1139 --delete-branch`; remove worktree `hg-v5`.
**Beads:** comment on k8s-zdb.5.5 with RUN.

## 8. k8s-zdb.5.4 harness: `-m 1` on a real merge commit, and conflict → abort + notify

**Proves:** main's "git revert, or abort and notify on conflict" step body (3f26bb5f) (S1) reverts a real two-parent merge commit with `-m 1`, and (S2) on a real conflict runs `git revert --abort`, emits `HealthGateRevertFailed` and exits 1 without leaving a revert in progress.
**Why a harness:** in production the step checks out the merge SHA and reverts that same tip, so a conflict cannot happen there; reaching the conflict branch would need an edit to `health-gate.yaml`. The retry-once rebase conflict in "Push, create, and merge the revert PR" is race-only and is not induced (residual, recorded in Beads).
**Failure-inducing change:** draft PR #1138: harness steps on the branch copy of `test-health-gate-rbac.yaml` that build a scratch repo under `$RUNNER_TEMP` (S0 premise: plain `git revert` of the merge fails with "is a merge but no -m option"; S1: tip is the merge; S2: a later commit conflicts with the merge) and run main's step body against it. The harness pushes nothing anywhere. Its only side effect is S2's real Event in `flux-system` against `Kustomization/cluster-apps`.
**Preconditions:** B0; no other rbac-test run in progress. Expect one `HealthGateRevertFailed` Slack alert naming a scratch SHA: that is the evidence, not an incident. The harness ServiceAccount can create Events but cannot read them back; the owner’s `events HealthGateRevertFailed | grep "$RUN"` command and Slack are the proof of reason routing.

```bash
gh workflow run test-health-gate-rbac.yaml --ref test/hg-zdb54-revert-conflict-harness
sleep 15; RUN=$(latest_run test-health-gate-rbac.yaml)
gh run view $RUN --json headBranch --jq .headBranch
gh run watch $RUN --exit-status
gh run view $RUN --log | grep -E 'S0|S1|S2|reversing changes|event/|PASS|FAIL|PREMISE|REGRESSION'
events HealthGateRevertFailed | grep $RUN
```

**Expected:** S0 PASS (premise); S1 PASS (exit 0, `branch=auto-revert/unscoped-<RUN>`, commit message contains "reversing changes made to", tree equals first parent, no Event); S2 PASS (exit 1, `event/health-gate-revert-failed-<RUN> created`, no `REVERT_HEAD`, clean status, HEAD unchanged); run `success`. Slack: finding `health-gate-revert-failed-<RUN>` reading "git revert of <scratch sha> failed with a conflict against main; git revert --abort was run and no revert PR was created."
**PASS:** S0, S1 and S2 all PASS and the Event exists. **FAIL:** S1 non-zero (the `-m 1` fix regressed), S2 exit 0 or a revert left in progress (abort path regressed), or S2 with no Event (notify path regressed). PREMISE: harness needs updating.
**Cleanup:** `gh pr close 1138 --delete-branch`; remove worktree `hg-zdb54`.
**Beads:** comment on k8s-zdb.5.4 with RUN and the S0/S1/S2 table.

## 9. V-8: real revert path end to end, plus the live `-m 1` proof (k8s-zdb.5.5, k8s-zdb.5.4)

**Proves:** a merge-commit merge that breaks one app is detected, reverted with `-m 1` through a revert-bot PR that bypasses the exclusion gate and self-merges, and announced with `HealthGateAutoRevert`. After 5.2, the push run for the revert's own merge commit must **not** revert the revert.
**Failure-inducing change:** draft PR #1134 changes only `kubernetes/apps/media/bazarr/app/helmrelease.yaml`: image tag `1.5.4` → `1.5.4-zdb55-induced-failure-test` (does not exist, so ImagePullBackOff) and `spec.timeout: 2m`, so upgrade + rollback + 3 retries reach `RetriesExceeded`/`Stalled` in roughly 8–10 minutes, inside the 900-second window. Blast radius: the bazarr HelmRelease. Helm rolls back after each failed upgrade, so bazarr keeps serving the previous release.
**Preconditions:** 5.2 merged and live-proven; B0 all Ready; bazarr HR Ready on 1.5.4 (`kubectl get hr -n media bazarr`); breaker state `{}`; merge freeze for about 40 minutes (check `gh pr list` for anything about to merge); read 5.2's PR description for any changed dispatch or attribution behaviour and adjust the expectations below to it.

```bash
PR=1134
gh pr ready $PR
gh pr merge $PR --merge                       # MUST be a merge commit
M=$(gh pr view $PR --json mergeCommit --jq .mergeCommit.oid)
gh api repos/jbaker48/k8s-cluster/commits/$M --jq '.parents | length'   # expect 2
sleep 20; RUN=$(gh run list --workflow health-gate.yaml --commit $M --limit 1 --json databaseId --jq '.[0].databaseId')
kubectl get hr -n media bazarr -w &            # watch Ready/Stalled transitions; kill when done
gh run watch $RUN --exit-status
gh run view $RUN --log | grep -E 'outcome=|resolved buckets|Auto-revert|event/'
REVERT_PR=$(gh pr list --state merged --label automated-revert --limit 1 --json number --jq '.[0].number')
gh pr view $REVERT_PR --json author,headRefName,labels,mergeCommit,comments --jq '{author:.author.login, head:.headRefName, labels:[.labels[].name], merge:.mergeCommit.oid, comments:[.comments[].body[0:80]]}'
git fetch origin main && git log origin/main -3 --format='%h %s%n%b' | grep -E 'Revert|reverts commit|reversing changes'
events HealthGateAutoRevert
```

**Expected:** Flux: bazarr HR goes `Ready=False` (upgrade timeout) and ends `RetriesExceeded`/`Stalled=True`; after the revert merges it returns to Ready on 1.5.4. If Flux has not picked up M within 2 minutes (`flux get sources git -A`), the owner may run `flux reconcile source git home-kubernetes -n flux-system`. Actions run on M: `outcome=unhealthy`, `resolved buckets: ["media/bazarr"]`, revert step succeeds, "Update circuit-breaker state" and "Push, create, and merge the revert PR" succeed, backstop `skipped`. Revert PR: author `k8s-cluster-revert-bot[bot]`, head `auto-revert/media-bazarr-<RUN>`, label `automated-revert`, Exclusion Gate comment "Automated health-gate revert recognized" (live CR-03 positive evidence), merged with a merge commit. The revert commit body reads "This reverts commit M, reversing changes made to <first parent>": that wording only comes from `git revert -m 1` and is the live 5.4 proof. Slack: `health-gate-revert-<RUN>` "Merge M to main reverted after media/bazarr reported Stalled/Failed". The health-gate run for the revert PR's merge commit ends healthy or, per 5.2's semantics, inconclusive/superseded, and **never** opens a second revert PR.
**If the run on M ends inconclusive** (window ended before bazarr stalled): this is the populated-list V-4 evidence (bazarr named in a `health-gate-inconclusive-<RUN>` Slack message). Re-trigger detection only as 5.2's PR description specifies. Never dispatch `health-gate.yaml` on `main` unless `git ls-remote origin refs/heads/main` still equals M, because a dispatch reverts `main`'s current HEAD.
**PASS:** every expected item above. **FAIL:** no revert, a revert PR that is gated or not merged, a revert of the wrong commit, a second revert of the revert (5.2 race regressed), or a revert step failure. On FAIL: keep the merge freeze, prepare a manual revert (`git revert -m 1 $M` on a branch, PR, human merge), restore bazarr, and file a Beads bug under k8s-zdb.5 with the RUN.
**Cleanup:** reset the breaker (it now records one `media/bazarr` revert): branch from `origin/main`, `printf '{}\n' > .github/health-gate/circuit-breaker-state.json`, PR, human merge. Confirm bazarr HR Ready on 1.5.4, `gh pr list --label automated-revert --state open` is empty, test branches deleted, worktree `hg-v8` removed.
**Beads:** comment on k8s-zdb.5.5 (V-8) and k8s-zdb.5.4 (live `-m 1` proof) with PR, M, RUN, revert PR and the revert-of-revert run.

## 10. Recording results

For each section, post the durable-handoff comment from `docs/dynamic-workflow.md` on the issue named in the section, with the run URLs as evidence. Close an issue only when every one of its tests has PASSed:

- k8s-zdb.5.3: CR-01, CR-02, CR-03 negative and CR-03 positive.
- k8s-zdb.5.4: section 8 (S0–S2) and the `-m 1` evidence from section 9.
- k8s-zdb.5.5: V-4, V-5, V-6, V-7, V-8 (plus an explicit accept/reject of the early-bootstrap residual in section 4).

Then update `docs/sre-agent/WINDOWS.md` entries #6, #7, #8 and #14 (and #13 if section 1 or 4 showed API VIP reachability) through a normal PR.

## 11. Final cleanup checklist

```bash
gh pr list --state open --label hold --json number,title --jq '.[] | "#\(.number) \(.title)"'   # no test(health-gate) PRs left
git ls-remote --heads origin 'test/hg-*' 'auto-revert/*'                                      # nothing
gh api 'repos/jbaker48/k8s-cluster/contents/.github/health-gate/circuit-breaker-state.json?ref=main' --jq .content | base64 -d   # {}
gh pr list --state open --label gate/human-required --json number,title                       # only PRs that genuinely need it
git -C /Users/jbaker/git/k8s-cluster worktree list | grep hg-                                  # remove leftovers with git worktree remove
flux get hr -A | grep -v True                                                                  # header only
```
