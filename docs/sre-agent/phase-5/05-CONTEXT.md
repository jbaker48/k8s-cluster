# Phase 5: Post-Merge Health-Gate & Auto-Revert - Context

**Gathered:** 2026-08-06
**Status:** Ready for planning

<domain>
## Phase Boundary

Every merge to `main` is watched by a health-gate that polls Flux Kustomization/HelmRelease `Ready`/`Stalled` conditions across the cluster for a bounded observation window. A genuinely unhealthy outcome (Stalled/Failed within the window) triggers an automatic `git revert`, delivered as an auto-merged revert PR — proven end-to-end against a deliberately induced real failure before Phase 6 ever asks it to backstop a real AI-driven auto-merge. An inconclusive outcome (still reconciling at window-close) notifies a human instead of reverting. A revert-loop circuit breaker pauses auto-merge for a repeatedly-failing app after N reverts in a time window. Hard-exclusion events (Phase 1) and health-gate reverts both get a real notification through existing alerting infra (Robusta → `#k8s-alerts`), not just a log line. Real auto-merge go-live (Phase 6) — actually wiring AI-approve verdicts to trigger a merge — is explicitly out of this phase; Phase 5 only builds and proves the safety net.

</domain>

<decisions>
## Implementation Decisions

### Execution Environment & Cluster Access
- **D-01:** The health-gate runs as a GitHub Actions workflow triggered on push to `main` — keeps it consistent with every other piece of this project (Phases 1-4 all live in `.github/workflows/`), rather than introducing a new in-cluster CronJob/Job pattern this repo has never used. — **Reversibility:** costly — reversing to an in-cluster job later means re-deriving the credential/trigger model from scratch.
- **D-02:** Since Phase 2's `k8s-cluster-ci` runner was deliberately built with zero Kubernetes API RBAC (network-reachability-only, per Phase 2 D-04), the health-gate workflow gets a **new** scoped ServiceAccount + kubeconfig, with a Role limited to `get`/`list`/`watch` on Kustomizations and HelmReleases only (no write, no other resource types) — exposed to the runner as a kubeconfig secret. This is a genuinely new RBAC grant; least-privilege scoping mirrors Phase 2's credential-scoping precedent. — **Reversibility:** reversible — a scoped Role/kubeconfig secret is easy to revoke or narrow further.

### Revert Delivery & Bypass
- **D-03:** Auto-revert lands as an **auto-merged revert PR**, not a direct push to `main`. Leaves a visible PR trail for every revert (matches AUDIT-01/AUDIT-02's auditability intent) and reuses PR-merge machinery instead of a separate direct-push credential path. HEALTH-03's "forward-only, no force-push/reset --hard" constraint still applies — the revert PR's commit is a real `git revert`, never a rewrite.
- **D-04:** The revert PR must bypass Phase 1's exclusion-gate and Phase 4's AI-review to auto-merge itself, since Phase 6 (general auto-merge authority) doesn't exist yet when Phase 5 ships. Exact bypass mechanism (dedicated bot identity, branch-name prefix, and/or label marker that exclusion-gate/ai-review explicitly check and skip on) is **Claude's discretion** — research GitHub's recommended patterns for trusted-bot-PR bypass during planning. Must be an explicit, auditable trust boundary (not implicit on shared `github-actions[bot]` identity — Phase 4's D-05/D-06 incident with `pull_request_target` and shared identity is the cautionary precedent here). — **Reversibility:** one-way-ish — once a bypass identity/marker is load-bearing for the safety net itself, changing it requires care not to accidentally reopen a hole exclusion-gate exists to close.

### Health Classification
- **D-05:** Two-bucket classification off Flux's own condition semantics: `Ready=False` with a `Stalled` condition or a terminal `Failed` reason within the observation window = **unhealthy** (triggers revert). Still reconciling (not yet `Ready`, no `Stalled`/`Failed`) when the window closes = **inconclusive** (notifies a human, no revert). Observation window duration is **Claude's discretion** for planning.

