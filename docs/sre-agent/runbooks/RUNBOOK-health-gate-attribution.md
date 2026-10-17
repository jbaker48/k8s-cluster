# Health-gate attribution runbook

## Current operating boundary

The health gate builds a read-only attestation for target commit `T` and its first parent `P = T^1`, then compares the rendered objects with a stable live snapshot. A sample reads authenticated `main` before and after the sample. Seeing any SHA other than `T` marks the run superseded permanently. A failed read, an incomplete collection, changed object identity/resourceVersion, unsupported render, or malformed condition cannot establish health or authorize a revert.

Only fully supported active resources can contribute to a healthy result. The run summary reports the supported and unsupported HelmRelease counts and reason-code histogram. Evidence contains object identity, revisions, hashes, and reason codes; it does not include raw HelmRelease values.

In the current configuration, **automatic rollback is disabled by proof requirements**. `stalled_or_failed` is always empty. The producer evaluates the full attribution conjunction in code, but these two checks are fixed failures:

- `baseline-missing`: no trusted healthy pre-merge baseline is bound to `P` and the same HelmRelease UID.
- `merge-cas-unavailable`: the available GitHub PR merge operation cannot atomically require that `main` still has base SHA `T`.

Both codes remain visible in candidate-failure diagnostics when every other attribution predicate passes. There is no input, environment variable, or JSON field that can override either prerequisite. Such a candidate is inconclusive: it cannot create a revert proposal, charge the breaker, or emit a successful auto-revert event.

The fixed concurrency group `health-gate-main` serializes health-gate runs, with cancellation disabled. It does not serialize owner merges or other writers to `main`, so it does not satisfy the base-SHA merge condition.

GitHub keeps at most one pending run for the health-gate-main concurrency group when cancel-in-progress is false; if another run becomes pending, GitHub cancels the older pending run. A pending run cancelled this way executes no steps and has no verdict. Cancellation is not a pass, and a cancellation notification step is unnecessary because no step runs while the workflow is pending.

## Owner decision

The current evidence shows 0 of 61 HelmReleases attestable. Until that changes, every merge ends inconclusive and emits HealthGateInconclusive; Robusta forwards that Event as a Slack page. The owner must accept that notification volume or decide a notification policy. This change does not alter the policy or Robusta configuration.

## What can be attested

The bounded producer supports local reproducible renders and relevant objects whose effective inputs can be reproduced from Git. Supported HelmReleases use inline `spec.values`, resolvable literal post-build substitutions, and an exact SemVer tag from an OCIRepository whose current artifact revision supplies a full SHA-256 OCI digest. The producer independently binds the rendered HR and source specs to the live object UID and generation; the OCI attempt revision and digest must match the sampled source artifact.

Every run reports current counts. The initial design evidence observed 33 OCI-backed and 28 HelmRepository-backed releases (61 total); those figures are context, not a hard-coded inventory. A different live count or a new unsupported reason needs investigation before treating the summary as comparable.

| Shape or condition | Result |
|---|---|
| Exact supported OCI source, inline values, current matching HR/source specs and generations | Eligible for positive health evidence, subject to the whole-cluster checks |
| `valuesFrom`, unread or unresolved substitutions, SOPS-dependent desired data, post-renderers, preserved values, remote kubeconfig, unsupported admission/defaulting, or unknown spec fields | Unsupported; blocks whole-cluster healthy |
| New, deleted, recreated, ambiguously owned, or inventory-missing HelmRelease | Unsupported; no predecessor identity or complete ownership proof |
| OCI range, non-SemVer tag, stale/missing source artifact, or mismatched attempt digest | Unsupported; no current chart identity proof |
| `chartRef: HelmChart`, ExternalArtifact, or legacy `spec.chart` using HelmRepository/GitRepository/Bucket | Unsupported chart source |
| Leaf Kustomization whose build needs a remote resource/component or another unsupported build feature | Its owned releases receive `remote-build-dependency`; other owners are rendered independently |
| Root or intermediate Kustomization-producing render that is remote or unsupported | Every release receives `root-render-unsupported` |
| Changed UID/resourceVersion, malformed or duplicate conditions, stale generations, mixed revisions, or superseded `main` | Sample is invalid or superseded; no positive proof |

