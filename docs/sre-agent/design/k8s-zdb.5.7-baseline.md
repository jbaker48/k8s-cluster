# k8s-zdb.5.7: trusted pre-merge baseline for health-gate rollback attribution

Status: **design for owner approval. Nothing here is implemented.**
Issue: `k8s-zdb.5.7` (parent `k8s-zdb.5`, discovered from `k8s-zdb.5.2`). Risk: high (health-gate and revert-bot path).
Inputs: the Astra and Opus design lanes for this issue (2026-10-11/12), the k8s-zdb.5.2 Astra design section 3, and PR #1141 read in place at head `934dbaef`.

## Summary

- **Where:** a per-PR producer runs before merge on `pull_request_target` (and on re-request). It observes the live cluster while `main == P` and the trusted `main` tree at `P`. It never checks out, renders or executes PR content. A scheduled snapshot of `main` is rejected because it cannot be bound to the prospective change.
- **Trust root:** a check run named `Health Baseline` on the PR head `H`, published by a new dedicated `health-baseline` GitHub App. The 5.8 ruleset makes it a required check pinned to that App's `integration_id`, with strict up-to-date, squash-only merges and no bypass actors. The record is canonical JSON in the check run output, hashed and bound to `P`, `H`, the PR, producer run and per-HR UIDs.
- **Verification:** after merge, the health-gate trusts only what it cannot recompute. It locates the record through `T -> PR -> H -> check run (pinned App id)`, then requires `T^1 == record.P`, `tree(T) == tree(H)`, `H` not behind `P`, a fresh record (TTL), the same HR and source UIDs live, and desired-spec fingerprints at `P` that match its own render. Any failure yields inconclusive: no revert, no breaker charge.

This design can never authorize a revert on its own. `server_enforced_base_sha_merge_cas` stays `False` until k8s-zdb.5.8 is proven live, and the runbook in PR #1141 records 0 of 61 HelmReleases attestable today (`docs/sre-agent/runbooks/RUNBOOK-health-gate-attribution.md` at `934dbaef`). A baseline for an unsupported HR is `unsupported` and never counts as healthy. Expect zero rollback authorizations until HR support grows.

## Current state (PR #1141 at 934dbaef)

- `scripts/health-gate-attest.py:1148-1172` hard-codes `healthy_premerge_baseline_same_hr_uid: False` and `server_enforced_base_sha_merge_cas: False`, and emits `baseline-missing` and `merge-cas-unavailable`.
- `.github/workflows/health-gate.yaml:300-319` (`candidate_owner_exception`) requires both checks to be exactly `false`, so changing either one changes jq behavior as well as Python.
- The gate runs on push to `main`, concurrency group `health-gate-main` without cancellation, on `k8s-cluster-ci`, environment `health-gate`, `contents: read`. It renders `T` and `P = T^1` from trusted trees. The revert-bot token exchange is at `health-gate.yaml:1022-1031`.
- Runner RBAC (`kubernetes/apps/arc-runners/k8s-cluster-ci/app/rbac.yaml`) is ClusterRole `health-gate-reader`: get/list/watch on KS, HR, GitRepository, OCIRepository, HelmRepository and HelmChart, plus `create` on events.
- The repository is **public** and currently allows merge, squash and rebase merges. No ruleset is applied.

## 1. Where and when the baseline is produced

**Decision: a pre-merge producer per PR, evaluated against the head `H` with base `P` = current `main`.**

New workflow `.github/workflows/health-gate-baseline.yaml`:

- Triggers: `pull_request_target` on `main` (opened, synchronize, reopened, ready_for_review) and `check_run: rerequested`, limited to the App's own check. The second trigger lets a human or the 6.1 auto-merge enabler refresh a stale baseline without a push.
- Only same-repository PRs (`head.repo.id == repository.id`) get a record. Fork PRs get a `neutral` check with code `baseline-fork-ineligible`, which keeps them mergeable by a human and never revert-eligible.
- Concurrency: group `health-gate-baseline-pr-<number>`, cancel-in-progress true. This is only duplicate-work control. Serialization comes from the ruleset.

