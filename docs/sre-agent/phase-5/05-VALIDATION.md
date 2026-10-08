---
phase: 5
slug: post-merge-health-gate-auto-revert
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
# audit-milestone §5.5 distinguishes NOT-VALIDATED (draft) from PARTIAL (validated + nyquist_compliant: false) (#2117)
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-08-06
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | None — this repo has no unit-test framework. Validation is `task validate:all` (yamllint, kustomize build, consistency script) plus live end-to-end proof against the real cluster/repo, matching Phases 1/2/4's established pattern. |
| **Config file** | `Taskfile.yaml`, `.pre-commit-config.yaml` |
| **Quick run command** | `task validate:yaml && task validate:kustomize` |
| **Full suite command** | `task validate:all` |
| **Estimated runtime** | ~30 seconds (lint/kustomize-build only; live cluster proofs are separate, unbounded by this estimate) |

---

## Sampling Rate

- **After every task commit:** Run `task validate:yaml && task validate:kustomize`
- **After every plan wave:** Run `task validate:all`
- **Before `/gsd-verify-work`:** Full suite must be green, AND all five ROADMAP success criteria must be proven live against the real cluster (see Manual-Only Verifications — this phase has no automated substitute for the induced-failure proofs)
- **Max feedback latency:** 60 seconds (lint tier); live-proof tasks are inherently unbounded (poll-loop windows, real merge/revert cycles) and are tracked separately, not against this latency budget

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 05-01-01 | 01 | 1 | HEALTH-01 | T-05-01 | health-gate kubeconfig grants only get/list/watch on Kustomizations/HelmReleases | lint | `task validate:kustomize` | ✅ | ⬜ pending |
| 05-01-02 | 01 | 1 | HEALTH-01 | — | k8s-cluster-ci networkpolicy grants egress to kube-apiserver via toEntities, not a broader CIDR | lint | `task validate:kustomize` | ✅ | ⬜ pending |
| 05-02-01 | 02 | 2 | HEALTH-01/HEALTH-02 | T-05-02 | poll loop classifies Stalled/Failed=unhealthy, still-reconciling-at-window-close=inconclusive, never defaults to healthy on error | live | manual workflow dispatch + `kubectl get events` observation | ❌ W0 | ⬜ pending |
| 05-03-01 | 03 | 2 | HEALTH-03/D-04 | T-05-03 | revert-bot identity is a dedicated GitHub App, never shared github-actions[bot]; bypass keyed off explicit branch-prefix+label marker, not github.actor | lint + live | `task validate:yaml` + live PR inspection of bypass-marker check | ❌ W0 | ⬜ pending |
| 05-03-02 | 03 | 2 | HEALTH-03 | — | revert commit is a real `git revert`, no force-push/reset --hard in workflow YAML | static | `grep -c 'force\|reset --hard' .github/workflows/health-gate.yaml` returns 0 | ❌ W0 | ⬜ pending |
| 05-04-01 | 04 | 3 | HEALTH-04 | T-05-04 | circuit-breaker state file is only ever written by the revert-bot's own credential; exclusion-gate only reads it at PR base SHA | live | manual repeated-induced-failure test + inspection of `.github/health-gate/circuit-breaker-state.json` | ❌ W0 | ⬜ pending |
| 05-05-01 | 05 | 4 | AUDIT-02 | T-05-05 | Kubernetes Event fires on revert and on hard-exclusion; Robusta customPlaybooks routes both reasons to #k8s-alerts | live | manual Slack `#k8s-alerts` observation | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

*Note: exact task IDs above are illustrative — the planner assigns final plan/wave/task numbering; this map should be reconciled against the actual PLAN.md files once written.*

---

## Wave 0 Requirements

- [ ] No traditional test-scaffolding gap — this repo's validation model is schema/syntax linting + live proof against the real cluster, already established by Phases 1/2/3/4. There is no framework to install.
- [ ] Structure Phase 5's plan with explicit live-verification tasks (mirroring Phase 1 D-11/D-12 and Phase 4 D-09/D-10/D-11) for each of the five ROADMAP success criteria, since none has a meaningful automated-test substitute.

*Existing infrastructure (lint/kustomize-build via `task validate:all`) covers all phase requirements' static-shape checks; live proof is required for behavioral requirements and is not a Wave 0 gap.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Health-gate polls Flux conditions cluster-wide within a bounded window | HEALTH-01 | No automated cluster-state test exists in this repo; requires a live cluster and a real merge event | Merge a trivial change to `main`, confirm `health-gate.yaml` triggers via `gh run list`, observe `kubectl get events` / workflow logs for the poll loop completing within the configured window |
| Deliberately induced real failure is detected as unhealthy and triggers an automatic revert PR that auto-merges | HEALTH-02 | CONTEXT.md explicitly requires "verified end-to-end against a real induced failure, not just unit-tested logic" | Merge a change that breaks a HelmRelease (5m-timeout-class app per Pitfall 2), confirm `health-gate.yaml` classifies `unhealthy`, opens a revert PR, and auto-merges it |
| Deliberately induced transient/ambiguous signal produces inconclusive, no revert | HEALTH-03 | Same as above — inherently a live timing-dependent proof | Induce a signal that is still `Reconciling` (not `Stalled`/`Failed`) at window-close, confirm no revert PR is created and a human notification fires instead |
| Circuit breaker pauses auto-merge for a path/app after N reverts in a window | HEALTH-04 | Requires multiple real revert cycles against the same app bucket | Induce repeated failures against the same app directory until the threshold is crossed, confirm `exclusion-gate.yaml` applies `gate/human-required` on the next PR touching that bucket, confirm human re-enable via editing `circuit-breaker-state.json` unblocks it |
| Notification fires through Robusta to `#k8s-alerts` on revert and on hard-exclusion | AUDIT-02 | Requires live Slack channel observation; no automated Slack-assertion tooling exists in this repo | During the HEALTH-02 and hard-exclusion proofs above, confirm a message appears in `#k8s-alerts` for each `HealthGateAutoRevert` / `HealthGateInconclusive` / `HardExclusionBlocked` event |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify (lint tier) or an explicit live-verification `<verify>` step
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify (lint-tier checks apply to every YAML-producing task)
- [ ] Wave 0 covers all MISSING references (N/A — no test-framework gap, see Wave 0 Requirements)
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s for lint tier; live-proof tasks tracked separately per Manual-Only Verifications
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
