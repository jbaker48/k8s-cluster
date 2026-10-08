---
schema_version: 1
open_count: 8
waived_count: 1
fixed_count: 5
total_count: 14
last_updated: 2026-08-19T11:17:04.102Z
---

# Broken Windows Ledger

> Cross-phase defect register. With `workflow.windows_enforce` enabled, `/gsd-ship` blocks while `open_count > 0`.
> Waive with `gsd-tools windows waive <id> "<reason>"` (reason required).
> Mark fixed with `gsd-tools windows fixed <id>`.

| id | phase | kind | file | line | description | status | reason | recorded_at | resolved_at |
|----|-------|------|------|------|-------------|--------|--------|-------------|-------------|
| 1 | 05 | unrun-verify | .github/workflows/test-health-gate-rbac.yaml |  | Live workflow_dispatch run blocked by GitHub Actions platform-wide outage (major_outage, incident qcvjkzcs7j74, since 2026-08-06T15:22Z) - two dispatch attempts (31128442523, 31128637283) both stuck queued/cancelled; underlying credential/RBAC boundary independently proven live via direct kubectl calls using the identical kubeconfig, but the in-workflow kubectl-bootstrap + dispatch path itself remains unproven end-to-end. Re-run once GitHub Actions recovers. | fixed |  | 2026-08-06T22:25:39.541Z | 2026-08-07T02:46:08.720Z |
| 2 | 05 | unrun-verify | .github/workflows/exclusion-gate.yaml |  | Plan 05-05 Task 2 Test 3: notify-exclusion job's HardExclusionBlocked Kubernetes Event could not be live-confirmed — k8s-cluster-ci ARC runner had no active listener during an ongoing external GitHub Actions outage (started 2026-08-06T15:22:49Z). PR #1079 left open pending re-verification once ARC/GitHub Actions recovers. | fixed |  | 2026-08-06T23:36:14.772Z | 2026-08-07T02:46:50.173Z |
| 3 | 05 | unmet-truth | kubernetes/apps/observability/robusta/app/helmrelease.yaml |  | Robusta Slack sender hit missing_scope (files:write) when processing a live HealthGateInconclusive event (run 31148364888, 2026-08-07T04:46:37Z) - files.getUploadURLExternal failed, so the notification's file/snippet attachment (event_resource_events action) may not have fully reached #k8s-alerts even though 05-03 previously human-confirmed basic text delivery works. Slack App OAuth scope needs files:write added; not fixed here (out of scope for 05-06, which only touches health-gate.yaml). | open |  | 2026-08-07T04:48:53.617Z |  |
| 4 | 05 | unmet-truth | .github/workflows/health-gate.yaml |  | Race condition: a push-triggered health-gate poll can fire before Flux begins reconciling the new commit, catching stale Stalled/RetriesExceeded state left over from a prior, already-resolved commit and misattributing the revert to the wrong (just-pushed) commit. Observed live during Plan 05-07: cleanup commit 09c2c0d2 (restoring bazarr) was reverted by mistake via real PR #1081 because the poll's first iteration ran ~15s after push, before Flux's observedGeneration caught up. Likely fix: poll step should wait for HelmRelease/Kustomization .status.observedGeneration to match .metadata.generation before trusting Ready/Stalled conditions. Not fixed in Plan 05-06/05-07 (architecture-level change, out of scope for a targeted fix); mitigated for now by manually resetting state before starting clean induced-failure cycles. | open |  | 2026-08-07T08:34:43.776Z |  |
| 5 | 05 | deviation | .github/workflows/health-gate.yaml |  | Bucket-resolution step used github.event.before (only populated for push events) as BEFORE_SHA; empty on workflow_dispatch re-dispatches (used throughout Plan 05-07 to work around window-boundary timing), causing 'git diff' to hard-fail via set -euo pipefail and violating Plan 05-06's own must-have that revert is never gated on bucket resolution. Fixed in commit 8fb2cf5b: falls back to AFTER_SHA~1 when BEFORE_SHA is empty. Live-verified working across Plan 05-07's cycles 1-3. | fixed |  | 2026-08-07T10:42:08.222Z | 2026-08-07T10:42:12.167Z |
| 6 | 05 | unrun-verify | .github/workflows/health-gate.yaml |  | Code-review critical fixes (05-REVIEW.md CR-01/CR-02/CR-03, commits 2477e4b5/21c299d1) were verified by inspection and jq/bash logic testing only, not re-exercised against real infrastructure. CR-01 (empty-Flux-list fail-open) needs a live poll iteration hitting a genuinely empty kubectl response to prove the fix. CR-02 (unscoped bucket) needs a real non-app-path PR against a paused unscoped bucket. CR-03 (bypass identity check) needs a real PR from the actual revert-bot App to confirm the added PR_AUTHOR_LOGIN/TYPE check doesn't accidentally block legitimate reverts, plus ideally a negative-proof attempt from a non-bot identity. Re-verify opportunistically during Phase 6 (auto-merge go-live), which depends on this same mechanism. | fixed |  | 2026-08-07T10:59:52.546Z | 2026-08-07T11:10:45.190Z |
| 7 | 05 | deviation | .github/workflows/health-gate.yaml |  | Phase verification found a live-crashed health-gate run (31170751825, triggered by revert PR #1084's own merge commit landing on main): git revert failed with 'commit is a merge but no -m option was given' (any merge-commit push, including every revert-bot self-merge, is unrevertable without -m), and the step's own abort+notify+exit safety net never executed because GitHub Actions' default bash -e step shell is not disabled by set -uo pipefail (a bare 'cmd; STATUS=$?' pattern aborts the step before the second line runs). Fixed in commit 3f26bb5f: detect parent count and pass -m 1 for merge commits; switch to if/else pattern (exempt from -e) for both this step and the sibling retry-once rebase step (WR-02). Verified by direct simulation against real repo commits and isolated -e reproduction, not yet re-exercised live end-to-end. | fixed |  | 2026-08-07T11:10:45.282Z | 2026-08-07T11:28:37.797Z |
| 8 | 05 | unrun-verify | .github/workflows/temp-cr03-bypass-positive-test.yaml |  | Quick task 260812-oje scaffolded four live-validation harnesses for 05-REVIEW.md CR-01/CR-02/CR-03, but NONE have been run: dispatching them is left to the user by design. Ledger entry #6 is marked 'fixed' even though its own description lists live verification that never happened (empty-Flux-list poll, non-app-path PR against a paused unscoped bucket, real revert-bot App PR) - this entry tracks the still-outstanding proof. Harnesses: test-health-gate-rbac.yaml CR-01 step (dispatch), temp-cr03-bypass-positive-test.yaml (dispatch), RUNBOOK-CR03-bypass-forgery.md (manual), RUNBOOK-CR02-circuit-breaker.md (manual). Highest risk is CR-03's positive path: real revert PRs #1082-#1084 predate 21c299d1, so nothing yet proves a legitimate bot revert still bypasses the exclusion gate. | open |  | 2026-08-12T08:03:45.823Z |  |
| 9 | 05 | todo | .github/workflows/temp-cr03-bypass-positive-test.yaml |  | Throwaway test workflow created by quick task 260812-oje must be DELETED once Phase 05 verification closes. It is workflow_dispatch-only and cannot merge anything, but it mints a revert-bot App installation token with write scope and opens a real PR, so it should not outlive its purpose. | waived | Retired, not completed: the temp workflow this reminder tracked was deleted in commit 94269438 (workflow_dispatch requires the file on the default branch, so it could never run without merging a throwaway test workflow into main). Replaced by an untracked local script that needs no merge, so there is no longer any file to delete. | 2026-08-12T08:03:52.516Z | 2026-08-12T09:41:03.494Z |
| 10 | 05 | unrun-verify | .github/workflows/test-health-gate-rbac.yaml |  | CR-01 dispatch trap: run 31583783942 (2026-08-12T09:37:50Z, workflow_dispatch) was dispatched against main (sha 767a4871), whose copy of test-health-gate-rbac.yaml has only the original 5 steps and NO CR-01 assertion - a dispatch executes that ref's version of the workflow file. That run therefore cannot produce a CR-01 verdict regardless of outcome and must be disregarded. A valid CR-01 run requires pushing chore/phase-05-validation-harnesses and dispatching with --ref chore/phase-05-validation-harnesses; confirm correctness by step list (6 steps, last named 'CR-01 regression assertion - genuinely empty Flux list must never classify as healthy'), not by run colour. Documented in both runbooks' Dispatch mechanics section. | open |  | 2026-08-12T09:50:52.029Z |  |
| 11 | 05 | deviation | .github/workflows/exclusion-gate.yaml |  | exclusion-gate.yaml has no failure-conditioned backstop, the mirror of health-gate's new one (commit 6860c787). If the exclusion-check job dies, its outputs are empty, so notify-exclusion silently skips and no HardExclusionBlocked event is emitted. The PR check does go red, which may be sufficient operator signal given a human is reviewing that PR anyway - deliberately left as a design decision, not fixed in quick task 260814-qee. | open |  | 2026-08-14T09:23:35.120Z |  |
| 12 | quick-260814-rnf | stub | kubernetes/apps/tools/claude-code/app/helmrelease.yaml | 45 | image.tag is 'latest' because ghcr.io/jbaker48/claude-code does not exist until the containers repo feat/claude-code branch is merged and the first GHCR build publishes. Must be pinned to the published <version>-<sha> tag before this app is trusted; 'latest' silently defeats GitOps reproducibility. Documented in the app README section 3. | open |  | 2026-08-14T10:21:04.351Z |  |
| 13 | quick-260819-t19 | deviation | .github/workflows/exclusion-gate.yaml |  | notify-exclusion job fails: ARC runner (k8s-cluster-ci) cannot reach the Kubernetes API VIP 10.20.0.250:6443 (i/o timeout) so the HardExclusionBlocked Event is never created — no Robusta/Slack notification on hard exclusion; health-gate.yaml shares the same runner+VIP. Observed on run 32245969899 (260819-t19 V-1). Not investigated. | open |  | 2026-08-19T11:16:58.581Z |  |
| 14 | quick-260819-t19 | unrun-verify | .planning/quick/260814-qee-fix-g-05-2-health-gate-poll-step-fail-si/260814-qee-SUMMARY.md |  | Health-gate live checks V-4 through V-8 (260814-qee SUMMARY section 5) remain un-run; 260819-t19 covered only V-1 and V-2 (exclusion-gate side). | open |  | 2026-08-19T11:17:04.102Z |  |

````json
[
  {
    "id": 1,
    "kind": "unrun-verify",
    "phase": "05",
    "file": ".github/workflows/test-health-gate-rbac.yaml",
    "line": null,
    "description": "Live workflow_dispatch run blocked by GitHub Actions platform-wide outage (major_outage, incident qcvjkzcs7j74, since 2026-08-06T15:22Z) - two dispatch attempts (31128442523, 31128637283) both stuck queued/cancelled; underlying credential/RBAC boundary independently proven live via direct kubectl calls using the identical kubeconfig, but the in-workflow kubectl-bootstrap + dispatch path itself remains unproven end-to-end. Re-run once GitHub Actions recovers.",
    "status": "fixed",
    "reason": "",
    "recorded_at": "2026-08-06T22:25:39.541Z",
    "resolved_at": "2026-08-07T02:46:08.720Z"
  },
  {
    "id": 2,
    "kind": "unrun-verify",
    "phase": "05",
    "file": ".github/workflows/exclusion-gate.yaml",
    "line": null,
    "description": "Plan 05-05 Task 2 Test 3: notify-exclusion job's HardExclusionBlocked Kubernetes Event could not be live-confirmed — k8s-cluster-ci ARC runner had no active listener during an ongoing external GitHub Actions outage (started 2026-08-06T15:22:49Z). PR #1079 left open pending re-verification once ARC/GitHub Actions recovers.",
    "status": "fixed",
    "reason": "",
    "recorded_at": "2026-08-06T23:36:14.772Z",
    "resolved_at": "2026-08-07T02:46:50.173Z"
  },
  {
    "id": 3,
    "kind": "unmet-truth",
    "phase": "05",
    "file": "kubernetes/apps/observability/robusta/app/helmrelease.yaml",
    "line": null,
    "description": "Robusta Slack sender hit missing_scope (files:write) when processing a live HealthGateInconclusive event (run 31148364888, 2026-08-07T04:46:37Z) - files.getUploadURLExternal failed, so the notification's file/snippet attachment (event_resource_events action) may not have fully reached #k8s-alerts even though 05-03 previously human-confirmed basic text delivery works. Slack App OAuth scope needs files:write added; not fixed here (out of scope for 05-06, which only touches health-gate.yaml).",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-07T04:48:53.617Z",
    "resolved_at": null
  },
  {
    "id": 4,
    "kind": "unmet-truth",
    "phase": "05",
    "file": ".github/workflows/health-gate.yaml",
    "line": null,
    "description": "Race condition: a push-triggered health-gate poll can fire before Flux begins reconciling the new commit, catching stale Stalled/RetriesExceeded state left over from a prior, already-resolved commit and misattributing the revert to the wrong (just-pushed) commit. Observed live during Plan 05-07: cleanup commit 09c2c0d2 (restoring bazarr) was reverted by mistake via real PR #1081 because the poll's first iteration ran ~15s after push, before Flux's observedGeneration caught up. Likely fix: poll step should wait for HelmRelease/Kustomization .status.observedGeneration to match .metadata.generation before trusting Ready/Stalled conditions. Not fixed in Plan 05-06/05-07 (architecture-level change, out of scope for a targeted fix); mitigated for now by manually resetting state before starting clean induced-failure cycles.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-07T08:34:43.776Z",
    "resolved_at": null
  },
  {
    "id": 5,
    "kind": "deviation",
    "phase": "05",
    "file": ".github/workflows/health-gate.yaml",
    "line": null,
    "description": "Bucket-resolution step used github.event.before (only populated for push events) as BEFORE_SHA; empty on workflow_dispatch re-dispatches (used throughout Plan 05-07 to work around window-boundary timing), causing 'git diff' to hard-fail via set -euo pipefail and violating Plan 05-06's own must-have that revert is never gated on bucket resolution. Fixed in commit 8fb2cf5b: falls back to AFTER_SHA~1 when BEFORE_SHA is empty. Live-verified working across Plan 05-07's cycles 1-3.",
    "status": "fixed",
    "reason": "",
    "recorded_at": "2026-08-07T10:42:08.222Z",
    "resolved_at": "2026-08-07T10:42:12.167Z"
  },
  {
    "id": 6,
    "kind": "unrun-verify",
    "phase": "05",
    "file": ".github/workflows/health-gate.yaml",
    "line": null,
    "description": "Code-review critical fixes (05-REVIEW.md CR-01/CR-02/CR-03, commits 2477e4b5/21c299d1) were verified by inspection and jq/bash logic testing only, not re-exercised against real infrastructure. CR-01 (empty-Flux-list fail-open) needs a live poll iteration hitting a genuinely empty kubectl response to prove the fix. CR-02 (unscoped bucket) needs a real non-app-path PR against a paused unscoped bucket. CR-03 (bypass identity check) needs a real PR from the actual revert-bot App to confirm the added PR_AUTHOR_LOGIN/TYPE check doesn't accidentally block legitimate reverts, plus ideally a negative-proof attempt from a non-bot identity. Re-verify opportunistically during Phase 6 (auto-merge go-live), which depends on this same mechanism.",
    "status": "fixed",
    "reason": "",
    "recorded_at": "2026-08-07T10:59:52.546Z",
    "resolved_at": "2026-08-07T11:10:45.190Z"
  },
  {
    "id": 7,
    "kind": "deviation",
    "phase": "05",
    "file": ".github/workflows/health-gate.yaml",
    "line": null,
    "description": "Phase verification found a live-crashed health-gate run (31170751825, triggered by revert PR #1084's own merge commit landing on main): git revert failed with 'commit is a merge but no -m option was given' (any merge-commit push, including every revert-bot self-merge, is unrevertable without -m), and the step's own abort+notify+exit safety net never executed because GitHub Actions' default bash -e step shell is not disabled by set -uo pipefail (a bare 'cmd; STATUS=$?' pattern aborts the step before the second line runs). Fixed in commit 3f26bb5f: detect parent count and pass -m 1 for merge commits; switch to if/else pattern (exempt from -e) for both this step and the sibling retry-once rebase step (WR-02). Verified by direct simulation against real repo commits and isolated -e reproduction, not yet re-exercised live end-to-end.",
    "status": "fixed",
    "reason": "",
    "recorded_at": "2026-08-07T11:10:45.282Z",
    "resolved_at": "2026-08-07T11:28:37.797Z"
  },
  {
    "id": 8,
    "kind": "unrun-verify",
    "phase": "05",
    "file": ".github/workflows/temp-cr03-bypass-positive-test.yaml",
    "line": null,
    "description": "Quick task 260812-oje scaffolded four live-validation harnesses for 05-REVIEW.md CR-01/CR-02/CR-03, but NONE have been run: dispatching them is left to the user by design. Ledger entry #6 is marked 'fixed' even though its own description lists live verification that never happened (empty-Flux-list poll, non-app-path PR against a paused unscoped bucket, real revert-bot App PR) - this entry tracks the still-outstanding proof. Harnesses: test-health-gate-rbac.yaml CR-01 step (dispatch), temp-cr03-bypass-positive-test.yaml (dispatch), RUNBOOK-CR03-bypass-forgery.md (manual), RUNBOOK-CR02-circuit-breaker.md (manual). Highest risk is CR-03's positive path: real revert PRs #1082-#1084 predate 21c299d1, so nothing yet proves a legitimate bot revert still bypasses the exclusion gate.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-12T08:03:45.823Z",
    "resolved_at": null
  },
  {
    "id": 9,
    "kind": "todo",
    "phase": "05",
    "file": ".github/workflows/temp-cr03-bypass-positive-test.yaml",
    "line": null,
    "description": "Throwaway test workflow created by quick task 260812-oje must be DELETED once Phase 05 verification closes. It is workflow_dispatch-only and cannot merge anything, but it mints a revert-bot App installation token with write scope and opens a real PR, so it should not outlive its purpose.",
    "status": "waived",
    "reason": "Retired, not completed: the temp workflow this reminder tracked was deleted in commit 94269438 (workflow_dispatch requires the file on the default branch, so it could never run without merging a throwaway test workflow into main). Replaced by an untracked local script that needs no merge, so there is no longer any file to delete.",
    "recorded_at": "2026-08-12T08:03:52.516Z",
    "resolved_at": "2026-08-12T09:41:03.494Z"
  },
  {
    "id": 10,
    "kind": "unrun-verify",
    "phase": "05",
    "file": ".github/workflows/test-health-gate-rbac.yaml",
    "line": null,
    "description": "CR-01 dispatch trap: run 31583783942 (2026-08-12T09:37:50Z, workflow_dispatch) was dispatched against main (sha 767a4871), whose copy of test-health-gate-rbac.yaml has only the original 5 steps and NO CR-01 assertion - a dispatch executes that ref's version of the workflow file. That run therefore cannot produce a CR-01 verdict regardless of outcome and must be disregarded. A valid CR-01 run requires pushing chore/phase-05-validation-harnesses and dispatching with --ref chore/phase-05-validation-harnesses; confirm correctness by step list (6 steps, last named 'CR-01 regression assertion - genuinely empty Flux list must never classify as healthy'), not by run colour. Documented in both runbooks' Dispatch mechanics section.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-12T09:50:52.029Z",
    "resolved_at": null
  },
  {
    "id": 11,
    "kind": "deviation",
    "phase": "05",
    "file": ".github/workflows/exclusion-gate.yaml",
    "line": null,
    "description": "exclusion-gate.yaml has no failure-conditioned backstop, the mirror of health-gate's new one (commit 6860c787). If the exclusion-check job dies, its outputs are empty, so notify-exclusion silently skips and no HardExclusionBlocked event is emitted. The PR check does go red, which may be sufficient operator signal given a human is reviewing that PR anyway - deliberately left as a design decision, not fixed in quick task 260814-qee.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-14T09:23:35.120Z",
    "resolved_at": null
  },
  {
    "id": 12,
    "kind": "stub",
    "phase": "quick-260814-rnf",
    "file": "kubernetes/apps/tools/claude-code/app/helmrelease.yaml",
    "line": 45,
    "description": "image.tag is 'latest' because ghcr.io/jbaker48/claude-code does not exist until the containers repo feat/claude-code branch is merged and the first GHCR build publishes. Must be pinned to the published <version>-<sha> tag before this app is trusted; 'latest' silently defeats GitOps reproducibility. Documented in the app README section 3.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-14T10:21:04.351Z",
    "resolved_at": null
  },
  {
    "id": 13,
    "kind": "deviation",
    "phase": "quick-260819-t19",
    "file": ".github/workflows/exclusion-gate.yaml",
    "line": null,
    "description": "notify-exclusion job fails: ARC runner (k8s-cluster-ci) cannot reach the Kubernetes API VIP 10.20.0.250:6443 (i/o timeout) so the HardExclusionBlocked Event is never created — no Robusta/Slack notification on hard exclusion; health-gate.yaml shares the same runner+VIP. Observed on run 32245969899 (260819-t19 V-1). Not investigated.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-19T11:16:58.581Z",
    "resolved_at": null
  },
  {
    "id": 14,
    "kind": "unrun-verify",
    "phase": "quick-260819-t19",
    "file": ".planning/quick/260814-qee-fix-g-05-2-health-gate-poll-step-fail-si/260814-qee-SUMMARY.md",
    "line": null,
    "description": "Health-gate live checks V-4 through V-8 (260814-qee SUMMARY section 5) remain un-run; 260819-t19 covered only V-1 and V-2 (exclusion-gate side).",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-19T11:17:04.102Z",
    "resolved_at": null
  }
]
````
