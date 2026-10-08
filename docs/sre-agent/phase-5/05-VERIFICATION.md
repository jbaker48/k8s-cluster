---
phase: 05-post-merge-health-gate-auto-revert
verified: 2026-08-07T11:05:27Z
updated: 2026-08-07T11:30:00Z
status: human_needed
score: 6/6 must-haves verified (code-complete; 3 items pending live/human re-verification, see human_verification)
behavior_unverified: 0
overrides_applied: 0
gaps: []
gaps_resolved:
  - truth: "A git revert --no-edit failure (merge conflict / structural failure against a fast-moving main) runs git revert --abort, emits a HealthGateRevertFailed Kubernetes Event describing the conflict, and fails the job with a non-zero exit — never silently producing a broken or partial revert PR (05-06-PLAN.md must-have, HEALTH-03 unclassified case)."
    original_status: failed
    fix_commit: 3f26bb5f
    fix_summary: "Detects merge commits (parent count > 1) and passes -m 1 to git revert (fixes the specific crash from run 31170751825, reverting revert-PR #1084's own merge commit). Switches the git revert call, and the sibling retry-once git rebase call, from a bare-command-then-$? pattern to if/else, which is exempt from GitHub Actions' inherited `bash -e` step shell — the actual root cause of the abort/notify/exit-1 code never executing."
    verification: "Logic verified: parent-count detection tested against the real repo's commit objects (922e5054=2 parents, 229a9ea6=1 parent); if/else exemption from `set -e` early-exit confirmed via isolated bash reproduction. NOT yet re-exercised live end-to-end (no real git-revert failure has occurred since this fix). Tracked as WINDOWS.md #7 (open, unrun-verify)."
human_verification:
  - test: "Confirm in Slack #k8s-alerts that the 3 genuine HealthGateAutoRevert notifications from Plan 05-07 (runs health-gate-revert-31164977487, -31165238337, -31170706760) actually displayed for a human, not just that the underlying K8s Event exists."
    expected: "All 3 events visible in #k8s-alerts with correct content (matches the pattern already human-confirmed for 05-03's synthetic events)."
    why_human: "Slack delivery cannot be observed by the verifier; robusta-runner log inspection for cycle 1 was inconclusive per 05-07-SUMMARY.md, and this is explicitly flagged as an outstanding item in that SUMMARY."
  - test: "Re-exercise CR-01/CR-02/CR-03 (05-REVIEW.md, fixed in commits 2477e4b5 and 21c299d1) against real infrastructure, not just static/jq-logic inspection: (1) a live poll iteration hitting a genuinely empty kubectl Flux-resource response, (2) a real non-app-path PR against a paused `unscoped` circuit-breaker bucket, (3) a real PR from the actual revert-bot App confirming the new PR_AUTHOR_LOGIN/TYPE check doesn't block legitimate reverts, plus a negative-proof attempt from a non-bot identity."
    expected: "CR-01: empty list never classifies healthy. CR-02: paused unscoped bucket blocks a non-app-path PR. CR-03: only true revert-bot-App-authored PRs bypass; a forged branch+label PR from another identity does NOT bypass."
    why_human: "Logged as WINDOWS.md #6 (unrun-verify, open) by the executor itself — code was read and confirmed present/syntactically correct in this verification pass (see Code Review Fixes below), but the 3 checks require live PRs/API states the verifier should not fabricate against production infrastructure without a deliberate, supervised test cycle like Plan 05-07's."
---

# Phase 5: Post-Merge Health-Gate & Auto-Revert Verification Report

