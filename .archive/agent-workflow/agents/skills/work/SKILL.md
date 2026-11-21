---
name: work
description: Finish a ready non-owner k8s-cluster Beads issue through Luna implementation, validation, fresh-context review and an owner-ready PR. Use for a named issue, epic, count or next ready issue; use autopilot for a queue loop.
---

# Work

Read `docs/dynamic-workflow.md` (routing, token budget, completion and authority) and the matching domain in `docs/workflow-specialists.md`.

## Select or resume

```bash
bd ready --exclude-type=epic --exclude-label=human,needs-human,owner-decision,autopilot --limit=0 --json
```

Order by `rank-NN` label, else priority. A named epic restricts selection to its descendants; a count limits distinct issues. Read `bd show <id>` and `bd comments <id>`. Inspect unfinished in-progress work first; adopt only after checking worktree, branch, PR, CI and remaining acceptance clauses. A shared assignee or old timestamp is not proof of abandonment.

## Implement and validate

Base: `origin/main`, isolated worktree per issue. Every edit goes to Luna: `scripts/lane.sh luna <worktree> <packet-file>`. Diagnosis that survived Luna → Sol (`lane.sh sol`); high-risk design or a diagnosis that survived Sol → Astra (`lane.sh astra`) and/or Opus (`lane.sh opus`). Research → `lane.sh research`. Normal tools run builds and validation. Reference docs in packets, never paste them.

Verify the premise against the live cluster (read-only `kubectl`/`flux get`) before building. Render with `kustomize build`, then `task validate:all`.

High risk is any path in `.github/exclusion-gate.yaml`, rook-ceph, `*.sops.yaml`, or anything weakening exclusion-gate/health-gate/NetworkPolicy/CI. It needs Luna review plus Astra (`astra-review`) plus Opus (`opus-review`) and stops at an owner PR.

## Review and finish

Fresh-context Luna reviews the exact diff (`lane.sh review`). Critical/high or `needs-attention` returns to Luna; after two rounds Astra adjudicates (`ASTRA_EFFORT=xhigh`). Open a PR with a conventional commit and `Refs: <id>`. Agents do not merge: the owner merges until epic k8s-zdb.6 (auto-merge go-live) ships. After merge, confirm Flux reconciled and the health-gate passed before closing: a merged PR is not a deployed PR.

Record every transition with the shared durable handoff from `docs/dynamic-workflow.md`. Close an issue only with evidence for every acceptance clause.