Collection steps (in-cluster runner):

1. Authenticated read of `main`: call it `P`. Require `compare/P...H` to report `behind_by == 0`. If `H` is behind, publish `neutral` with code `pr-behind-main`; strict mode blocks that merge anyway.
2. Check out **`P` only** with `persist-credentials: false`, render it with the existing pinned render path, and take two complete live samples with the same pagination, stability and identity rules as the gate.
3. Require GitRepository `flux-system/home-kubernetes` to show artifact `main@sha1:P` and the root KSs to have applied `P`.
4. Evaluate each HR with the **same** healthy predicate the gate uses for target `T`, with target `P`.
5. Read `main` again. If it is not `P`, publish `neutral` with code `superseded`.

Observation window target is at most 120 seconds.

### Why this is "before the merge, under enforced serialization"

Strict up-to-date plus a required, App-pinned check on the latest `H` means a merge can happen only while `H` contains the tip of `main`, and only after a baseline was posted on that exact `H`. When `main` moves, `H` falls behind; updating the branch creates `H'`, which triggers `synchronize` and a fresh baseline. The gate still checks `T^1 == record.P`, because strict mode alone permits a fast-forward of `main` to a commit already inside `H`.

| Merge path | Result |
|---|---|
| Squash | `T^1 = P`, `tree(T) = tree(H)` when `H` contains `P`. **Allowed and the only enabled method.** |
| Merge commit | Safe in principle (`T^1 = P`, `T^2 = H`), but disabled to keep one verification path. Owner question 3. |
| Rebase merge | `T^1` is a replayed commit, not `P`. Always inconclusive. **Disabled** via `allowed_merge_methods: ["squash"]`. |
| Direct push, multi-commit push | No PR or no record. Inconclusive. Blocked by the ruleset's PR requirement. |
| Owner bypass | May skip strict mode. Inconclusive and never auto-revertable. Owner question 4. |
| Force push to `main` | Blocked by `non_fast_forward`. This also makes "`main == P` at observation end" imply "observed before the merge". |

### Freshness

The gate requires `observation.ended_at <= merged_at`, `check_run.completed_at <= merged_at`, and `merged_at - observation.ended_at <= BASELINE_TTL`. Recommended TTL: **600 seconds** (owner question 2). GitHub does not expire checks, so a stale baseline never blocks a merge; it only removes revert eligibility. The 6.1 auto-merge enabler re-requests `Health Baseline` as its last step, so GitHub auto-merge fires within seconds of a fresh observation. Humans use "Re-run".

## 2. Trust root, storage and verification

**Decision: a check run from a dedicated `health-baseline` GitHub App, required and pinned by `integration_id` in the 5.8 ruleset.**

| Option | Who can forge it | Verdict |
|---|---|---|
| Actions check from `GITHUB_TOKEN` | Any same-repo PR author: a `pull_request` workflow running PR-modified YAML posts under the same GitHub Actions integration. | Rejected |
| AI-review App (6.4) | It processes attacker-controlled PR text with an LLM; prompt injection could reach a check-writing token. 6.4 also scopes it without `checks`. | Rejected |
| Revert-bot App | Mixes the authorizer with the actor and owner-only credentials. | Rejected |
| Sigstore / GitHub artifact attestation | Strong provenance and free on a public repo, but it cannot be a required check by itself, and signing an untrusted producer proves nothing. | Optional extra provenance, not the authorization root |
| **Dedicated App check run** | Only holders of the App key (the owner/admins), a compromised trusted runner, or a merged change to `main`'s workflows. | **Chosen** |

This design does not defend against a malicious owner or administrator.

Storage: the record is canonical JSON in the check run `output.text` (limit 65,535 characters), with an embedded `record_sha256`, plus the same bytes uploaded as an Actions artifact (30-day retention) for audit. The check run is authoritative; the artifact is a copy. If the record does not fit in `output.text`, the producer publishes `neutral` with `baseline-oversize` and the implementer stops and escalates.