**Phase Goal:** Cluster health is watched after any merge to `main`, and a genuinely unhealthy outcome is automatically reverted — proven against a deliberately induced failure before it's ever asked to backstop a real AI-driven auto-merge.
**Verified:** 2026-08-07T11:05:27Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Health-gate polls Flux Kustomization/HelmRelease Ready/Stalled conditions across the cluster for a bounded window after every merge | ✓ VERIFIED | `.github/workflows/health-gate.yaml` push trigger has no `paths:` filter (lines 11-13); poll loop (lines 92-165) uses a single jq pass over `kustomizations...,helmreleases...  -A`. Live: multiple real runs (31141292338, 31148789002, 31163304575, and all of Plan 05-07's cycles) confirm the poll executes on every push to `main`. |
| 2 | A deliberately induced real HelmRelease failure is detected unhealthy within the window and triggers an automatic git revert + push to main — proven end-to-end on real infra | ✓ VERIFIED | Live-reproduced 3 full cycles this session's history (05-07): commit `229a9ea6`→run `31164977487`→PR #1082 merged; `4e9efd93`→run `31165238337`→PR #1083 merged; `e961a7e5`→run `31170706760`→PR #1084 merged. `kubectl get helmrelease -n media bazarr` confirms `Ready:True`/`UpgradeSucceeded` at the original `1.5.4` tag right now — cluster state is clean and consistent with the SUMMARY's claims, independently re-confirmed live during this verification. |
| 3 | A deliberately induced transient/ambiguous signal produces "inconclusive" and notifies a human instead of reverting | ✓ VERIFIED | 4+ live runs classified inconclusive with zero revert action taken (31148789002, 31149746298-blocked-by-then-broken-token/not-a-false-revert, 31155402462, 31163304575) plus 05-06's dedicated `window_override_seconds=5` proof (run 31148364888). `HealthGateInconclusive` events currently exist in the cluster (`kubectl get events`) for recent runs, confirming the notification path fires. |
| 4 | After N reverts within a window for the same path/app, auto-merge is paused for that path/app until human re-enable — verified by inducing repeated failures | ✓ VERIFIED | Live: 3rd real revert (`e961a7e5`, run 31170706760) set `media/bazarr.paused:true` in the SAME commit as the 3rd revert timestamp. Throwaway PR #1085 touching `media/bazarr/**` got `gate/human-required` + circuit-breaker-specific comment. PR #1086 (normal merge, `paused:false`) genuinely re-enabled the bucket — throwaway PR #1087 confirmed clean (no gate label). `circuit-breaker-state.json` is currently `{}` on disk (cleaned up), consistent with the SUMMARY's claimed end state. |
| 5 | A notification fires through existing in-cluster alerting infra on the induced revert and on a hard-exclusion event, reusing the same channel | ⚠️ SEE HUMAN VERIFICATION | K8s Events for all 3 of this session's genuine `HealthGateAutoRevert` reverts are confirmed to exist (`kubectl get events`). Robusta's `customPlaybooks` route the exact 4 locked reason strings (`HealthGateAutoRevert`, `HealthGateInconclusive`, `HealthGateRevertFailed`, `HardExclusionBlocked`) to `main_slack_sink` (confirmed present in `robusta/app/helmrelease.yaml`), and this mechanism was human-eyes-on confirmed working for 4 synthetic test events in Plan 05-03 (screenshot evidence). **However**, the 3 specific genuine `HealthGateAutoRevert` notifications from Plan 05-07 have NOT been independently confirmed reaching #k8s-alerts by a human — SUMMARY explicitly flags this as outstanding, and robusta-runner log inspection for cycle 1 was inconclusive. Routed to Human Verification below. |

**Score:** 5/6 must-haves verified (4 of 5 roadmap Success Criteria cleanly verified with live evidence; SC5 partially verified pending human Slack confirmation; 1 additional plan-level must-have — the revert-failure notification path — found FAILED via live evidence gathered during this verification).

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `kubernetes/apps/arc-runners/k8s-cluster-ci/app/rbac.yaml` | health-gate ServiceAccount + least-privilege ClusterRole/Binding | ✓ VERIFIED | `kubectl get sa health-gate -n arc-runners` and `kubectl get clusterrole health-gate-reader` both exist live. |
| `.github/workflows/test-health-gate-rbac.yaml` | Standing RBAC-verification workflow | ✓ VERIFIED | Live dispatched run `31135883767` completed with `conclusion:success` (closes WINDOWS.md #1). |
| `.github/health-gate/circuit-breaker-state.json` | Committed git-native circuit-breaker state store | ✓ VERIFIED | Exists, currently `{}` (clean post-test state), matches D-06 design. |
| `.github/labels.yaml` → `automated-revert` label | Real synced repository label | ✓ VERIFIED | `gh label list` confirms `automated-revert` exists live with correct description. |
| `kubernetes/apps/observability/robusta/app/helmrelease.yaml` | `customPlaybooks` routing the 4 locked reason strings to Slack | ✓ VERIFIED | `customPlaybooks` block present with all 4 reason strings (`HealthGateAutoRevert`, `HealthGateInconclusive`, `HealthGateRevertFailed`, `HardExclusionBlocked`), `main_slack_sink` referenced. |
| `.github/workflows/health-gate.yaml` | Push-triggered poll/classify/revert/notify workflow | ✓ VERIFIED (with 1 gap) | Poll/classify/inconclusive/revert/circuit-breaker/PR-merge logic all present and wired. CR-01 fix (empty-list fail-open) confirmed present in code (`(.items | length > 0) and (...)`, line 132). One live-discovered gap in the revert-conflict-handling step (see Gaps). |
| `.github/workflows/exclusion-gate.yaml` | Bypass check, circuit-breaker read-side, notify-exclusion job | ✓ VERIFIED | CR-02 fix (`unscoped` fallback, lines 160-165) and CR-03 fix (`PR_AUTHOR_TYPE`/`PR_AUTHOR_LOGIN` bot-identity check, lines 34-35, 46-52) both confirmed present in code, matching 05-REVIEW.md's prescribed fixes exactly. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| `health-gate.yaml` (unhealthy branch) | Revert-bot App credential | `actions/create-github-app-token` exchange | ✓ WIRED | Confirmed present at line 264-270; live-proven across all 3 genuine 05-07 cycles. |
| `health-gate.yaml` (revert PR branch) | `exclusion-gate.yaml` bypass check | `auto-revert/` prefix + `automated-revert` label + bot-identity check | ✓ WIRED | Live-proven: revert-bot's own PRs (#1082-1084) bypassed exclusion-gate cleanly; the CR-03 identity tightening (`k8s-cluster-revert-bot[bot]`, `type:Bot`) is present in both files consistently (`APP_SLUG` output from `create-github-app-token` matches the check). |
| `health-gate.yaml` (circuit-breaker write) | `circuit-breaker-state.json` | Dedicated commit on revert branch | ✓ WIRED | Live-proven: 3 genuine reverts wrote 3 timestamps + `paused:true` in the correct commit. |
| `exclusion-gate.yaml` (circuit-breaker check) | `circuit-breaker-state.json` (read-only) | `gh api contents` at PR base SHA | ✓ WIRED | Live-proven: throwaway PR #1085 correctly blocked while paused; #1087 correctly unblocked after re-enable. |
| Kubernetes `Event` objects (4 reason strings) | Robusta `customPlaybooks` → `main_slack_sink` | text-match on `reason` field | ✓ WIRED (text notifications proven in 05-03; this session's 3 specific revert events pending human confirmation) | See Human Verification. |

### Behavioral Spot-Checks (Live Infrastructure)

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| RBAC test workflow dispatches and completes | `gh run list --workflow=test-health-gate-rbac.yaml` | Run 31135883767: `completed success` | ✓ PASS |
| Cluster is currently in the clean post-test state SUMMARY claims | `kubectl get helmrelease -n media bazarr`, `cat circuit-breaker-state.json` | `Ready:True`/`UpgradeSucceeded` at tag `1.5.4`; `{}` | ✓ PASS |
| CR-01 fix present in deployed workflow file | `grep 'length > 0'` in `health-gate.yaml` | Present at line 132 | ✓ PASS (static; not re-exercised live — see Human Verification) |
| CR-02/CR-03 fixes present in deployed workflow file | Read `exclusion-gate.yaml` lines 34-52, 160-165 | Both present, match 05-REVIEW.md's prescribed fix exactly | ✓ PASS (static; not re-exercised live — see Human Verification) |
| Revert-conflict notification path actually fires on a real git-revert failure | `kubectl get events -A --field-selector reason=HealthGateRevertFailed` after live-observed failed run 31170751825 | **0 events found** — no `HealthGateRevertFailed` event exists despite a real git revert failure occurring at 2026-08-07T10:36:58Z | ✗ FAIL (see Gaps) |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| HEALTH-01 | 05-01, 05-04 | Post-merge health-gate watches Flux Ready/Stalled across cluster in a bounded window | ✓ SATISFIED | Live poll proven repeatedly; RBAC boundary live-proven (least-privilege read + Forbidden-on-mutate). |
| HEALTH-02 | 05-04, 05-06 | Three-way outcome (healthy/unhealthy/inconclusive); only unhealthy reverts | ✓ SATISFIED | CR-01 fail-open bug fixed (code confirmed); inconclusive path live-proven not to revert, multiple runs. |
| HEALTH-03 | 05-02, 05-05, 05-06 | Auto-revert is `git revert` + push (forward-only), never history rewrite | ✓ SATISFIED (core), ⚠️ GAP (error path) | Forward-only revert confirmed (`--force-with-lease` scoped only to the bot's own disposable branch, never `main`); 3 genuine live reverts all forward-only. **However**, the specific must-have that a revert *failure* notifies loudly is FAILED — see Gaps. |
| HEALTH-04 | 05-05, 05-06, 05-07 | Revert-loop circuit breaker pauses auto-merge after N reverts, requires human re-enable | ✓ SATISFIED | Live-proven both directions (trip + re-enable) against real induced failures, not hand-edited state. |
| AUDIT-02 | 05-01, 05-03, 05-05, 05-07 | Notification (not just log line) sent on every revert and hard-exclusion, reusing existing alerting infra | ✓ SATISFIED (successful revert + hard-exclusion paths), ⚠️ GAP (failed-revert path), ⚠️ HUMAN NEEDED (this session's specific Slack confirmation) | `HealthGateAutoRevert`/`HardExclusionBlocked` K8s Events proven live and Slack-delivered (05-03 screenshot); `HealthGateRevertFailed` proven NOT to fire on a real failure (this verification's finding). |

No orphaned requirements — all 5 of this phase's REQUIREMENTS.md-mapped IDs (HEALTH-01..04, AUDIT-02) appear in at least one plan's `requirements:` frontmatter and are accounted for above.

### Code Review Fixes (05-REVIEW.md CR-01/CR-02/CR-03)

All three critical findings from the code review were re-verified by direct file inspection during this verification pass (not merely trusted from SUMMARY/REVIEW claims):

- **CR-01** (empty Flux list classified healthy): `health-gate.yaml:132` now reads `all_ready: ( (.items | length > 0) and ( [ ... ] | all ) )` — fix confirmed present and correct by direct read.
- **CR-02** (unscoped bucket never checked): `exclusion-gate.yaml:160-165` now mirrors `health-gate.yaml`'s `unscoped` fallback — fix confirmed present and correct by direct read.
- **CR-03** (bypass forgeable): `exclusion-gate.yaml:34-35,46-52` now additionally requires `PR_AUTHOR_TYPE == "Bot"` and `PR_AUTHOR_LOGIN == "k8s-cluster-revert-bot[bot]"` — fix confirmed present and correct by direct read.

Per WINDOWS.md #6 (open, unrun-verify), none of these three fixes have been re-exercised against real infrastructure since being merged (commits `2477e4b5`, `21c299d1`, pushed 2026-08-07T10:59Z — after Plan 05-07 concluded). The code is syntactically and logically correct on inspection, and CR-01/CR-02 are simple, low-risk boolean/jq changes; CR-03 is the highest-value one to actually re-exercise live (an identity check is exactly the kind of thing that silently doesn't match in practice — e.g. App slug casing, `[bot]` suffix). Routed to Human Verification.

### New Finding: Revert-Conflict Notification Path Is Broken (found live during this verification)

While independently checking current live GitHub Actions run history (not merely reading SUMMARY.md), a health-gate run triggered by the push that merged PR #1084 (`31170751825`, 2026-08-07T10:36:28Z) was found with `conclusion: failure`. Investigation of this run's logs revealed:

1. A push-triggered poll (the same class of race documented in WINDOWS.md #4) misclassified the just-merged revert-PR's own merge commit as unhealthy.
2. `health-gate.yaml`'s "git revert, or abort and notify on conflict" step attempted `git revert --no-edit` against that commit — but it is a 2-parent merge commit (created by `gh pr merge --merge`), and `git revert` correctly refused: `error: commit ... is a merge but no -m option was given.` (exit 128).
3. The step's own error-handling code (intended to run `git revert --abort`, emit a `HealthGateRevertFailed` Kubernetes Event, and `exit 1` explicitly) **never executed**. The job died immediately at the failing `git revert` line instead.
4. Root cause: GitHub Actions' default step shell is `bash -e {0}`. The script's `set -uo pipefail` (line 329) — despite the adjacent comment claiming "Deliberately WITHOUT -e" — does not clear the `-e` flag already active from the shell invocation. Any non-zero exit anywhere in the step aborts it immediately, bypassing the explicit `REVERT_STATUS=$?` check and everything after it.
5. Confirmed via `kubectl get events -A --field-selector reason=HealthGateRevertFailed`: **zero matching events exist**, despite this real failure having occurred. No operator-facing signal beyond a generic Actions job failure was produced — the exact "silent failure" this must-have exists to prevent.

Cluster state was not left broken (bazarr is `Ready:True` at the correct tag, `circuit-breaker-state.json` is untouched/`{}`), so this did not cause a safety incident this time — but it does mean that if `git revert` genuinely fails (a real merge conflict, or any other structural failure) in production, the safety-net notification will not fire, silently defeating part of AUDIT-02 and HEALTH-03's literal "never silently" wording.

This is closely related to, but distinct from, the already-documented and accepted WINDOWS.md #4 (push/reconciliation race causing a wrong commit to be targeted) — that item does not mention or cover the fact that the fail-loud notification path is itself non-functional. Recommend logging a new WINDOWS.md entry and fixing before Phase 6 (auto-merge go-live) begins relying on this mechanism, since Phase 6 explicitly depends on this exact health-gate/revert machinery per WINDOWS.md #6's own note.

### Anti-Patterns Found

No debt markers (`TBD`/`FIXME`/`XXX`/`TODO`/`HACK`/`PLACEHOLDER`) found in `health-gate.yaml` or `exclusion-gate.yaml`. The 7 non-critical warnings from 05-REVIEW.md (WR-01 through WR-07 — mutable-tag action pins, unbounded `reverts` array growth, unquoted heredoc interpolation, unchecked `window_override_seconds` arithmetic, Holmes/Robusta RBAC review, Robusta empty `account_id`/`signing_key`) remain open and non-blocking, consistent with 05-REVIEW.md's own classification; not re-litigated here as none of them contradict a must-have or roadmap success criterion.

### Human Verification Required

1. **Slack confirmation of Plan 05-07's 3 genuine `HealthGateAutoRevert` notifications**
   - **Test:** Check #k8s-alerts for the three notifications corresponding to runs `31164977487`, `31165238337`, `31170706760`.
   - **Expected:** All 3 visible with correct content, matching the pattern already confirmed for 05-03's synthetic test events.
   - **Why human:** Slack delivery cannot be observed programmatically by the verifier; robusta-runner log inspection was inconclusive per 05-07-SUMMARY.md.

2. **Live re-exercise of CR-01/CR-02/CR-03 fixes**
   - **Test:** (a) Force a poll iteration against a genuinely empty Flux resource list; (b) submit a real PR touching a non-`kubernetes/apps/` path while the `unscoped` bucket is paused; (c) submit a real PR from the actual revert-bot App identity and confirm it bypasses, then attempt a forged branch+label PR from a different identity and confirm it does NOT bypass.
   - **Expected:** CR-01/CR-02/CR-03 behave exactly as the fix commits intend.
   - **Why human:** Logged as WINDOWS.md #6 (open); code is confirmed present and correct on inspection, but deliberately manufacturing these 3 live production scenarios (especially the negative-identity-forgery proof) needs a supervised test cycle, not something this verifier should improvise against live infrastructure.

3. **Re-verify the revert-conflict notification gap fix (fixed post-verification, commit `3f26bb5f`)**
   - **Test:** Deliberately trigger a `git revert` failure (e.g. revert a merge commit, or a genuine textual conflict) and confirm a `HealthGateRevertFailed` Kubernetes Event is created and the job still fails with non-zero exit.
   - **Expected:** Event created, Slack notification received, job fails — matching the must-have's literal wording.
   - **Why human:** The code fix is applied and logic-verified (merge-commit parent-count detection tested against real commits; if/else `-e`-exemption confirmed via isolated reproduction), but not yet re-exercised against a real live failure. Tracked as WINDOWS.md #7 (open).

### Gaps Summary

The core Phase 5 mechanism — poll, classify, revert, circuit-breaker trip, human re-enable — is proven live and working end-to-end against real, deliberately induced failures, repeated 3 times, exactly as ROADMAP Success Criteria 1-4 require. This is strong, credible evidence; SUMMARY.md's narrative for these criteria matches what was independently re-confirmed in the live cluster and GitHub Actions run history during this verification.

**Update (2026-08-07T11:30Z, orchestrator):** The one gap this verification found (revert-conflict notification path silently failing) has been fixed — commit `3f26bb5f`, pushed to `main` shortly after this verification ran. It detects merge commits and passes `-m 1`, and switches the broken bare-command-then-`$?` pattern to `if`/`else` (which is exempt from GitHub Actions' inherited `bash -e` step shell — the actual root cause). Fix is logic-verified (parent-count detection tested against real repo commits; `-e`-exemption confirmed via isolated reproduction) but not yet re-exercised against a real live failure — tracked as WINDOWS.md #7, same treatment as the CR-01/02/03 fixes below. No must-have remains code-incomplete; three items now need only live/human re-verification, not further code changes.

Three items are routed to human verification rather than treated as blocking gaps: the Slack eyes-on confirmation for this session's specific revert notifications (mechanism proven working generally in 05-03; this specific instance unconfirmed), the live re-exercise of the CR-01/CR-02/CR-03 code-review fixes (WINDOWS.md #6), and the live re-exercise of this revert-conflict-notification fix (WINDOWS.md #7). All three are code-complete and logic-verified; none require further code changes, only supervised live test cycles — natural candidates for early Phase 6 work, since Phase 6 depends on this exact mechanism.

---

_Verified: 2026-08-07T11:05:27Z_
_Verifier: Claude (gsd-verifier)_