### Circuit Breaker (HEALTH-04)
- **D-06:** Circuit-breaker bucketing is **not** exclusion-gate's category taxonomy (that file only covers the 3 hard-EXCLUDED categories — talos/kubernetes-core/cilium — and doesn't cover the apps that actually get auto-merged/reverted, e.g. media, database, network). Instead, bucket directly by which `kubernetes/apps/<namespace>/<app-name>` directory the merged PR touched — no new config file to maintain, though it can't group related apps under one shared breaker. Pause-state storage mechanism (repo file, GitHub repo variable, etc.) is **Claude's discretion**.

### Notifications (AUDIT-02)
- **D-07:** Notifications reuse Robusta's existing Slack sink (`main_slack_sink` → `#k8s-alerts`, `kubernetes/apps/observability/robusta/app/helmrelease.yaml`) rather than adding a second parallel Slack credential/path. The mechanism is: emit a Kubernetes Event on revert/exclusion; Robusta already watches cluster events and routes them to its configured sink. This requires whatever component has cluster write access (likely the health-gate's scoped ServiceAccount, extended with `create` on `events`, or a small in-cluster step) to create the Event — exact shape is **Claude's discretion** for planning.
- **D-08:** Confirmed in scope for Phase 5: extending Phase 1's `exclusion-gate.yaml` (already marked complete) with the same Kubernetes-Event notification step. AUDIT-02 explicitly names hard-exclusion as a notification trigger and cannot be satisfied without touching that workflow — this completes an already-scoped v1 requirement, not scope creep on a "done" phase.

### Claude's Discretion
- Observation window duration (D-05).
- Exact revert-PR bypass mechanism: bot identity, branch-name prefix, and/or label marker (D-04).
- Circuit-breaker pause-state storage location and exact enforcement point (D-06).
- Exact Kubernetes Event shape/reason/component fields for Robusta to route correctly (D-07).
- Exact RBAC Role/ClusterRole shape for the health-gate's read-only kubeconfig (D-02) — get/list/watch scoped to Kustomizations and HelmReleases only.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project scope & requirements
- `.planning/PROJECT.md` — Full project scope, constraints, key decisions (build order, health-gate architecture finding: Flux-native conditions + small custom polling job, not Flagger/Argo Rollouts)
- `.planning/REQUIREMENTS.md` (HEALTH-01, HEALTH-02, HEALTH-03, HEALTH-04, AUDIT-02) — The five v1 requirements this phase closes
- `.planning/ROADMAP.md` §Phase 5 — Goal, dependencies (Phase 1), and the 5 success criteria this phase must satisfy

