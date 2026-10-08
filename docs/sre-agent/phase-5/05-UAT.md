---
status: testing
phase: 05-post-merge-health-gate-auto-revert
source: [05-VERIFICATION.md]
started: 2026-08-07T11:32:00Z
updated: 2026-08-07T11:32:00Z
---

## Current Test

number: 2
name: Live re-exercise of code-review fixes CR-01/CR-02/CR-03 (WINDOWS.md #6)
expected: |
  CR-01: an empty Flux resource list never classifies as healthy.
  CR-02: a paused `unscoped` circuit-breaker bucket blocks a real non-app-path PR.
  CR-03: only a PR actually authored by the revert-bot App (k8s-cluster-revert-bot[bot]) bypasses exclusion-gate; a forged branch-name+label PR from a different identity does NOT bypass.
awaiting: user response

## Tests

### 1. Slack confirmation of Plan 05-07's 3 genuine HealthGateAutoRevert notifications
expected: All 3 notifications visible in #k8s-alerts with correct content (matches 05-03's already-confirmed pattern). K8s Events underlying them are confirmed to exist programmatically; Slack delivery itself could not be independently corroborated by the executor.
result: issue
reported: "Only 1 of 3 delivered — health-gate-revert-31165238337 is present in #k8s-alerts; health-gate-revert-31164977487 (cycle 1) and health-gate-revert-31170706760 (cycle 3) do not appear when searching Slack."
severity: major
corroborating_evidence: |
  robusta-runner pod robusta-runner-c47969988-86wgf has run continuously since 2026-08-06 22:40
  (predates all 3 cycles, no restart), so its full log covers the test window.
  - The runner NEVER logs event names: 0 hits for `plan-05-03` (05-03's synthetic events, which
    DID deliver to Slack and were human-confirmed) and 0 hits for `health-gate` overall. Log
    absence is therefore not evidence of absence on its own.
  - However, Slack API activity IS logged. Enumerating every 2026-08-07 log timestamp shows
    activity at 09:41:07 (10s after cycle 2's revert PR #1083 merged at 09:40:57Z) — the one
    cycle the user confirms delivered. Cycles 1 (PR #1082 merged 09:14:03Z) and 3 (PR #1084
    merged 10:36:24Z) have ZERO runner log activity anywhere in their windows.
  - Conclusion: the two missing notifications failed UPSTREAM of Slack delivery — the Robusta
    customPlaybook/forwarder never processed those two HealthGateAutoRevert Events at all. This
    is distinct from WINDOWS.md #3 (the known files:write scope gap), which only breaks the
    `Related Events.txt` attachment upload, not core text delivery.
  - 05-07-SUMMARY.md line 185 already noted cycle 1's missing runner log entry as "inconclusive,
    not a confirmed failure". This UAT result resolves that ambiguity: it was a real failure.

### 2. Live re-exercise of code-review fixes CR-01/CR-02/CR-03 (WINDOWS.md #6)
expected: |
  CR-01: an empty Flux resource list never classifies as healthy.
  CR-02: a paused `unscoped` circuit-breaker bucket blocks a real non-app-path PR.
  CR-03: only a PR actually authored by the revert-bot App (k8s-cluster-revert-bot[bot]) bypasses exclusion-gate; a forged branch-name+label PR from a different identity does NOT bypass.
result: [pending]
validation_procedure: |
  Derived 2026-08-12 from the live cluster + actual gate code. Scaffolding in progress via /gsd-quick.

  CR-01 (health-gate.yaml:132, `(.items | length > 0) and ...`):
    Prod's `-A` query cannot be made to return empty, but a genuine HTTP-200 empty response can:
    verified live that `kubectl get kustomizations...,helmreleases... -n kube-public -o json`
    returns `items: []` with exit 0. Seam: `.github/workflows/test-health-gate-rbac.yaml`
    (workflow_dispatch, already runs on k8s-cluster-ci with HEALTH_GATE_KUBECONFIG). Add a step
    that queries kube-public, pipes it through the JQ_CLASSIFY block copied verbatim from
    health-gate.yaml, and fails the job if `all_ready == true`. Real API call / RBAC / empty
    response / classifier; only the namespace scope differs from prod. Zero prod impact.

  CR-02 (exclusion-gate.yaml:163-165 unscoped fallback):
    exclusion-gate reads circuit-breaker state from `base.sha` (line 144), so the pause must
    already be on main. Current state is `{}`. Three PRs:
      A. Set circuit-breaker-state.json to {"unscoped":{"reverts":[],"paused":true}}, MERGE.
         (That path is in no exclusion category, so it won't self-block.)
      B. Throwaway PR touching a path outside kubernetes/apps/** AND outside all 3 exclusion
         categories (README.md works). Expect gate/human-required + the 🔌 comment naming
         `unscoped`. Close without merging.
      C. Reset state file to {}, MERGE.
    WARNING: while A is on main, EVERY non-app-path PR is blocked (incl. Renovate PRs touching
    .github/). Keep the window short.

  CR-03 (exclusion-gate.yaml:46-52 author check):
    Negative proof (the security fix): PR from branch `auto-revert/forgery-test`, self-apply the
    `automated-revert` label, touch an excluded path (comment-only line in talconfig.yaml).
    Expect bypass NOT taken -> 🚫 comment + gate/human-required. Close without merging.
    GOTCHA: trigger is bare `pull_request_target` (default types opened/reopened/synchronize) —
    labeling does NOT retrigger. Apply label, then push an empty commit to fire `synchronize`.

    Positive proof (REGRESSION RISK — highest-value test of the three): commit 21c299d1 ADDED the
    PR_AUTHOR_LOGIN == "k8s-cluster-revert-bot[bot]" requirement. Real revert PRs #1082-#1084 all
    predate it, so nothing yet proves a legitimate bot revert still bypasses. If that check is
    wrong, auto-revert silently stops working — the exact safety net Phase 6 depends on.
    REVERT_BOT_APP_ID / REVERT_BOT_APP_PRIVATE_KEY are `health-gate` environment secrets, so:
    a throwaway workflow_dispatch job in that environment mints an installation token, opens a
    no-op PR from `auto-revert/bypass-positive-test` with the label; confirm the ✅ bypass comment
    and absence of gate/human-required; close it. (Alternative — a 4th induced-failure cycle —
    costs a real bazarr outage and re-trips the circuit breaker.)

### 3. Live re-exercise of the revert-conflict notification fix (WINDOWS.md #7, commit 3f26bb5f)
expected: |
  Deliberately triggering a `git revert` failure (e.g. reverting a merge commit, or a genuine
  textual conflict) produces a `HealthGateRevertFailed` Kubernetes Event and the job fails with
  a non-zero exit — matching Plan 05-06's "never silently producing a broken or partial revert
  PR" must-have. This fix was applied after a live failure (run 31170751825) showed the original
  code's error-handling never executed due to a shell `-e` inheritance bug.
result: [pending]

## Live Blocker (discovered 2026-08-12 ~10:00Z, during UAT test 2 dispatch)

`k8s-cluster-ci` ARC runner scale set is NON-FUNCTIONAL. Tests 2 and 3 cannot run until fixed.

Evidence:
- `autoscalingrunnerset/k8s-cluster-ci` (arc-runners) is `phase: Outdated`, currentRunners 0, and has NO
  `AutoscalingListener`. Only `ha-restarter`'s listener exists, so ARC as a whole is fine — this one
  scale set is broken.
- `gh api repos/jbaker48/k8s-cluster/actions/runners` => total_count 0.
- Controller (pod up 5d9h, 0 restarts) is WEDGED: its log ends at 2026-08-12T09:38:17Z mid-loop
  ("deleting runner scale set" -> "Deleted the runner scale set from Actions service" ->
  "AutoscalingListener does not exist." -> "Ephemeral runner set is outdated" -> repeat) and has
  emitted nothing since — ~30min of silence while jobs queue.
- NOT a Flux/config regression: HelmRelease k8s-cluster-ci is Ready, unchanged since 2026-08-07T00:47:28Z
  (v4, chart 0.14.2). Flux kustomization actions-runner-controller Ready at main@sha1:767a4871.
- Timeline: 09:37:50Z dispatch -> runner pending 09:37:56 -> running 09:38:03 -> marked outdated 09:38:12
  -> cleaned up -> controller enters delete loop 09:38:16 and hangs. The wedge PREDATES the 10:00:06Z
  re-dispatch by ~22min, so it was not caused by cancelling the earlier run.
- Runs 31583783942 (main, cancelled 0 steps) and 31585452784 (branch, queued indefinitely) both produced
  no verdict.

PRODUCTION IMPACT beyond testing — both of these run `runs-on: k8s-cluster-ci`:
- `health-gate.yaml`: the post-merge health-gate does not execute AT ALL right now. Any merge to main is
  currently unwatched and un-revertable. The Phase 5 safety net is silently inert.
- `exclusion-gate.yaml`'s `notify-exclusion` job: hard-exclusion notifications do not fire.
- NOT affected: `exclusion-gate.yaml`'s `exclusion-check` job runs on `ubuntu-latest`, so deterministic
  path-gating and labelling still work.

This compounds gap G-05-1: notification delivery was already unreliable, and now the job that emits the
events cannot start. Phase 6 must not proceed until both are resolved.

## Summary

total: 3
passed: 0
issues: 1
pending: 2
skipped: 0
blocked: 0

## Gaps

- gap_id: G-05-3
  truth: "Cluster-critical infra is ALWAYS excluded from AI-driven auto-merge via deterministic path-glob matching, regardless of agent judgment (PROJECT.md's stated non-negotiable; ROADMAP Phase 1 GATE-01/GATE-02 criterion 1)."
  status: fixed
  fixed_by: 755dfa49
  severity: blocker
  found: "2026-08-14, during the G-05-2 defect-class audit (quick task 260814-qee) — NOT by a scripted test."
  reason: >
    `exclusion-gate.yaml`'s `exclusion-check` job set NO shell options on ANY step, so only GitHub's
    inherited `-e` applied and there was no `pipefail`. `gh api ... --jq '.content' | base64 -d >
    /tmp/exclusion-gate.yaml` therefore reported the exit status of `base64 -d`, which SUCCEEDS on
    empty input — so a failed, rate-limited, or unauthorized `gh` call left an empty config behind
    and exited 0. Compounding it, `for k in $(yq ... )` is exempt from `-e` and simply iterates zero
    times on failure. Net effect: a transient GitHub API blip published `excluded=false` AND
    `paused=false` with a GREEN check — Talos, kubernetes-core, flux and Cilium paths all silently
    eligible for AI-driven auto-merge, and a tripped circuit breaker silently unenforced.
    This is FAIL-OPEN, strictly worse than G-05-2's fail-silent: the gate did not merely go quiet,
    it actively published the permissive verdict. It defeats the single guarantee the whole project
    describes as non-negotiable, and it had been latent since Phase 1.
    Fix: `set -euo pipefail` on all 9 steps, assert-after-fetch (a missing/empty config aborts the
    job rather than evaluating to "not excluded"), and lists resolved before their loops. Same
    treatment applied to the circuit-breaker state fetch.
  verification_required: >
    LIVE PROOF STILL OUTSTANDING (V-1, highest priority): open a throwaway PR touching
    kubernetes/bootstrap/talos/talconfig.yaml and confirm the 🚫 comment + gate/human-required label.
    Pre-fix harness proof: fetch exit=0 -> published 'excluded=false'. Post-fix: fetch exit=1 -> no
    verdict published.
  test: n/a (found by audit)
  artifacts: []
  missing: []

- gap_id: G-05-2
  truth: "An errored poll iteration can only ever fall through to 'keep polling'/'inconclusive', never silence — the health-gate must always either revert or notify a human (ROADMAP Phase 5 criteria 1, 3 and 5; health-gate.yaml's own documented fail-closed guarantee)."
  status: failed
  reason: >
    PROVEN LIVE on run 31778908203 (push of 89f55e1d to main, 2026-08-14) — the first real health-gate
    execution after the ARC outage. Step 5 "Poll Flux conditions and classify" FAILED with exit 1 and
    step 6 "Emit inconclusive notification" was SKIPPED, along with the entire revert path (steps
    7-13). The gate did nothing at all: no revert, no notification, merge unwatched. Fail-SILENT, not
    fail-closed.
    MECHANISM (same defect class as commit 3f26bb5f, which fixed it in the revert step but left the
    poll step untouched — its own diff comment even references "same class of gap"):
    health-gate.yaml:95 sets `set -uo pipefail` WITHOUT -e, but GitHub invokes the step shell as
    `/usr/bin/bash -e {0}`, so -e is active regardless (the file acknowledges this at line 327). The
    poll loop then does `RAW_OUTPUT=$(kubectl get ... )` followed by `KCTL_STATUS=$?`; under -e the
    failed command substitution exits the shell IMMEDIATELY, so `KCTL_STATUS=$?` and the entire
    guard below it — including its `echo "WARNING: kubectl poll failed..."` — never execute. With no
    `outcome=` written to $GITHUB_OUTPUT, step 6's `if: outcome == 'inconclusive'` is false and the
    notification is skipped.
    EVIDENCE: step ran 07:12:07Z -> 07:16:07Z = exactly 240s, i.e. ~8 polls at POLL_INTERVAL 30s,
    far short of WINDOW_SECONDS 900 — so it did NOT reach the window end; a kubectl call failed
    mid-window. The step emitted ZERO stdout (no WARNING line, no `outcome=`), which is only possible
    if the guard never ran.
    SEVERITY RATIONALE: strictly worse than CR-01. CR-01 could produce a false "healthy" verdict;
    this kills the step before any classification happens, so a single transient API blip disables
    the entire safety net silently. Phase 6 (auto-merge go-live) would be building on a gate that
    can vanish without a trace.
    FIX SHAPE: convert the bare-command-then-$? pattern to `if kubectl ...; then ... else ... fi`
    (exempt from -e), exactly as 3f26bb5f did for git revert/rebase. Audit every other
    bare-command-then-$? site in health-gate.yaml and exclusion-gate.yaml for the same class.
  severity: blocker
  test: n/a (found during live operation, not a scripted UAT test)
  artifacts: []
  missing: []

- gap_id: G-05-1
  truth: "A notification (not just a log line) fires through existing in-cluster alerting infra on every induced revert, reusing the same channel (ROADMAP Phase 5 success criterion 5; HEALTH-04/AUDIT-02)."
  status: failed
  reason: "User reported: only 1 of 3 genuine HealthGateAutoRevert notifications reached #k8s-alerts (health-gate-revert-31165238337 present; -31164977487 and -31170706760 absent). Runner-log correlation shows Slack API activity only in cycle 2's window, and none at all in cycles 1 and 3 — so Robusta never processed those two Events. Notification delivery is unreliable (~33% observed), not merely attachment-degraded."
  severity: major
  test: 1
  artifacts: []
  missing: []
