# Roadmap: SRE Agent — Staged Renovate/PR Auto-Merge

## Overview

This roadmap builds a staged auto-merge pipeline for `jbaker48/k8s-cluster` in the exact order confirmed during questioning: prove the deterministic safety net before the AI verdict is ever allowed to touch a real merge. It starts with the one non-negotiable, zero-dependency safety mechanism (the hard-exclusion path-gate), then lays the infrastructure the rest of the pipeline needs (a repo-scoped ARC runner so CI can reach in-cluster `litellm`, then `konflate` for evidence). Only once that foundation exists does the AI-review workflow go live — in advisory/comment-only mode, so verdict quality can be observed against real PR traffic. The post-merge health-gate and auto-revert mechanism is then built and proven independently, via a deliberately induced failure, before the last phase wires real auto-merge live and turns the whole system on for real.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [x] **Phase 1: Hard-Exclusion Path-Gate** - Deterministic, code-enforced check blocks AI-driven auto-merge on any PR touching Talos/Kubernetes-core/Cilium paths, independent of AI judgment (completed 2026-07-27)
- [x] **Phase 2: ARC Runner Scale Set & Controller Upgrade** - CI can reach the internal-only `litellm` proxy via a new repo-scoped, hardened runner (completed 2026-08-04)
- [x] **Phase 3: konflate Deployment & Standalone Validation** - Rendered-diff/blast-radius evidence tool deployed in-cluster and validated against real PR data before being trusted in live review (completed 2026-08-05)
- [x] **Phase 4: AI-Review Workflow (Advisory-Only)** - Every PR gets an AI risk-triage review comment, matching home-ops's production-proven config, with no merge authority yet (completed 2026-08-06)
- [ ] **Phase 5: Post-Merge Health-Gate & Auto-Revert** - Cluster health is watched after any merge and unhealthy outcomes are automatically reverted, proven via a deliberately induced failure
- [ ] **Phase 6: Auto-Merge Go-Live** - Real auto-merge is enabled for approved, non-excluded, green-checked PRs, with full exclude/merge/revert audit trail

## Phase Details

### Phase 1: Hard-Exclusion Path-Gate

**Goal**: Any PR touching cluster-critical infrastructure is deterministically flagged and blocked from AI-driven auto-merge, regardless of what the AI verdict says.
**Depends on**: Nothing (first phase)
**Requirements**: GATE-01, GATE-02
**Success Criteria** (what must be TRUE):

  1. An `exclusion-check` job runs on every PR and outputs a deterministic `excluded: true|false` based on path-glob matching against Talos, Kubernetes-core, and Cilium paths — with zero dependency on litellm, `pr-reviewer-action`, or any AI call.
  2. The exclusion path list lives in its own file, separate from `.github/labeler.yaml`, so it can't be casually loosened alongside unrelated labeler changes.
  3. A test PR that only touches non-critical paths is not flagged; a test PR touching a Talos/Kubernetes-core/Cilium path is flagged, visibly marked via comment and/or label, and states a human must merge it — verified against real (or realistic fixture) PRs of both kinds.

**Plans**: 2/2 plans executed

Plans:
**Wave 1**

- [x] 01-01-PLAN.md — Author exclusion-gate.yaml path taxonomy, gate/human-required label, and the exclusion-check workflow

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 01-02-PLAN.md — Publish to main and verify via real test PRs (D-11/D-12)

### Phase 2: ARC Runner Scale Set & Controller Upgrade

**Goal**: GitHub Actions jobs running against this repo can reach the internal-only `litellm` proxy, on infrastructure hardened before any live AI pipeline exists to leak from.
**Depends on**: Phase 1 (sequenced per confirmed build order; no hard technical dependency)
**Requirements**: INFRA-01
**Success Criteria** (what must be TRUE):

  1. A new `gha-runner-scale-set` scoped to `jbaker48/k8s-cluster` is deployed and Flux reports it Ready/healthy.
  2. The shared ARC controller is upgraded to a version compatible with chart `0.14.2`, and the existing `ha-restarter` scale set continues to run its jobs successfully after the upgrade (no regression to existing infra).
  3. A test CI job running on the new runner successfully reaches `litellm`'s internal endpoint end-to-end (not just a network policy review — an actual job run).
  4. Runner pods run ephemeral, without Docker socket access, with RBAC scoped to network reachability only, not general Kubernetes API access.

