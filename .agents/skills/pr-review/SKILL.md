---
name: pr-review
description: Adversarially review one k8s-cluster PR, branch or diff, or sweep every open PR into a tiered merge/hold/close report, and turn confirmed high-severity findings into bounded Beads work. Use when a review gate or PR guidance is requested.
---

# PR review

Read `docs/dynamic-workflow.md` and the domain in `docs/workflow-specialists.md`. Review is read-only and authorizes no edits, publication or merging. Never mutate the reviewed tree.

## Scope

Usage: `/pr-review <PR number | branch | --uncommitted | --all-open>`.

- PR: `gh pr view <n> --json baseRefName,headRefName,headRefOid,title,body,files`; fetch so the head SHA exists locally. A PR whose body says "stacked on #N" reviews against that PR's head, not `main`.
- Branch: `git diff origin/main...<branch>` after confirming its intended base.
- `--uncommitted`: `git diff HEAD` plus untracked files. Another session may own them.
- `--all-open`: the sweep below.

Record base/head SHAs. Stop if the diff is empty (an empty Renovate PR is a close recommendation, not a review). Start from `git diff --stat`; read changed hunks with context and open code outside them only to confirm or refute a specific suspected failure.

## Reuse before reviewing

Lane output lives in `.lane-out/<issue>/` (also `policy*/`, `designs/`). Before dispatching, look for verdicts that name the current head SHA. An approval at the exact head from the required lanes is reused, not re-run. A newer head needs only the incremental diff from the last reviewed SHA. Find an existing `review` epic for the PR/sweep and reuse its unresolved findings, rechecking them on the new head, instead of filing duplicates.

## Lanes

- Ordinary: `scripts/lane.sh review <worktree> <base> <head> <issue-id>`.
- High risk (every `.github/exclusion-gate.yaml` category, rook-ceph, `*.sops.yaml`, anything weakening exclusion-gate/health-gate/NetworkPolicy/CI/review/renovate rules): add `astra-review` and `opus-review`; all three must approve. `ASTRA_EFFORT=xhigh` for adjudication.
- `lane.sh` needs a `k8s-` issue id. Use the PR's linked issue; for a PR without one (Renovate), use the review epic id.

The diff is embedded in the prompt so reviewers do not fetch it. Verdicts follow `scripts/verdict.schema.json`; read `verdict` and `severity | title` per finding, and open a body only to act on it.

## What to look for

Render correctness, blast radius, data loss from `prune`/PVC renames or deletions, secrets, weakened safeguards and vacuous checks. For dependency bumps also check:

- Upgrade path: skipped minors where the vendor supports only consecutive ones (Cilium, Rook, Kubernetes, Talos), and version-support matrices (Talos ↔ Kubernetes, Rook ↔ Ceph ↔ Kubernetes).
- Breaking changes in the upstream changelog against the values and features this repo actually uses (`grep` the keys; check live state read-only when a default changes).
- Coupled PRs that must land together or in order (bootstrap `helmfile.yaml` plus the app HelmRelease, controller plus runner sets, two PRs editing the same line).
- Evidence other open PRs rely on (a fix verified against chart version X is invalidated by a bump of X).
- Staleness: a months-old PR whose base no longer matches `main`, or that targets a version superseded upstream.

## Findings

Every finding needs `path:line`, a concrete failure scenario and a fix. The orchestrator reopens the code (and live state where relevant) behind every critical/high finding before reporting it, and refutes what does not hold. Critical/high or `needs-attention` blocks the candidate.

File each confirmed critical/high finding as a `bug` child of the review epic, with the owning `agent:<domain>` label, real dependencies, and **What**, **Why**, **Files**, **Steps**, **Verify**. Add a dependency from the implementation issue when the finding gates it. Mediums and lows go in the report only.

## Sweep (`--all-open`)

1. `gh pr list --state open --json number,author,title,isDraft,files,statusCheckRollup,createdAt`. Create one epic `Review: open PR sweep <date>` (label `review`) unless one is open.
2. Tier each PR. **A**: a high-risk path or a major version gets lanes as above (after the reuse check). **B**: owner PRs that are not high risk get one ordinary lane if no current verdict exists. **C**: patch/minor bumps of leaf apps get an orchestrator check (base still matches `main`, changelog, coupled PRs) and no lane. Drafts and "DO NOT MERGE" test PRs are listed, not reviewed.
3. Report one row per PR: recommendation (`merge`, `merge after <PR/step>`, `hold: owner decision`, `rework`, `close`), the reason in one line, and the finding id. Group by recommendation and give a merge order for coupled PRs.

## Close-out

A merged PR is not proof of deployment: require Flux reconciliation and a passing health-gate. If nothing critical/high was confirmed, close the review epic with the reason and the count of minor notes. Never close an epic with unresolved children from an earlier pass. Record the reviewed head SHA(s), verdict, finding ids, the fix and validation each needs, and who acts next. Under `$work`/`$autopilot`, return that packet to the orchestrator. Standalone, end with the exact `$work <finding-id>` or the remaining CI/owner/merge action.
