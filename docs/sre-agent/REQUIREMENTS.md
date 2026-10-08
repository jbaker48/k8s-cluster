# Requirements: SRE Agent — Staged Renovate/PR Auto-Merge

**Defined:** 2026-07-27
**Core Value:** Low-risk PRs merge themselves safely; anything that could take down the cluster still requires a human — and if the AI or the human is wrong anyway, the health-gate reverts it automatically.

## v1 Requirements

### Infrastructure

- [x] **INFRA-01**: New ARC runner scale set deployed, scoped to `jbaker48/k8s-cluster`, with the shared ARC controller upgraded to a compatible version (chart `0.14.2`), so CI can reach the internal-only `litellm` proxy
- [x] **INFRA-02**: `konflate` deployed in-cluster (Helm chart, MCP endpoint enabled) following the same OCIRepository/HelmRelease pattern already used for `litellm`

### AI Review

- [x] **REVIEW-01**: AI PR review workflow runs on every PR (Renovate and human-authored) against this repo, using `pr-reviewer-action` pinned to an exact tag, calling `litellm` via a scoped virtual key (never the master key)
- [x] **REVIEW-02**: Review workflow is wired to `konflate` as an MCP evidence tool, matching the home-ops `tool_mcp_servers` pattern — treated as a review enhancement, not a blocking dependency
- [x] **REVIEW-03**: Review workflow inherits home-ops's safety config verbatim: concurrency dedup per PR, draft-PR skip, fork/untrusted-source tool restrictions, bounded tool-loop (max requests/rounds/wall-clock), fail-closed on model failure (never auto-approves on error)
- [x] **REVIEW-04**: Review workflow ships and runs in advisory-only mode (comment only, no merge action) first, so verdict accuracy can be observed against real PR volume before the merge-triggering step is enabled

### Exclusion Gate

- [x] **GATE-01**: Deterministic path-glob hard-exclusion check runs on every PR, matching Talos, Kubernetes-core, and Cilium paths, independent of and unoverridable by the AI verdict
- [x] **GATE-02**: A PR matching the hard-exclusion gate is visibly marked (comment and/or label) and always requires human merge, regardless of AI verdict

### Auto-Merge

- [ ] **MERGE-01**: A PR is only eligible for real auto-merge when: AI verdict = approve, the hard-exclusion gate did not fire, and required CI/status checks are green
- [ ] **MERGE-02**: Real auto-merge activation is gated behind a config toggle, enabled only after the health-gate has been proven via an induced-failure test — a build-order requirement, not just a feature flag

### Health-Gate & Revert

- [x] **HEALTH-01**: After an auto-merge, a post-merge health-gate watches Flux Kustomization/HelmRelease `Ready`/`Stalled` conditions across the cluster for a bounded observation window
- [x] **HEALTH-02**: The health-gate produces a three-way outcome (healthy / unhealthy / inconclusive); only "unhealthy" triggers an auto-revert — "inconclusive" notifies a human instead of reverting
- [x] **HEALTH-03**: Auto-revert is implemented as `git revert` + push (forward-only), never a history rewrite (no force-push, no `reset --hard`)
- [x] **HEALTH-04**: A revert-loop circuit breaker pauses auto-merge for the affected path/app after N reverts within a time window, requiring explicit human re-enable

### Audit & Notifications

- [ ] **AUDIT-01**: Every exclude/merge/revert decision is recorded in a structured, human-readable audit trail (what fired, why, which PR/commit, timestamp)
- [x] **AUDIT-02**: A notification (not just a log line) is sent on every revert and every hard-exclusion, reusing existing in-cluster alerting infra rather than building a new channel

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Observability

- **OBS-01**: Compact/tiered review verbosity by risk class, to reduce PR comment noise as "any PR" scope generates higher review volume than home-ops's narrower scope
- **OBS-02**: Metrics/track-record dashboard on approve/exclude/revert rates and false-approve rate, built from AUDIT-01's log data

### Trust Scope

- **MERGE-03**: Progressive expansion of auto-merge trust scope (e.g. start narrower than "any approve", expand once track-record data supports it), tuned based on OBS-02's metrics

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| General-purpose kubectl/flux/git MCP access for the review agent | Rejected during questioning — home-ops's own production pattern proves a CI job + one scoped MCP tool is sufficient; broad live-cluster access is the largest blast-radius risk in the design |
| toolhive as an MCP gateway | Unneeded once the narrower single-tool (konflate) architecture was confirmed |
| Expanding the hard-exclusion list beyond Talos/Kubernetes-core/Cilium | Deliberately left to AI judgment per the original seed design; revisit only if track-record data shows systematic AI under-weighting for another category, the same way spike 001 proved the case for Cilium |
| Adaptive/router model selection instead of a pinned model | Spike 001 used a pinned model for reproducible results; adaptive routing is a separate production cost-optimization concern, not part of this project |
| Per-app/per-namespace configurable health-gate windows | The `db_or_migration_changes`/stateful-app risk category needs its own follow-up spike before a differentiated window design is worth building |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| GATE-01 | Phase 1 | Complete |
| GATE-02 | Phase 1 | Complete |
| INFRA-01 | Phase 2 | Complete |
| INFRA-02 | Phase 3 | Complete |
| REVIEW-01 | Phase 4 | Complete |
| REVIEW-02 | Phase 4 | Complete |
| REVIEW-03 | Phase 4 | Complete |
| REVIEW-04 | Phase 4 | Complete |
| HEALTH-01 | Phase 5 | Complete |
| HEALTH-02 | Phase 5 | Complete |
| HEALTH-03 | Phase 5 | Complete |
| HEALTH-04 | Phase 5 | Complete |
| MERGE-01 | Phase 6 | Pending |
| MERGE-02 | Phase 6 | Pending |
| AUDIT-01 | Phase 6 | Pending |
| AUDIT-02 | Phase 5 | Complete |

**Coverage:**

- v1 requirements: 16 total
- Mapped to phases: 16
- Unmapped: 0 ✓

---
*Requirements defined: 2026-07-27*
*Last updated: 2026-07-27 after roadmap creation (all 16 v1 requirements mapped across 6 phases)*
