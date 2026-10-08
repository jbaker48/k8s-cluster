# SRE Agent: Staged Renovate/PR Auto-Merge

## What This Is

An AI-assisted auto-merge pipeline for this cluster's GitOps repo. Every open PR (Renovate dependency bumps plus human-authored PRs) is reviewed by an AI risk-triage step modeled directly on `bjw-s-labs/home-ops`'s production `.forgejo/workflows/pr-reviewer.yaml` pattern: `misospace/pr-reviewer-action` calling the existing in-cluster `litellm` proxy, with `home-operations/konflate` wired in as an MCP tool server for rendered-diff/blast-radius evidence. An "approve" verdict triggers a real auto-merge — not just an advisory comment. A deterministic post-merge health-gate watches cluster health after merge and auto-reverts if something breaks. Cluster-critical infra (Talos, Kubernetes, Cilium) is always excluded from AI-driven auto-merge via deterministic path-glob matching (not agent judgment), regardless of verdict.

## Core Value

Low-risk PRs (the overwhelming majority of Renovate noise) merge themselves safely; anything that could take down the cluster still requires a human — and if the AI or the human is wrong anyway, the health-gate reverts it automatically.

## Context

**Origin:** Today, Renovate only auto-merges GitHub Actions bumps (minor/patch). Every Docker image, Helm chart, and Flux resource bump requires manual PR review and merge — this is the toil this project eliminates.

