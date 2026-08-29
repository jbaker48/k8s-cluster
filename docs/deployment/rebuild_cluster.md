# Complete Cluster Rebuild Guide

This guide covers rebuilding the Kubernetes cluster from scratch, including all prerequisites, the exact sequence of operations, and troubleshooting common issues.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Pre-Rebuild Checklist](#pre-rebuild-checklist)
3. [Cluster Teardown](#cluster-teardown)
4. [Bootstrap Sequence](#bootstrap-sequence)
5. [Post-Bootstrap Verification](#post-bootstrap-verification)
6. [Troubleshooting](#troubleshooting)
7. [Dependency Reference](#dependency-reference)

---

## Prerequisites

### Required Tools

All tools are managed by mise. Install them with:

```bash
mise trust
mise install
```

Every tool the tasks call is declared in `.mise.toml`, including `kubectl`,
`talosctl`, `talhelper`, `flux`, `helm`, `helmfile`, `kustomize`, `sops`,
`age`, `yq`, `jq`, `task`, `kubeconform`, `yamllint`, `minijinja-cli`,
`stern`, `pre-commit` and `cloudflared`.

Confirm they resolve through mise and not a system package manager, since a
Homebrew binary earlier in `PATH` will shadow the pinned version:

```bash
mise doctor
mise which talhelper
```

### Required Files

Before rebuilding, ensure these files exist:

| File | Purpose | How to Create |
|------|---------|---------------|
| `age.key` | SOPS decryption key | Must exist from original setup |
| `.sops.yaml` | SOPS configuration | Should exist in repo |
| `kubernetes/bootstrap/talos/talsecret.sops.yaml` | Talos secrets | Generated on first bootstrap or restore from backup |
| `kubernetes/flux/vars/cluster-secrets.sops.yaml` | Cluster secrets | Must exist (encrypted) |

### Network Requirements

| Component | IP/Range | Purpose |
|-----------|----------|---------|
| Control Plane VIP | 10.20.0.250 | Kubernetes API endpoint |
| talos01 | 10.20.0.14 | Control plane node |
| talos02 | 10.20.0.15 | Control plane node |
| talos03 | 10.20.0.16 | Control plane node |
| Pod Network | 10.69.0.0/16 | Container networking |
| Service Network | 10.96.0.0/16 | Kubernetes services |

---

## Pre-Rebuild Checklist

### 1. Backup Critical Data

```bash
# Snapshot all VolSync-enabled apps
task volsync:snapshot NS=media APP=plex
task volsync:snapshot NS=home APP=home-assistant
# ... repeat for all apps with VolSync

# Verify backups completed
kubectl get replicationsources -A
```

### 2. Document Current State (Optional)

```bash
# Save current Flux state
flux get kustomizations -A > /tmp/flux-state.txt
flux get helmreleases -A >> /tmp/flux-state.txt

# Save PVC information
kubectl get pvc -A > /tmp/pvc-state.txt
```

### 3. Verify Secrets Are Accessible

```bash
# Test SOPS decryption
sops -d kubernetes/flux/vars/cluster-secrets.sops.yaml > /dev/null && echo "Secrets OK"

# Verify age key
test -f age.key && echo "Age key OK"
```

---

## Cluster Teardown

### Option A: Full Reset (Recommended for Clean Rebuild)

This resets all nodes to maintenance mode and wipes cluster state:

```bash
# WARNING: This destroys the entire cluster
task talos:reset
```

Wait for all nodes to reboot into maintenance mode (can take 2-3 minutes per node).

### Option B: Partial Reset (Keep Talos Secrets)

If you want to preserve Talos secrets for faster rebuild:

```bash
# Reset without wiping secrets
task talos:reset -- --force
```

### Cleaning Up Stuck Rook-Ceph Resources

If Rook-Ceph resources are stuck during teardown:

```bash
# Remove finalizers from stuck resources
task rook:remove-finalizers
```

### Wiping Ceph Data on Nodes

For a completely fresh Ceph cluster, you may need to wipe OSD disks. Connect to each node:

```bash
# Check which disks have Ceph data
talosctl -n 10.20.0.14 list /dev/disk/by-id/

# The Ceph disks will need to be wiped during Talos reset
# or manually cleared before rook-ceph-cluster deploys
```

---

## Bootstrap Sequence

The bootstrap follows a strict 3-phase sequence. **Do not skip phases or run out of order.**

### Phase 1: Bootstrap Talos

This phase provisions the Talos Linux OS layer and establishes the Kubernetes control plane.

```bash
task bootstrap:talos
```

**What happens:**
1. Generates `talsecret.sops.yaml` if it doesn't exist
2. Encrypts secrets with SOPS
3. Generates machine configurations from `talconfig.yaml`
4. Applies configuration to all nodes
5. Bootstraps etcd cluster
6. Generates kubeconfig

**Expected duration:** 3-5 minutes

**Verification:**
```bash
# Check nodes are responding
talosctl -n 10.20.0.14 health

# Nodes will show NotReady (no CNI yet)
kubectl get nodes
```

### Phase 2: Bootstrap Apps (Helmfile)

This phase deploys essential system components before Flux takes over.

```bash
task bootstrap:apps
```

**What happens:**
1. Waits for nodes to reach `Ready=False` state
2. **Creates privileged namespaces** (rook-ceph, observability, network, etc.)
3. Deploys Helmfile releases in order:
   - `prometheus-operator-crds` (observability)
   - `cilium` (kube-system) - CNI
   - `coredns` (kube-system) - DNS
   - `spegel` (kube-system) - Registry mirror
   - `flux` (flux-system) - GitOps controller
4. Waits for all nodes to become Ready

**Expected duration:** 5-10 minutes

**Verification:**
```bash
# Nodes should now be Ready
kubectl get nodes

# Cilium should be running
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium

# CoreDNS should be running
kubectl -n kube-system get pods -l app.kubernetes.io/name=coredns
```

### Phase 3: Bootstrap Flux

This phase configures Flux to take over GitOps management.

```bash
task bootstrap:flux
```

**What happens:**
1. Applies GitHub deploy key (if exists)
2. Creates `sops-age` secret for decryption
3. Applies encrypted cluster secrets
4. Applies cluster settings ConfigMap
5. Applies Flux configuration (starts GitOps reconciliation)

**Expected duration:** 2-3 minutes (Flux starts), 15-30 minutes (full reconciliation)

**Verification:**
```bash
# Check Flux components
flux check

# Watch Flux reconciliation
flux get kustomizations -A --watch
```

---

## Post-Bootstrap Verification

### 1. Check Core Infrastructure (First 5-10 minutes)

```bash
# External Secrets (must be healthy first)
flux get kustomization external-secrets -n flux-system
kubectl -n external-secrets get pods

# OpenEBS
flux get kustomization openebs -n flux-system
kubectl -n openebs-system get pods

# Rook-Ceph Operator
flux get kustomization rook-ceph -n flux-system
kubectl -n rook-ceph get pods -l app=rook-ceph-operator
```

### 2. Check Storage (10-20 minutes)

Rook-Ceph cluster initialization takes time. Monitor progress:

```bash
# Watch Ceph cluster status
flux get kustomization rook-ceph-cluster -n flux-system

# Once toolbox is running, check Ceph health
task rook:status

# Verify storage classes exist
kubectl get storageclasses
```

**Expected storage classes:**
- `ceph-block` - Block storage (RBD)
- `ceph-filesystem` - Shared filesystem (CephFS)
- `openebs-hostpath` - Local node storage

### 3. Check Networking

```bash
# Ingress controllers
kubectl -n network get pods

# Certificates
kubectl get certificates -A

# External DNS (if using)
kubectl -n network logs -l app.kubernetes.io/name=external-dns
```

### 4. Check Applications

```bash
# Overall Flux status
flux get kustomizations -A | grep -v "True"

# Any failed HelmReleases
flux get helmreleases -A | grep -v "True"

# Pods not running
kubectl get pods -A | grep -v Running | grep -v Completed
```

### 5. Restore Data from Backups

Once storage is healthy, restore application data:

```bash
# Example: Restore Plex from 3rd previous snapshot
task volsync:restore NS=media APP=plex PREVIOUS=3

# Example: Restore Home Assistant
task volsync:restore NS=home APP=home-assistant PREVIOUS=1
```

---

## Troubleshooting

### Nodes Not Becoming Ready

**Symptom:** `kubectl get nodes` shows NotReady

**Check Cilium:**
```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium
kubectl -n kube-system logs -l app.kubernetes.io/name=cilium-agent --tail=50
```

**Check kubelet:**
```bash
talosctl -n 10.20.0.14 logs kubelet
```

### Flux Kustomization Stuck

**Symptom:** Kustomization shows `False` or stuck reconciling

```bash
# Get detailed status
flux get kustomization <name> -n flux-system

# Check events
kubectl describe kustomization <name> -n flux-system

# Force reconciliation
flux reconcile kustomization <name> -n flux-system --with-source
```

### External Secrets Not Syncing

**Symptom:** ExternalSecrets show error status

```bash
# Check ClusterSecretStore
kubectl get clustersecretstore

# Check ExternalSecret status
kubectl get externalsecrets -A

# View external-secrets operator logs
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets
```

### Rook-Ceph Cluster Not Healthy

**Symptom:** Ceph shows HEALTH_WARN or HEALTH_ERR

```bash
# Detailed health
task rook:health

# OSD status
task rook:osd-status

# Check operator logs
kubectl -n rook-ceph logs -l app=rook-ceph-operator --tail=100
```

**Common issues:**
- OSDs not starting: Check disk availability and previous Ceph data
- MONs not forming quorum: Check network connectivity between nodes
- PGs not clean: Wait for cluster to stabilize (can take 10-15 minutes)

### Stuck Resources with Finalizers

If resources won't delete during teardown:

```bash
# Rook-Ceph resources
task rook:remove-finalizers

# Generic resource (replace with actual resource)
kubectl patch <resource> <name> -n <namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge
```

### HelmRelease Stuck in "Not Ready"

```bash
# Get HelmRelease status
flux get helmrelease <name> -n <namespace>

# Check Helm history
helm history <name> -n <namespace>

# Force upgrade
flux reconcile helmrelease <name> -n <namespace> --force

# Nuclear option: uninstall and let Flux reinstall
flux suspend helmrelease <name> -n <namespace>
helm uninstall <name> -n <namespace>
flux resume helmrelease <name> -n <namespace>
```

### Namespace Privilege Issues

**Symptom:** Pods failing with security context errors

Privileged namespaces are created during `bootstrap:apps`. If a namespace is missing privilege labels:

```bash
# Check namespace labels
kubectl get namespace <name> -o yaml | grep pod-security

# Manually add privilege labels if missing
kubectl label namespace <name> \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged
```

---

## Dependency Reference

### Bootstrap Dependency Chain

```
Phase 1: task bootstrap:talos
├── Generate talsecret.sops.yaml
├── Generate machine configs
├── Apply configs to nodes
├── Bootstrap etcd
└── Generate kubeconfig

Phase 2: task bootstrap:apps
├── Wait for nodes (Ready=False)
├── Create privileged namespaces ← CRITICAL
│   ├── rook-ceph (privileged)
│   ├── observability (privileged)
│   ├── network (privileged)
│   ├── openebs-system (privileged)
│   ├── volsync-system (privileged)
│   ├── tools (privileged)
│   ├── database (privileged)
│   ├── home (privileged)
│   └── media (privileged)
├── Helmfile releases:
│   ├── prometheus-operator-crds
│   ├── cilium (depends on crds)
│   ├── coredns (depends on cilium)
│   ├── spegel (depends on coredns)
│   └── flux (depends on coredns, spegel)
└── Wait for nodes (Ready=True)

Phase 3: task bootstrap:flux
├── Apply GitHub deploy key
├── Create sops-age secret
├── Apply cluster-secrets
├── Apply cluster-settings
└── Apply Flux config → GitOps takes over
```

### Flux Infrastructure Dependencies

```
external-secrets (wait: true)
    └── external-secrets-stores
            │
            ├── openebs (wait: true)
            │
            ├── rook-ceph (wait: true)
            │       └── rook-ceph-cluster (wait: true)
            │               │
            │               ├── snapshot-controller (wait: true)
            │               │       └── volsync
            │               │
            │               └── [Apps using ceph-block storage]
            │
            ├── cert-manager
            │       └── cert-manager-issuers
            │               └── ingress-nginx-*
            │
            └── [Most applications]
```

### Privileged Namespaces

These namespaces require `pod-security.kubernetes.io/enforce: privileged`:

| Namespace | Reason |
|-----------|--------|
| `rook-ceph` | Storage cluster needs kernel access |
| `observability` | Prometheus node exporters need host access |
| `network` | Cilium CNI needs eBPF/network access |
| `openebs-system` | Storage operator needs host path access |
| `volsync-system` | Backup movers need privileged access |
| `tools` | Device plugins need host device access |
| `database` | Database operators may need elevated access |
| `home` | Home automation apps need device access |
| `media` | Media apps need transcoding/device access |

---

## Quick Reference Commands

```bash
# Full rebuild from scratch
task talos:reset
# Wait for nodes to reboot...
task bootstrap:talos
task bootstrap:apps
task bootstrap:flux

# Check overall status
flux get kustomizations -A
kubectl get pods -A | grep -v Running

# Force full reconciliation
task reconcile

# Storage status
task rook:status

# Unlock stuck VolSync repos
task volsync:unlock
```

---

## Recovery Scenarios

### Scenario: Single Node Failure

**See [rebuild_node.md](./rebuild_node.md) for the full procedure.** Rebuilding
one node is not a scaled-down cluster rebuild — it has its own constraints:

- All three nodes are etcd members, so a second node must never be wiped while
  one is down, or the API becomes read-only and the node cannot rejoin.
- `openebs-hostpath` data is node-local and is destroyed by a wipe. Ceph is
  replicated and survives.
- A rebuilt node needs its CloudNativePG instance replaced by hand before the
  database will recover.

### Scenario: Complete Cluster Loss (Disaster Recovery)

1. Ensure you have:
   - `age.key` (CRITICAL - cannot recover without this)
   - Git repository access
   - Network infrastructure (DHCP/DNS)
2. Follow full [Bootstrap Sequence](#bootstrap-sequence)
3. Restore data from off-cluster backups (VolSync restic repos)

### Scenario: Ceph Data Loss

If Ceph OSDs are lost but nodes are healthy:

1. Delete the CephCluster: `kubectl delete cephcluster -n rook-ceph rook-ceph`
2. Remove finalizers if stuck: `task rook:remove-finalizers`
3. Wipe OSD disks on each node
4. Force Flux to recreate: `flux reconcile kustomization rook-ceph-cluster -n flux-system --force`
5. Restore application data from VolSync backups
