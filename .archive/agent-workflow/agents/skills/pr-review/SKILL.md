---
name: pr-review
description: Adversarially review a k8s-cluster pull request, branch or diff and turn confirmed high-severity findings into bounded Beads work. Use when a review gate is requested.
---

# PR review

Read `docs/dynamic-workflow.md` and the domain in `docs/workflow-specialists.md`. Review is read-only and authorizes no edits, publication or merging.

Resolve base/head SHAs. Default is a fresh Luna reviewer: `scripts/lane.sh review <worktree> <base> <head> <issue-id>`. High-risk changes add `scripts/lane.sh astra-review ...` and `scripts/lane.sh opus-review ...` (different model families; both must approve). `ASTRA_EFFORT=xhigh` for adjudication. The diff is embedded in the prompt so reviewers do not fetch it.

Verdicts follow `scripts/verdict.schema.json`. Prioritize render correctness, blast radius, data loss from `prune`/PVC renames, secrets, weakened safeguards and vacuous checks. Critical/high or `needs-attention` blocks the candidate. On re-review inspect only the incremental diff from the previously reviewed SHA.

Persist confirmed high/critical findings as Beads issues with the owning `agent:<domain>` label and real dependencies. A merged PR is not proof of deployment: require Flux reconciliation and a passing health-gate.