**Plans**: 3/3 plans executed

Plans:
**Wave 1**

- [x] 02-01-PLAN.md — Bump ARC controller + ha-restarter chart to 0.14.2 together, verify no regression

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 02-02-PLAN.md — Create the k8s-cluster-ci scale set app (D-01/D-03/D-04 hardening applied)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 02-03-PLAN.md — Human PAT/Doppler checkpoint, then verify litellm reachability end-to-end

### Phase 3: konflate Deployment & Standalone Validation

**Goal**: A rendered-diff/blast-radius evidence tool is running in-cluster and its output quality for this repo is verified before it's trusted inside a live AI review call.
**Depends on**: Phase 2 (needs the ARC runner's network path to reach konflate's MCP endpoint for validation)
**Requirements**: INFRA-02
**Success Criteria** (what must be TRUE):

  1. `konflate` is deployed in-cluster via the same OCIRepository/HelmRelease pattern already used for `litellm`, and Flux reports it Ready.
  2. konflate's `/mcp` endpoint responds to a direct test call made from the new ARC runner (Phase 2's network path).
  3. A standalone test against at least one real historical PR diff produces a usable rendered-diff/blast-radius evidence response — closing spike 001's explicitly deferred gap before Phase 4 wires it into live review.

**Plans**: 2/2 plans executed

Plans:
**Wave 1**

- [x] 03-01-PLAN.md — Deploy konflate end-to-end (GitHub App checkpoint + tracer deploy), prove Flux Ready

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 03-02-PLAN.md — Standalone validation: /mcp reachability + access-control proof, PR #1037 evidence quality

### Phase 4: AI-Review Workflow (Advisory-Only)

**Goal**: Every PR against this repo receives a genuine AI risk-triage review comment, with the same safety config home-ops runs in production — but no merge authority yet, so verdict quality can be observed against real PR volume first.
**Depends on**: Phase 2, Phase 3 (needs both the litellm network path and a validated konflate evidence tool for genuine end-to-end testing)
**Requirements**: REVIEW-01, REVIEW-02, REVIEW-03, REVIEW-04
**Success Criteria** (what must be TRUE):

  1. `pr-reviewer-action`, pinned to an exact tag, runs automatically on every open PR (Renovate and human-authored) against this repo and posts a review comment only — no merge/approve action is ever taken.
  2. The workflow calls `litellm` through a scoped virtual key, never the master key, confirmed by inspecting the credential used in a live run.
  3. `konflate` is wired in as an MCP tool in the review's tool loop, and at least one real review run shows the model pulling konflate evidence when it needs more than the injected diff summary.
  4. Draft PRs are skipped, concurrent runs on the same PR are deduped, fork-originated PRs run with restricted tool access, and the tool loop is bounded (max requests/rounds/wall-clock) — each verified against a real or simulated test case.
  5. A simulated model/tooling failure causes the workflow to fail closed (post a notice, never default to an approve verdict).

**Plans**: 3/3 plans executed

Plans:
**Wave 1**

- [x] 04-01-PLAN.md — Provision the scoped litellm virtual key, author ai-review.yaml, and prove it end-to-end on two real PRs

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 04-02-PLAN.md — Prove bounded tool-loop compliance, draft-PR skip, and concurrency dedup against real GitHub Actions runs

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 04-03-PLAN.md — Prove fork-PR restriction and fail-closed behavior, then human-confirm scoped-key usage

### Phase 5: Post-Merge Health-Gate & Auto-Revert