### Prior phase context (patterns to mirror)
- `.planning/phases/04-ai-review-workflow-advisory-only/04-CONTEXT.md` — D-05/D-06: the shared `github-actions[bot]` identity incident (PR #1063) that motivates D-04's explicit-trust-boundary requirement for the revert-PR bypass; workflow-isolation pattern (new workflow file, not combined into existing ones)
- `.planning/phases/02-arc-runner-scale-set-controller-upgrade/02-CONTEXT.md` — D-01 (per-component scoped GitHub credential pattern), D-04 (the `k8s-cluster-ci` runner's deliberate zero-RBAC design that D-02 above must work around, not violate for other workloads)
- `.planning/phases/01-hard-exclusion-path-gate/01-CONTEXT.md` — Path-category taxonomy pattern (D-06's reasoning for why this isn't reused as-is for circuit-breaker bucketing); PR comment/label marking pattern to extend with the Event-notification step (D-08)

### Existing config this phase reads from / extends
- `.github/exclusion-gate.yaml` — Current 3-category taxonomy (talos, kubernetes-core, cilium) — confirmed too narrow for circuit-breaker bucketing (D-06); referenced for pattern only
- `.github/workflows/exclusion-gate.yaml` — Existing workflow to extend with the Kubernetes-Event notification step (D-08)
- `kubernetes/apps/observability/robusta/app/helmrelease.yaml` — `sinksConfig.slack_sink` (`main_slack_sink` → `#k8s-alerts`) — the existing alerting channel D-07's notifications must reach
- `kubernetes/flux/config/cluster.yaml` — Existing Flux `GitRepository`/`Kustomization` pattern (read-only `github-deploy-key` secret) — confirms no existing git-write credential exists in-cluster; the revert-PR's git-write need is new, scoped to GitHub Actions (D-01/D-03), not Flux's own credential

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `.github/workflows/exclusion-gate.yaml` — `pull_request_target` trigger, concurrency group, config-fetched-from-base-branch pattern, `mshick/add-pr-comment@v3` comment step — structural template for the health-gate's own new workflow file, and the file this phase directly extends (D-08).
- `kubernetes/apps/arc-runners/k8s-cluster-ci/app/` — Existing runner scale set (Phase 2) the health-gate workflow runs on; its `networkpolicy.yaml` already permits egress to litellm/konflate but has **no** Kubernetes API egress/RBAC — D-02's new kubeconfig/RBAC is additive to this, not a replacement.
- `kubernetes/apps/observability/robusta/app/helmrelease.yaml` — Existing `slack_sink` config (`#k8s-alerts`) — the notification target D-07 routes to via Kubernetes Events.

### Established Patterns
- GitHub Actions workflows live in `.github/workflows/`, config-driven category files live alongside them at `.github/*.yaml` (mirrors `exclusion-gate.yaml`'s split from its workflow) — a precedent, though D-06 explicitly chose NOT to add a matching circuit-breaker config file.
- Credential scoping is always per-component and least-privilege (Phase 2 D-01, Phase 4 D-01/D-02) — D-02's new RBAC grant and D-04's bypass identity should follow the same discipline: narrowest possible permission set for the specific job.
- No existing CronJob or in-cluster scheduled-job pattern in this repo — D-01's GitHub-Actions-workflow choice avoids having to invent one.
- No branch-protection rules found in this repo currently (`grep` for `branch.protect`/`required_status_checks` in `.github/` and `kubernetes/` returned nothing) — the revert-PR's auto-merge (D-03) likely doesn't need to satisfy required-status-check gating, but confirm this during research/planning rather than assuming it stays true.

### Integration Points
- New workflow file: `.github/workflows/health-gate.yaml` (or similar, exact name TBD by planner/executor) — triggered on push to `main`.
- Extension to existing `.github/workflows/exclusion-gate.yaml`: new Kubernetes-Event notification step (D-08).
- New in-cluster RBAC: ServiceAccount + Role (Kustomizations/HelmReleases get/list/watch) + kubeconfig Secret, likely under a new or existing namespace — exact placement TBD by planner.
- New GitHub credential: revert-PR bot identity/bypass marker consumed by both the new health-gate workflow and (for the skip check) `exclusion-gate.yaml`/`ai-review.yaml`.

</code_context>

<specifics>
## Specific Ideas

- User was explicit that the exclusion-gate taxonomy (3 hard-excluded categories) is the wrong shape to reuse for circuit-breaker bucketing — the two are different problem spaces (permanently-excluded infra vs. apps that can fail after being legitimately auto-merged) and conflating them would be a real correctness bug, not just a style choice.
- User confirmed AUDIT-02's hard-exclusion notification is in-scope for Phase 5 even though Phase 1 is marked complete — this is finishing an already-scoped requirement, not reopening Phase 1.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within Phase 5's scope. (Real auto-merge go-live, AUDIT-01's full structured audit trail, and MERGE-01/MERGE-02 all remain explicitly Phase 6's.)

### Reviewed Todos (not folded)
None — no pending todos matched this phase during `cross_reference_todos`.

</deferred>

---

*Phase: 5-Post-Merge Health-Gate & Auto-Revert*
*Context gathered: 2026-08-06*