### Separation of collection and publication (both lanes agree)

The workflow has two jobs:

- **collect** on `k8s-cluster-ci`, environment `health-gate-baseline`, holds only the read-only baseline kubeconfig. It emits the record and its digest.
- **publish** on a GitHub-hosted runner, environment `health-gate-baseline-publish`, holds only the App key. It validates the record's schema, digest and bindings (repository, PR, `H`, `P`, run id and attempt), mints the App token, and posts the check. It has no Kubernetes credential and no PR checkout.

Both environments restrict deployment branches to `main`, so only `pull_request_target` and `check_run` runs (which execute `main`'s YAML) can obtain their secrets. Never use repository-level secrets for either credential.

### How the gate locates and verifies the record

Push events only; a `workflow_dispatch` run of the gate skips verification and reports `baseline-missing`. There is no input flag, uploaded JSON or boolean override.

1. `T` is a full 40-character lowercase SHA with exactly one parent; `P := T^1`.
2. `GET commits/T/pulls` returns exactly one merged PR with base `main` and `merge_commit_sha == T`. `H := pull.head.sha`.
3. `tree(T) == tree(H)` via API reads (no checkout of `H`).
4. `compare/P...H` reports `behind_by == 0`.
5. `GET commits/H/check-runs?check_name=Health Baseline&app_id=<pinned>`: `app.id` equals the App id **pinned as a literal in the gate YAML** (not a repository variable), `head_sha == H`, completed, conclusion `success`, `completed_at <= merged_at`. Choose the newest run whose record has `P == T^1`; conflicting qualifying records yield `baseline-unverifiable`.
6. The record hash, schema, repository, PR number, `H` and `P` match.
7. The producer run in the record exists, ran `.github/workflows/health-gate-baseline.yaml` from `main` on an allowed event, and its tool versions equal the gate's pinned versions.
8. TTL check (section 1).

The gate then recomputes rather than trusts:

- each HR's `desired_spec_fp_P`, from its own cached render of `P`;
- the live HR UID, which must equal the record UID in both gate samples, and the source UID;
- live generation at or above the record generation;
- the healthy predicate itself, re-evaluated over the saved allowlisted status evidence, rather than trusting `state: "healthy"`.

## 3. Binding: record schema `health-baseline/v1`

Strict schema: reject unknown fields, duplicate keys, malformed identifiers, duplicate objects and oversized records.

```text
{ schema: "health-baseline/v1",
  repository: {id, full_name},
  pr: {number, head_repository_id, head_sha: H},
  git: {base_sha: P, base_tree_sha, head_tree_sha, behind_by: 0},
  main_reads: [{phase: "start", sha: P}, {phase: "end", sha: P}],
  observation: {started_at, ended_at, samples: 2, sample_valid, reason_codes: []},
  producer: {workflow_path, workflow_sha, run_id, run_attempt, event,
             script_sha256, tools: [{name, version, sha256}]},
  root: {gitrepository_uid, artifact_revision: "main@sha1:P", artifact_digest,
         root_ks: [{name, uid, generation, last_applied_revision}]},
  helm_releases: [{
    namespace, name, uid, generation, resource_version,
    owner: {namespace, name, uid, generation, last_applied_revision},
    source: {kind, namespace, name, uid, generation, artifact_revision, artifact_digest},
    desired_spec_fp_P, chart_revision, attempted_config_digest, history_head_digest,
    evidence: {conditions_allowlisted, observed_generation, attempted_generation},
    state: "healthy" | "not_healthy" | "unsupported" | "inconclusive",
    reason_code }],
  counts: {total, healthy, not_healthy, unsupported, inconclusive},
  record_sha256 }
```

- No raw values, Secret or ConfigMap data, or condition messages.
- `state: "healthy"` requires `sample_valid`, both main reads equal to `P`, and the full gate healthy predicate at target `P`, within the existing supported subset. Normalization is not broadened.
- "Live state at `T^1` matched the baseline" means the observation was taken while both `main` and the cluster were at `P` (main reads, root artifact, owner applied revision), and the gate re-establishes the same UIDs and the same desired fingerprint at `P`. It cannot prove uninterrupted health between observation and merge; the TTL bounds that residual risk.
- Binding to the prospective change is by `H` and tree equality. The gate already computes changed inputs between `P` and `T` from trusted trees, and `tree(T) == tree(H)` makes that the PR's change.
- In `attest()`, `healthy_premerge_baseline_same_hr_uid` becomes true **per HR** only when the verifier output for that `namespace/name` is `verified` and its UID equals the live UID; `attest()` re-checks the UID itself. Never a global boolean.

## 4. Ruleset and auto-merge

Required checks on `main`, prepared by 5.8 as exact JSON for the owner to apply:

| Context | Source |
|---|---|
| `Exclusion Check` | GitHub Actions integration |
| `Health Baseline` | `integration_id` = `health-baseline` App |
| `AI PR Review` | AI-review App, once 6.4 lands |

5.8 must inventory the actual (matrix-expanded) context names before finalizing. Other rules: `strict_required_status_checks_policy: true`, `pull_request` with `allowed_merge_methods: ["squash"]`, `non_fast_forward`, `deletion`, optionally `required_linear_history`, and no bypass actors (owner question 4).

### Per-HR semantics: no merge deadlock

- `Health Baseline` concludes **`success` for any well-formed, authentic record**, including one with unhealthy, unsupported or inconclusive HRs. An HR that was not healthy at `P` simply cannot be auto-reverted for `T`.
- Producer error, timeout, cluster API failure, superseded `main`, behind PR, fork PR and oversize record publish **`neutral`** with a reason code. `neutral` satisfies a required check, so the PR stays mergeable; the gate treats it as `baseline-missing`.
- The only merge-blocking state is "check absent or pending", which means an App, publisher or runner outage (owner question 6).

### Auto-merge (6.1)

6.1 keeps its own conditions: AI-review verdict, exclusion-check job `success` and `excluded == 'false'` exactly (fail closed), all required checks. It does not read the baseline's contents. Its only obligation here is to re-request `Health Baseline` last, so the baseline is fresh at merge.

### Revert PRs

Revert-bot PRs receive the same check because it is required. Their baseline will usually record the broken HR as `not_healthy`, so a repair is never auto-reverted against a nonexistent healthy predecessor. In addition, the gate never authorizes a rollback of a commit whose PR is an automated revert (`revert-of-revert-prohibited`, identified by the existing D-03 provenance check). 5.8 owns the rule that a revert proposal whose base advanced is rejected, never refreshed into renewed authorization.

## 5. Failure modes and fail-safe defaults

Every row yields **inconclusive attribution: empty `stalled_or_failed`, no revert token exchange, no breaker charge**, with a distinct diagnostic code. There is no fallback to older records, post-merge polls, condition timestamps or Helm history.

| Failure | Code |
|---|---|
| No PR for `T`, multiple PRs, direct push, bypass merge that breaks `T^1` or tree equality | `baseline-no-pr` / `baseline-binding-mismatch` |
| No check from the pinned App, wrong App id, `neutral`, pending | `baseline-missing` |
| Hash, schema, tool-version or producer-run mismatch; unparsable; conflicting records | `baseline-unverifiable` |
| `P != T^1`, `H` mismatch, tree mismatch, `H` behind `P` | `baseline-binding-mismatch` |
| TTL exceeded, check or observation completed after merge | `baseline-stale` |
| HR absent from record, `state != healthy`, fingerprint mismatch | `baseline-hr-not-healthy` |
| HR or source UID changed (recreated) | `baseline-uid-mismatch` |
| GitHub API error or App outage during verification | `baseline-api-error` (no retry beyond the existing bounded window) |
| `main` moved during observation | producer publishes `neutral` `superseded`; nothing matches `T^1` |
| Force push of `H` after the check | new `H` requires a new check; an old record never matches `pull.head.sha` |
| Commit from an automated revert PR | `revert-of-revert-prohibited` |
| Gate `workflow_dispatch` run | `baseline-missing` |

The existing global competing-failure veto (`scripts/health-gate-attest.py:1137-1146`) is preserved. Per-HR baselines improve merge availability; they do not weaken post-merge attribution.

Ruleset reads cannot prove an administrator never disabled enforcement temporarily. An empty bypass list and trusted owner administration are deployment invariants; detected drift disables authorization.

## 6. RBAC and credentials

- **Kubernetes:** new ServiceAccount `health-gate-baseline` with ClusterRole `health-gate-baseline-reader`: get/list/watch on KS, HR, GitRepository, OCIRepository, HelmRepository and HelmChart. **No** event create, Secrets, ConfigMaps, pods/exec or mutations. Its kubeconfig is an environment secret in `health-gate-baseline`. The existing `health-gate` credential is not reused, because it can create Events and its environment is not branch-restricted for PR events. This is a cluster-wide, additive RBAC change shipped by GitOps PR, owner-merged, and proven by negative checks in `test-health-gate-rbac.yaml`.
- **GitHub, producer:** `GITHUB_TOKEN` with `contents: read`, `pull-requests: read`, `actions: read`. The App token exists only in the publish job.
- **GitHub, gate:** add `checks: read`, `pull-requests: read`, `actions: read` to the health-gate job.
- **New App (owner action):** `health-baseline`, repository-scoped, `checks: write`, `contents: read`, `pull_requests: read`. App id and private key stored only in environment `health-gate-baseline-publish`.
- **Revert-bot: not touched.** No change to its App, credentials, permissions, environment or activation. Any such change is owner-only and out of scope.
- **PR-triggered jobs on the in-cluster runner (public repository):** `pull_request_target` runs `main`'s YAML. The collect job checks out only `P` and never `H`, `refs/pull/*` or PR scripts, actions, hooks, submodules, `.mise.toml`, plugins or remote bases (`local_graph_error` already rejects remote references). PR number and SHAs pass through `env:` and are validated (`^[0-9]+$`, 40 lowercase hex). PR title, body and branch name are never read. Tools come from the existing pinned, checksum-verified bootstrap. A static test greps both workflows for `refs/pull`, `head.ref`, `pull_request.title` and any checkout of `H`. If ARC isolation cannot guarantee that a same-repo `pull_request` workflow cannot obtain the baseline environment secrets, stop for separately scoped runner hardening.
- **Exclusion gate:** add `.github/workflows/health-gate-baseline.yaml`, `scripts/health-gate-baseline.py` and `scripts/health-gate-attest.py` to `.github/exclusion-gate.yaml` so changes to them always need a human merge (owner question 5).
- **Capacity:** every same-repo PR synchronize uses one `k8s-cluster-ci` slot for roughly 1-5 minutes (owner question 7).

## 7. Test and fixture plan

New runner `scripts/test-health-gate-baseline.sh`, in the style of `scripts/test-health-gate-classify.sh`: extract the real step shell by step ID, stub `gh`, `kubectl`, `git`, clock and sleep, run the real producer (`observe`) and verifier (`verify`), and fail on any unexpected write or network call. Fixtures live in `.github/health-gate/fixtures/baseline/`.

- **Positive (non-vacuous):** `squash-merge-healthy-same-uid` sets `healthy_premerge_baseline_same_hr_uid=true` for exactly one HR while `stalled_or_failed` stays empty (merge CAS still false).
- **Binding corruption, one field each:** repository, PR, `H`, `P`, tree, HR UID, owner UID, source UID, artifact digest, desired fingerprint, tool version, producer run, App id.
- **Topology:** `rebase-merge-parent-mismatch`, `merge-commit-disallowed`, `direct-push-no-pr`, `multiple-prs-for-T`, `tree-mismatch`, `head-force-pushed-old-record`, `pr-behind-main`, `main-moved-during-observation`, `fast-forward-into-head`.
- **Provenance:** `wrong-app-id-same-name`, `actions-integration-forgery`, `pr-modified-producer-yaml`, `artifact-substitution`, `hash-tamper`, `conflicting-records`, `oversize-record`, `fork-pr`.
- **Time:** `stale-ttl`, `ttl-boundary`, `completed-after-merge`, `observation-after-merge`.
- **Cluster:** `partial-list`, `resourceversion-churn`, `api-timeout`, `hr-recreated-uid-change`, `source-uid-change`, `hr-not-healthy-at-P`, `hr-unsupported-at-P`, `hr-absent-from-record`, `unrelated-hr-unhealthy` (check `success`, only that HR ineligible).
- **Paths:** `revert-pr-target`, `workflow-dispatch-no-baseline`, `api-error-during-verify`, `neutral-conclusion`.
- **Parity:** the producer's per-HR healthy result must equal the jq classifier's verdict on the same snapshot, because the predicate is evaluated in both places.
- **Static:** the no-PR-content grep above, and malicious render paths, symlinks and plugins rejected.

Every negative fixture asserts all three: empty candidates, no token exchange, zero breaker delta.

Owner-supervised live proofs (offline mocks cannot prove server enforcement): wrong-App check rejected by the ruleset, stale-base merge rejected for squash, direct and force pushes denied, auto-merge firing after a re-requested baseline, and the server-side "base branch was modified" behavior on a deliberate race.

## 8. Phased implementation plan

Prerequisites: PR #1141 merged (implementation starts from its merged SHA); owner approval of this design; the owner creates the `health-baseline` App and both environments; 5.8 ruleset prepared.

| Phase | Actor | Files | Notes |
|---|---|---|---|
| 0 | Luna | `.github/health-gate/main-ruleset.json` (new, shared with 5.8); `docs/sre-agent/runbooks/RUNBOOK-health-gate-attribution.md` (mod) | Exact ruleset JSON and `gh api` command for the owner; runbook adds the baseline contract, codes, TTL, bypass caveat. |
| 1 | Luna | `scripts/health-gate-baseline.py` (new: `observe`, `verify`); `.github/health-gate/baseline.schema.json` (new); `scripts/health-gate-attest.py` (mod: `--baseline-verification <file>`, per-HR check and UID recheck, no boolean path) | Offline only. |
| 2 | Luna | `.github/health-gate/fixtures/baseline/*.json` (new); `scripts/test-health-gate-baseline.sh` (new); `scripts/test-health-gate-classify.sh` (mod: parity) | Must pass before any workflow change. |
| 3 | Luna | `.github/workflows/health-gate-baseline.yaml` (new); `.github/workflows/health-gate.yaml` (mod: permissions, push-only verify step before polling, `candidate_owner_exception` accepts a verified baseline) | **Diagnostic mode:** the verifier runs and reports, `server_enforced_base_sha_merge_cas` stays `False`, so authorization stays at 0. |
| 4 | Luna PR, owner merge | `kubernetes/apps/arc-runners/k8s-cluster-ci/app/rbac.yaml` (mod: new SA and ClusterRole); `.github/workflows/test-health-gate-rbac.yaml` (mod); `.github/exclusion-gate.yaml` (mod, owner-approved) | Cluster-wide, additive. |
| 5 | Owner | App install, environment secrets, ruleset apply, live proofs | Activation of rollback remains a separate, reviewed change after 5.8 is proven. |

Every phase gets fresh Luna, Astra and Opus review and stops at an owner PR. Validation: `actionlint` on the changed workflows, `shellcheck` on both test runners, both fixture runners, `python3 -I -m py_compile scripts/health-gate-baseline.py`, `task validate:yaml`, `task validate:consistency`, and `kustomize build kubernetes/apps/arc-runners/k8s-cluster-ci/app`.

Stop and escalate if: the record cannot fit a check run; matching the gate predicate needs any relaxed predicate; a step needs the revert-bot App, Secret/ConfigMap RBAC or a checkout of `H`; runner isolation cannot protect the environment secrets; any live proof fails.

Rollback of cluster-wide pieces: disable the ruleset (`enforcement: "disabled"`) from a saved export; revert the RBAC PR (additive, pruned); remove `Health Baseline` from required checks **before** removing the workflow, so no PR waits on a check that never comes. Without the check, the gate returns to `baseline-missing`.

## Resolved disagreements between the Astra and Opus lanes

| Topic | Astra | Opus | Resolution |
|---|---|---|---|
| Check target commit | Publish only on the test-merge commit `M`, parents `[P,H]` | Publish on `H`; verify `tree(T) == tree(H)` and `T^1 == P` after merge | **Opus.** Required checks are evaluated on the head; `M` is regenerated by GitHub and its check precedence is undocumented for App checks. Binding `P` inside the record plus post-merge `T^1` and tree checks gives the same guarantee with documented behavior. |
| Rendering PR content pre-merge | Render `P` and `M^{tree}` on a GitHub-hosted job, as data | Never render PR content; render only `P` | **Opus.** The gate already renders `P` and `T` from trusted trees after merge, and tree equality binds `T` to the PR. Rendering PR trees pre-merge adds attack surface for no extra guarantee. |
| Storage | Artifact as record, App check carries its digest | Record in check run `output.text` | **Combined.** Check run output is authoritative (single lookup, App-authenticated); the artifact is an audit copy. Oversize stops and escalates. |
| Credential separation | Separate collect and publish surfaces; App key never on the in-cluster runner | App token only in the final step of one job | **Astra.** Two jobs: in-cluster collect with kubeconfig only, GitHub-hosted publish with App key only. |
| Producer failure | No record keeps the check pending and blocks merge; API errors give an authentic inconclusive record | Errors publish `neutral`, mergeable | **Opus, with Astra's semantics.** Authentic inconclusive outcomes publish `neutral`; only a total App/publisher outage blocks. |
| Merge methods | Merge and squash | Squash only | **Squash only** for one verification path; matches existing `(#NNNN)` squash history. Owner question 3. |
| TTL | 600 s | 900 s, plus re-request last in auto-merge | **600 s, with re-request last.** Owner question 2. |
| Bypass actors | None | Owner `pull_request`-mode bypass acceptable; bypass merges never revertable | **None recommended**, since a bypass also defeats 5.8's merge CAS. Owner question 4. |
| Revert PRs | Same check; repair is not revertable because its baseline is unhealthy | Same check plus explicit `revert-of-revert-prohibited` | **Both.** |
| Producer provenance | Verify producer run, workflow identity and event via Actions API | Record workflow path and tool versions | **Both:** record fields plus API verification of the run. |
| File names | `health-gate-baseline.yaml`, `main-ruleset.json` under `.github/health-gate/` | `health-baseline.yaml`, ruleset under `docs/` | `health-gate-baseline.yaml` and `.github/health-gate/main-ruleset.json`. |

## Owner questions

1. Approve a **third GitHub App** (`health-baseline`, `checks: write`) and two new environments? The alternative is a GitHub artifact attestation pinned to the signer workflow, which cannot itself be a required check.
2. Baseline TTL: accept **600 seconds** from observation end to `merged_at`, with 6.1 auto-merge re-requesting the baseline as its last step?
3. Merge methods: **squash only** (recommended), or also merge commits?
4. Ruleset bypass: **no bypass actors** (recommended)? If the owner keeps a bypass, every bypass merge is permanently non-revertable and weakens 5.8.
5. Add the baseline workflow, baseline script and attest script to `.github/exclusion-gate.yaml`?
6. Accept that a `health-baseline` App or publisher outage blocks all merges until the owner intervenes (the alternative, a non-required check, makes baselines optional and forgeable by omission)?
7. Accept `k8s-cluster-ci` capacity for one baseline job per same-repo PR update, and a `neutral` (never revert-eligible) result for fork PRs on this public repository?