**Goal**: Cluster health is watched after any merge to `main`, and a genuinely unhealthy outcome is automatically reverted — proven against a deliberately induced failure before it's ever asked to backstop a real AI-driven auto-merge.
**Depends on**: Phase 1 (exclusion audit signal exists to notify alongside); sequenced after Phase 4 per confirmed build order, though the health-gate has no hard code dependency on the AI-review layer
**Requirements**: HEALTH-01, HEALTH-02, HEALTH-03, HEALTH-04, AUDIT-02
**Success Criteria** (what must be TRUE):

  1. After a merge to `main`, the health-gate polls Flux Kustomization/HelmRelease `Ready`/`Stalled` conditions across the cluster for a bounded observation window.
  2. A deliberately induced real failure (merging a change that breaks a HelmRelease) is detected as "unhealthy" within the window and triggers an automatic `git revert` + push to `main` — verified end-to-end against a real induced failure, not just unit-tested logic.
  3. A deliberately induced transient/ambiguous signal produces an "inconclusive" outcome that notifies a human instead of auto-reverting.
  4. After N reverts within a configured time window for the same path/app, auto-merge is automatically paused for that path/app until a human explicitly re-enables it — verified by inducing repeated failures.
  5. A notification (not just a log line) fires through existing in-cluster alerting infra on the induced revert and on a hard-exclusion event, reusing the same channel.

**Plans**: 7/7 plans executed

Plans:
**Wave 1**

- [x] 05-01-PLAN.md — Health-gate RBAC + network policy + kubeconfig delivery (D-02)
- [x] 05-02-PLAN.md — Revert-bot identity decision + provisioning + bypass/circuit-breaker scaffold (D-04)
- [x] 05-03-PLAN.md — Robusta customPlaybooks extension, live-proven with synthetic events (D-07)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 05-04-PLAN.md — health-gate.yaml tracer: poll + 3-way classify + notify, live-proven healthy
- [x] 05-05-PLAN.md — exclusion-gate.yaml: bypass check + circuit-breaker read + hard-exclusion notify

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 05-06-PLAN.md — health-gate.yaml revert logic + circuit-breaker write-side, inconclusive live-proven

**Wave 4** *(blocked on Wave 3 completion)*

- [x] 05-07-PLAN.md — Full induced-failure live proof: unhealthy→revert→circuit-breaker trip→human re-enable

### Phase 6: Auto-Merge Go-Live

**Goal**: Real auto-merge is live for PRs that clear every gate, removing the human from the loop for low-risk changes — with a full audit trail across every exclude, merge, and revert decision the system makes.
**Depends on**: Phase 1, Phase 4, Phase 5 (all three gates — exclusion, AI verdict, and the proven health-gate — must exist before real merge authority is granted)
**Requirements**: MERGE-01, MERGE-02, AUDIT-01
**Success Criteria** (what must be TRUE):

  1. A real PR with AI verdict = approve, not excluded, and all required checks green is automatically merged with no human action.
  2. Real auto-merge stays behind a config toggle that is only flipped on after Phase 5's health-gate has been proven via an induced failure — the toggle flip is a distinct, deliberate, auditable action, not a default-on feature flag.
  3. Every exclude, merge, and revert decision the system makes end-to-end appears in a structured, human-readable audit trail entry containing what fired, why, which PR/commit, and a timestamp.

**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6

| Phase | Plans Complete | Status | Completed |
|-------|-----------------|--------|-----------|
| 1. Hard-Exclusion Path-Gate | 2/2 | Complete    | 2026-07-27 |
| 2. ARC Runner Scale Set & Controller Upgrade | 3/3 | Complete    | 2026-08-04 |
| 3. konflate Deployment & Standalone Validation | 2/2 | Complete    | 2026-08-05 |
| 4. AI-Review Workflow (Advisory-Only) | 3/3 | Complete    | 2026-08-06 |
| 5. Post-Merge Health-Gate & Auto-Revert | 7/7 | In Progress|  |
| 6. Auto-Merge Go-Live | 0/TBD | Not started | - |

---
*Roadmap created: 2026-07-27*
*Granularity: standard (6 phases — at the top of the standard band, justified by the user-confirmed strict build order: each phase is an independently verifiable safety/infra milestone, not a thin single-task split)*
