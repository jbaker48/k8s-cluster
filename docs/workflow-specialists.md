# k8s-cluster workflow specialists

The `agent:<name>` label selects a domain, not a model. Routing, authority and handoffs are in [dynamic-workflow.md](dynamic-workflow.md). Worker contracts live in `.codex/agents/` and `.claude/agents/`; packets name the domain and do not paste this document.

All workers stay in the named worktree and scope, report changed files, commands/results, unmet clauses and a precise next action, and never weaken a gate to pass.

| Label | Scope | Required validation | Risk |
|---|---|---|---|
| `agent:flux-apps` | `kubernetes/apps/**` (not rook-ceph, cilium) | `kustomize build` on the app and namespace dir; `task validate:consistency`; schema headers; `ks.yaml` required properties | ordinary |
| `agent:talos` | `kubernetes/bootstrap/talos/**` | `task talos:generate-config` render only; `task validate:all` | **high** |
| `agent:network` | Cilium, envoy-gateway, NetworkPolicy, external-dns, cloudflared | kustomize build; policy diff reviewed for blast radius | cilium **high**, rest ordinary |
| `agent:storage` | rook-ceph, openebs, volsync | kustomize build; PVC/Kustomization/HelmRelease/ReplicationSource names match | rook-ceph **high** |
| `agent:flux-core` | `kubernetes/flux/**`, `components/`, `templates/`, `bootstrap/helmfile.yaml` | `task validate:all`; `flux build ks` where possible | **high** |
| `agent:secrets` | `*.sops.yaml`, ExternalSecrets | edit only via `sops`; never print plaintext; ExternalSecret keys exist in Doppler | **high** for sops |
| `agent:ci-platform` | `.github/**`, `scripts/`, `.taskfiles/`, docs | actionlint; shellcheck; `task validate:yaml`; never widen permissions or loosen exclusion/health gates | safeguard edits **high** |
| `agent:sre-agent` | exclusion-gate, ai-review, health-gate, revert-bot | as ci-platform, plus the live proofs in `docs/sre-agent/` | **high** |

High-risk = any path in `.github/exclusion-gate.yaml` plus rook-ceph, sops files, and any change weakening exclusion-gate, health-gate, NetworkPolicy, CI or review. It gets Luna + Astra + Opus review and stops at an owner PR.

## Validation commands

```bash
kustomize build kubernetes/apps/<ns>/<app>/app >/dev/null
task validate:all
task validate:consistency
```

## Live read-only evidence

```bash
export KUBECONFIG=$PWD/kubeconfig
flux get ks -A | grep -v True
flux get hr -A | grep -v True
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl top nodes
```

Never run `kubectl apply/delete/patch/scale/rollout`, `flux reconcile/suspend/resume`, `talosctl` mutations, or print decrypted secrets from a worker lane.

## Review

`reviewer` is independent and read-only, examines every changed file, cites `file:line`, and returns the verdict JSON in `scripts/verdict.schema.json`. `scout` gathers facts and options. Astra and Opus return bounded packets or verdicts, never patches.