For a legacy HelmRepository-backed HR, the producer checks the live HelmRepository against its rendered source object and finds the generated HelmChart by its owner labels. It validates the generated chart name, version, and source reference against the rendered HR chart template, and cross-checks `status.helmChart` against that labeled object. The live artifact revision is retained only as diagnostic evidence. HelmRelease attempt status does not bind that generated chart digest to the HR attempt, so even matching chart version and HelmChart artifact digest remain unsupported and are never described as byte-level proof.

## Reading an inconclusive result

Use the reason histogram and per-object diagnostics to identify the missing proof. Common codes include:

- `superseded`: authenticated `main` moved during the sample; the earlier SHA is not reconsidered if `main` later returns to it.
- `root-render-unsupported` or `remote-build-dependency`: the desired graph could not be rendered locally under the reviewed subset.
- `unsupported-values`, `unsupported-substitution`, or `unsupported-chart-source`: the producer cannot bind effective inputs to the attempt.
- `baseline-missing` and `merge-cas-unavailable`: all other attribution checks may have passed, but rollback remains prohibited.
- `api-error`, `resource-changed-during-sample`, or an incomplete list: collect a fresh sample; do not infer health from the partial result.

Generic source, owner, or dependency failures are diagnostic. A recent condition timestamp, an old `RetriesExceeded`, an owner's attempted revision alone, a previously healthy cluster, or a Helm history entry is not enough to attribute a failure to `T`.

## Owner verification after merge

The implementation pass does not dispatch workflows or mutate cluster state. After the owner merges the reviewed change, first perform these read-only checks:

```bash
flux get ks -A
flux get hr -A
kubectl -n flux-system get gitrepository home-kubernetes -o json
kubectl get ocirepositories,helmrepositories,helmcharts -A
gh run list --workflow health-gate.yaml --commit <merged-sha>
```

The owner should confirm the actual health-gate credential's RBAC boundary through the updated `test-health-gate-rbac.yaml` workflow and verify the new source-resource checks ran. An administrator kubeconfig cannot prove the runner identity's permissions. The workflow verifies get/list/watch on GitRepository, OCIRepository, HelmRepository, and HelmChart, and checks that Secret/ConfigMap reads and source/Kustomization/HelmRelease mutations are denied.

Then use a supervised induced-failure and cleanup cycle:

1. Record a healthy starting state, current `main`, the selected app's original input, and breaker state.
2. Merge a deliberate failure through an owner-reviewed PR.
3. Capture sanitized source, owner, and HR progression before application, after target-input binding, and at terminal failure.
4. Expect an inconclusive result with explicit unsupported, baseline, or merge-CAS reasons. Confirm there was no auto-revert and no breaker increment. This proves fail-safe behavior, not full HEALTH-02 restoration.
5. Restore the original input through an owner-reviewed cleanup PR. Confirm stale failure conditions do not revert the cleanup commit.
6. Verify recovery, notification delivery, and unchanged breaker state. Do not substitute a historical application version for the current selected app.
7. Exercise supersession with an owner-controlled follow-up merge. Confirm the older run stays inconclusive and never retargets.

Preserve the existing exclusion-gate and revert-bot identity checks throughout. Do not use a synthetic condition, a user-supplied baseline, or a manual switch to simulate authorization.

## Requirements before automatic rollback can be restored

The owner must separately approve and prove both missing mechanisms:

1. A pre-merge baseline producer that runs before merge under the same enforced serialization, is bound to `P`, the prospective change, live identities, and effective inputs, and proves the same HR UID was healthy.
2. A server-enforced merge path that atomically requires base SHA `T` and covers every writer to `main`, including owner merges. A preflight read, workflow concurrency, the current `gh pr merge`, or detect-and-undo does not provide this property.

Only after a new reviewed design supplies both may the owner expect a current-input terminal failure to produce a revert-bot PR and conditionally land against exactly `T`. Only a confirmed landed revert charges the existing N=3/24-hour breaker. Stale or indeterminate operations must not retry against a new base. Run the documented three-cycle breaker proof only after these prerequisites exist, then perform explicit cleanup.

Stop and request a new design if implementation would require Secret/ConfigMap access, a new external service, controller mutation, NetworkPolicy expansion, chart-byte fetching, approximate digest reconstruction, broader normalization, or an unreviewed merge-enforcement mechanism.
