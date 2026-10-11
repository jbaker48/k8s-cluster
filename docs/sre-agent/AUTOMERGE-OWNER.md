# Auto-merge owner

Decision date: 2026-10-11
References: `k8s-19y`, `k8s-2cc`

The AI-review pipeline is the single owner of auto-merge: the deterministic
exclusion gate, AI review, then health gate with auto-revert. Auto-merge go-live
is tracked in epic `k8s-zdb.6` and issue `k8s-zdb.6.1`. Until that ships, the
owner merges PRs manually.

Renovate only opens PRs. Its config explicitly disables auto-merge, limits open
PRs to 10 concurrent and 2 per hour, keeps the weekend schedule, and waits three
days for major, minor, and patch releases. `timestamp-optional` avoids holding
updates forever when a release timestamp is missing; Renovate silently stalled
for five months before (`k8s-ykh`).

Renovate requires dependency dashboard approval for Talos, Kubernetes, Cilium,
and Rook-Ceph upgrades. Rook-Ceph is high-risk and owner-only. These approvals
complement `.github/exclusion-gate.yaml`; that deterministic exclusion remains
authoritative.

## ARC runner image tracking

Runner images live in inline values in Flux HelmReleases, so the custom manager
in `.github/renovate.json5` tracks their stock and forked image forms. GitHub
enforces a rolling minimum runner version, and an outdated pin can wedge ARC
0.14.2 in `Outdated`, taking self-hosted CI down. See upstream
actions/actions-runner-controller issues [#4595](https://github.com/actions/actions-runner-controller/issues/4595),
[#4596](https://github.com/actions/actions-runner-controller/issues/4596), and
[#4600](https://github.com/actions/actions-runner-controller/issues/4600).

The stock matcher is active in `k8s-cluster-ci` and `ha-restarter`; keep it
alongside the `ghcr.io/falcondev-oss/actions-runner` matcher. Keep the falcondev
fork pinned by both tag and digest so Renovate updates them together.