**Prior exploration (already done, feeds directly into this project):**
- `.planning/seeds/sre-agent-renovate-automerge.md` — original design shape (two-layer confidence model: AI triage + deterministic health-gate/rollback; hard-exclusion rule for cluster-critical infra; "reuse before building" constraint).
- `.planning/spikes/001-konflate-pr-reviewer-live-test/` — **VALIDATED (with caveat)**. Live-tested `misospace/pr-reviewer-action` against real open Renovate PRs on this repo, talking to the real `litellm` proxy (model `claude-sonnet-4-6`). Confirmed the AI triage layer produces genuinely substantive, non-rubber-stamp reviews (caught a real Cilium 1.19.4 `EndpointSlice` label-filtering breaking-change risk). Also confirmed the hard-exclusion rule is load-bearing, not redundant: on that same Cilium minor bump, the AI still verdicted `approve` despite surfacing the real risk — it's good at describing risk, not at weighting cluster-wide blast radius the way the hard rule does.
- **Architecture reference (found during this session's questioning):** `bjw-s-labs/home-ops`'s live production setup (`.forgejo/workflows/pr-reviewer.yaml`, `.agents/instructions/pr-review.instructions.md`, `.forgejo/labeler.yaml`) shows the actual shape to copy: `pr-reviewer-action` runs as a plain CI job (no bespoke in-cluster "SRE agent" with general kubectl/flux MCP access), calling `litellm` directly, with `konflate` wired in as a scoped MCP tool (`tool_mcp_servers: "konflate=http://konflate.<ns>.svc.cluster.local:8080/mcp"`) that the action calls during its native tool-loop when it needs more than the injected rendered-diff summary. Their `labeler.yaml` path-glob pattern (`area/talos`, `area/bootstrap`, etc.) is the model for implementing this project's hard-exclusion rule deterministically by file path rather than via agent judgment.

**Correction found during domain research (two independent research agents confirmed):** the home-ops reference is **advisory-only in production** — `pr-reviewer.yaml` posts a review comment and does nothing else; `pr-reviewer-action` never merges/approves/pushes anything itself (confirmed from its own docs). Home-ops's real auto-merge is 100% Renovate-native config, entirely independent of the AI verdict, and they have **no post-merge health-gate/auto-revert workflow at all**. So: the AI-review-mechanics half of this project (action config, model wiring, `konflate` MCP evidence tool) is copy-able, production-proven plumbing — but "AI verdict triggers a real auto-merge" and "deterministic health-gate + auto-revert" are genuinely new construction, with no reference implementation to lean on. This changes nothing about v1 scope (still building both), but it does change build order — see Key Decisions.

**Health-gate architecture question resolved by research:** Flux's native `Ready`/`Stalled` conditions are sufficient signal — Flagger and Argo Rollouts solve traffic-shifted canary rollout, not "revert the git commit," and are not needed. The health-gate is a small custom polling job (not a new controller) that watches conditions for a bounded window post-merge and runs `git revert && push` on failure. Still open: direct push to `main` (needs a bot credential/branch-protection exception) vs. an auto-merged revert PR — a planning-phase decision.

**Stack finding:** this repo's shared ARC runner controller is pinned at `v0.11.0`; the new scale set needs `gha-runner-scale-set` chart `v0.14.2`, so the shared controller needs a version upgrade too (affects the existing `ha-restarter` scale set — flag for planning, not just the new scale set in isolation).

**New gap found during spike 001 (production blocker):** `litellm` is only reachable via `envoy-internal` — GitHub-hosted runners can't reach it. Needs a new ARC (actions-runner-controller) runner scale set scoped to `jbaker48/k8s-cluster`, following the existing pattern in `kubernetes/apps/arc-runners/ha-restarter` (currently scoped only to `jbaker48/home-assistant-config`).

**Existing cluster foundation this builds on** (already in place, not part of this project's scope):
- Flux CD 2.17.2 GitOps deploying from this repo's `main` branch; HelmRelease/Kustomization health status already exists as a signal Flux tracks natively.
- `litellm` already deployed in-cluster (`kubernetes/apps/ai/litellm`) as the LLM proxy backend.
- `arc-runners/ha-restarter` already establishes the ARC runner scale-set pattern to mirror.
- `.github/renovate.json5` already auto-merges GitHub Actions bumps via branch automerge — this project extends auto-merge to the rest of Renovate's PR traffic (and human PRs) via AI triage instead of blanket automerge.

## Requirements

### Validated

- [x] Deterministic hard-exclusion rule: PRs touching Talos, Kubernetes core, or Cilium paths are never AI-auto-merged, implemented via path-glob matching (modeled on home-ops's `labeler.yaml`), independent of AI verdict — Validated in Phase 1: Hard-Exclusion Path-Gate. Empirically proven end-to-end against two real PRs (non-critical unflagged, critical dual-category flagged with combined sticky comment); code review also caught and fixed a config-fetch trust-boundary gap (CR-01) and a hardcoded-category drift risk (CR-02) before this was considered done.
- [x] AI review workflow runs against real PRs (Renovate and human-authored) on this repo via `workflow_dispatch`, using `pr-reviewer-action` + `litellm`, matching the bjw-s-labs/home-ops reference pattern — Validated in Phase 4: AI-Review Workflow (Advisory-Only). Empirically proven across a substantive chart-bump PR, a near-trivial digest-bump PR, a genuine fork-originated cross-repo PR, and a deliberately-broken-credential fail-closed test — comment-only, zero native reviews added, scoped litellm key confirmed via live spend-ledger inspection. **Caveat:** the originally-planned automatic `pull_request_target` trigger (opened/reopened/synchronize/ready_for_review) is NOT currently live — it was deliberately removed after a real live incident (the shared `github-actions[bot]` identity caused `ai-review.yaml`'s first automatic dispatch to silently overwrite an unrelated `flux-diff.yaml` comment on PR #1063, content unrecoverable). Restoring automatic triggering requires a dedicated bot identity (PAT or GitHub App) for `ai-review.yaml` — tracked as required follow-up work, not dropped.
- [x] `konflate` wired into the review workflow as an MCP tool server for rendered-diff/blast-radius evidence — Validated in Phase 3 (deployment + standalone validation) and Phase 4 (review-workflow wiring: live runs show the model actually invoking `mcp__konflate__list_pull_requests`/`get_pr_summary` when it needs more than the injected diff summary).

### Active
- [ ] New ARC runner scale set scoped to `jbaker48/k8s-cluster`, mirroring `arc-runners/ha-restarter`, so CI can reach `litellm` (closes the spike 001 gap)
- [ ] "Approve" verdict (outside excluded paths) triggers a real auto-merge, not just an advisory comment
- [ ] Deterministic post-merge health-gate watches cluster health (affected app(s) plus broader cluster-level regressions) after an auto-merge and automatically reverts (git revert + push) if something goes unhealthy
- [ ] Hard-exclusion path list and health-gate revert behavior are both auditable/observable (clear log or notification of why something was excluded or reverted)

### Out of Scope

- General-purpose "SRE agent" with broad kubectl/flux/git MCP access — explicitly rejected during questioning in favor of the narrower, validated home-ops pattern (CI job + scoped konflate MCP tool only)
- toolhive as an MCP gateway — not needed once the narrower architecture was confirmed
- Expanding the hard-exclusion list beyond Talos/Kubernetes/Cilium (e.g. storage/Rook Ceph, cert-manager, stateful apps) — deliberately left to AI judgment per the original seed design, not a hard rule

## Constraints

- **Reuse before building**: Confirmed via spike 001 and this session's reference check — `misospace/pr-reviewer-action` + `home-operations/konflate` replace any custom-built review/diff tooling. Do not build bespoke equivalents.
- **Model pinning**: Spike 001 used a pinned model (`claude-sonnet-4-6`) rather than an adaptive-router alias, for reproducible results. Production model choice is a decision for planning, not re-litigated here.
- **Network reachability**: `litellm` is only reachable via `envoy-internal`; GitHub-hosted runners cannot reach it directly — requires the new ARC runner scale set.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Real auto-merge on approve (not advisory-only) | User explicitly chose full automation over decision-support-only for v1 | — Pending |
| v1 includes both AI triage AND the deterministic health-gate/rollback layer | User wants the safety net in place before real auto-merge goes live, not deferred | — Pending |
| ARC runner scale set is in-scope for this project | Required to close the production-blocking gap spike 001 found; not treated as an external dependency | — Pending |
| Architecture = CI job (pr-reviewer-action) + scoped konflate MCP tool, not a general in-cluster "SRE agent" | Directly copies bjw-s-labs/home-ops's validated production pattern instead of the seed's more speculative toolhive/MCP-everything design | — Pending |
| konflate included in v1 (not deferred) | User chose to include it now despite it being unverified in spike 001, since the home-ops reference shows a working production integration to copy | — Pending |
| Hard-exclusion rule implemented via deterministic path-glob matching | Mirrors home-ops's `labeler.yaml` area/* pattern; keeps the "no agent override" guarantee enforceable in code, not prompt-dependent | — Pending |
| Scope is any PR, not just Renovate | User explicitly broadened scope beyond the seed's Renovate-only framing | — Pending |
| Health-gate watches broader cluster health, not just the affected app | User chose the wider option; exact mechanism (Flux-native vs Flagger/Argo Rollouts/custom controller) is still an open research question | — Pending |
| Health-gate = Flux-native conditions + small custom polling job, not Flagger/Argo Rollouts | Research closed this question: Flagger/Argo Rollouts solve canary traffic-shifting, not "revert the git commit" | ✓ Good |
| Build order: hard-exclusion gate → ARC runner (+ controller upgrade) → konflate → AI-review (advisory-only) → health-gate (proven via induced failure) → auto-merge wiring, enabled last | User confirmed this sequencing after research showed auto-merge-trigger and health-gate/auto-revert have no reference implementation (unlike the AI-review plumbing, which does) — still all v1, just sequenced so the safety net is proven before it's relied upon | — Pending |
| `ai-review.yaml`'s automatic `pull_request_target` trigger removed (kept `workflow_dispatch`-only), not restored this phase | Live incident during Phase 4: `pr-reviewer-action`'s comment-publish path (`gh pr comment --edit-last`) edits whichever comment its bot identity posted last with no content/marker matching; since it shares the default `github-actions[bot]` identity with `flux-diff.yaml`'s existing comment step, the first automatic dispatch silently overwrote an unrelated `flux-diff.yaml` comment on PR #1063 (content unrecoverable). User chose to remove the automatic trigger rather than accept recurring risk. | ✓ Good — contained a real incident; restoring automatic triggering (needs a dedicated bot identity, PAT or GitHub App) is tracked as required follow-up before Phase 4's "runs on every PR" success criterion is fully met |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-08-06 after Phase 4 completion*
