# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A self-hosted Kubernetes cluster using **Talos Linux** as the OS, **Flux CD** for GitOps deployments, and **SOPS** for encrypted secret management. The cluster runs diverse workloads across namespaces (AI, Database, Media, Network, Observability, Security, Self-hosted, Storage, and Tools).

## Essential Commands

### Setup & Dependencies
```bash
mise trust                    # Trust .mise.toml configuration
mise install                  # Install all tools (Python, kubectl, flux, etc.)
mise run deps                 # Install Python dependencies via uv

task init                      # Initialize cluster configuration
task configure                 # Generate Talos config from configuration
```

### Cluster Bootstrap
```bash
task bootstrap:talos          # Bootstrap Talos Linux cluster
task bootstrap:apps           # Bootstrap essential system apps via Helm
task bootstrap:flux           # Bootstrap Flux CD for GitOps
```

### Validation & Maintenance
```bash
task validate:all             # Run all validation checks (YAML, Kustomize, consistency)
task validate:consistency     # Check schema compliance and repository consistency
task validate:yaml            # Validate YAML syntax using yamllint
task validate:kustomize       # Validate all Kustomize manifests
task maintain:consistency     # Fix formatting and schemas, then validate
```

### Cluster Operations
```bash
task reconcile                # Force Flux to reconcile from Git (pulls latest changes)
task talos:generate-config    # Generate Talos configuration from talconfig.yaml
task talos:apply-node IP=10.20.0.14 MODE=auto  # Apply config to specific node
task talos:upgrade-node IP=10.20.0.14           # Upgrade Talos on a node
task talos:upgrade-k8s        # Upgrade Kubernetes version
task talos:reset              # Reset cluster nodes to maintenance mode
```

### VolSync Backup & Restore
```bash
task volsync:snapshot NS=media APP=plex              # Create manual backup snapshot
task volsync:restore NS=media APP=plex PREVIOUS=3    # Restore from 3rd previous snapshot
task volsync:unlock                                  # Unlock all restic repositories
task volsync:unlock-local NS=media APP=plex          # Unlock specific repo from local machine
task volsync:state-suspend                           # Suspend VolSync (before maintenance)
task volsync:state-resume                            # Resume VolSync
```

### Talos & Kubernetes Management
```bash
kubectl get nodes -o wide     # View cluster nodes
kubectl get pods -A           # View all pods
flux get sources git -A       # Check Git source status
flux get kustomizations -A    # Check Flux kustomization status
talosctl get machineconfig    # Check Talos configuration
```

## Project Structure

### `kubernetes/` - Main Configuration
- **`bootstrap/`** - Cluster initialization files
  - `talos/` - Talos Linux configuration (talconfig.yaml, talsecret, clusterconfig/)
  - `flux/` - Flux CD configuration and GitHub deploy key
  - `helmfile.yaml` - Essential system Helm charts (Cilium, CoreDNS, etc.)
- **`flux/`** - Flux CD configuration
  - `apps.yaml` - Root Kustomization that orchestrates all apps
  - `config/` - Cluster configuration (SOPS decryption setup, post-build substitution)
  - `repositories/` - Helm/Git/OCI repositories used by the cluster
  - `vars/` - Cluster-wide variables (cluster-secrets.sops.yaml, cluster-settings.yaml)
- **`apps/`** - Application deployments organized by namespace
  - Each namespace (e.g., `home/`, `database/`, `media/`) contains apps
  - Each app follows structure: `<app-name>/ks.yaml` (Flux Kustomization) + `<app-name>/app/` (resources)
  - Namespaces: ai, cert-manager, database, default, external-secrets, flux-system, home, kube-system, media, network, observability, openebs-system, rook-ceph, security, selfhosted, tools, volsync-system
- **`components/`** - Shared Kustomize components (e.g., app-template repository definitions)
- **`templates/`** - Reusable templates (volsync, helmrelease examples)

### `scripts/` - Automation
- `validate-consistency.sh` - Repository validation (schemas, required properties, patterns)
- `fix-schemas.sh` - Auto-fix missing schema declarations
- `fix-helmrelease-schemas.sh` - Update HelmRelease schemas
- `fix-properties.sh` - Ensure required properties in manifests
- `fix-timeout-format.sh` - Format timeout values consistently

### `.taskfiles/` - Task Definitions
- `bootstrap/Taskfile.yaml` - Talos, apps, and Flux bootstrap tasks
- `talos/Taskfile.yaml` - Talos-specific operations (config generation, upgrades, reset)
- `volsync/Taskfile.yaml` - Backup and sync operations

### Configuration Files
- `.mise.toml` - Tool versions (Python 3.14, kubectl, flux, helm, talhelper, sops, etc.)
- `Taskfile.yaml` - Main task definitions for validation and maintenance
- `.sops.yaml` - SOPS age encryption configuration
- `.pre-commit-config.yaml` - Git hooks (YAML validation, trailing whitespace, consistency check)
- `kubeconfig` - Kubernetes cluster access (generated)
- `age.key` - SOPS encryption key (generated, never commit)

## Architecture & Patterns

### Flux CD GitOps Flow
1. `kubernetes/flux/apps.yaml` is the root Kustomization in flux-system namespace
2. It recursively applies all `ks.yaml` files in `kubernetes/apps/`
3. Each app's `ks.yaml` points to its `app/` directory containing resources
4. Global variables are substituted via `cluster-settings.yaml` and `cluster-secrets.sops.yaml`
5. All resources are decrypted using SOPS before deployment

### Application Structure
Every application follows this consistent pattern:
```
kubernetes/apps/<namespace>/<app-name>/
├── ks.yaml                 # Flux Kustomization (meta-resource for Flux)
└── app/
    ├── kustomization.yaml  # Resource aggregation (applies all YAMLs in app/)
    ├── helmrelease.yaml    # Helm chart deployment configuration
    ├── externalsecret.yaml # Optional: secrets synced from external-secrets
    ├── ocirepository.yaml  # Optional: OCI image repository reference
    ├── configmap.yaml      # Optional: application configuration
    └── pvc.yaml            # Optional: persistent volumes
```

Key points:
- The `ks.yaml` file at the app root is a Flux Kustomization that points to the `app/` directory
- It defines metadata like targetNamespace, dependencies, and app-specific variable substitutions
- The `app/kustomization.yaml` is a standard Kustomize file listing resources to apply
- Most apps use bjw-s/app-template HelmRelease with specific schema validation

### Schema Validation
Every YAML file must have a schema declaration header for IDE support:
- **Flux Kustomization (ks.yaml)**: `https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json`
- **App Kustomization**: `https://json.schemastore.org/kustomization`
- **App-template HelmRelease**: `https://raw.githubusercontent.com/bjw-s/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json`
- **System HelmRelease**: `https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/helmrelease-helm-v2.json`

The consistency validation script enforces these schemas across the repository.

### Secret Management
- Encrypted files use `.sops.yaml` extension (e.g., `talsecret.sops.yaml`)
- SOPS uses age encryption with key stored in `age.key`
- Encrypted files are excluded from git commits
- External-secrets operator syncs secrets to Kubernetes

## Important Concepts

### Talos Linux Specifics
- Configuration via `talconfig.yaml` + `talenv.yaml` in `kubernetes/bootstrap/talos/`
  - `talconfig.yaml` contains cluster topology, node details, patches, and network configuration
  - `talenv.yaml` contains version overrides (Talos version, Kubernetes version)
  - When both files exist, talenv.yaml values take precedence
- talhelper generates machine configurations and bootstrap commands from these files
- talosctl manages the OS layer (separate from kubectl)
- Cilium is the CNI (Flannel disabled in Talos config)

### Bootstrap Sequence
The cluster bootstrap follows a strict 3-step sequence:
1. **`task bootstrap:talos`** - Generates configs, applies to nodes, bootstraps etcd, generates kubeconfig
2. **`task bootstrap:apps`** - Deploys essential system components via Helmfile (Cilium, CoreDNS, Kubelet CSR Approver)
3. **`task bootstrap:flux`** - Installs Flux CD, applies sops-age secret, deploys cluster-settings and cluster-secrets

Each step depends on the previous step completing successfully.

### Repository Consistency
- Pre-commit hooks run `validate-consistency.sh` on every commit
- Consistency checks verify:
  - YAML syntax validity
  - Schema declarations on all files
  - Required properties in Flux Kustomizations (targetNamespace, retryInterval, commonMetadata)
  - No commented-out applications
  - HelmRelease schema consistency
- Use `task maintain:consistency` to auto-fix common issues

### Variable Substitution
- Global variables in `kubernetes/flux/vars/cluster-settings.yaml` are substituted across apps
- Secrets in `kubernetes/flux/vars/cluster-secrets.sops.yaml` are decrypted and substituted
- Variables referenced as `${VAR_NAME}` in manifests
- Post-build substitution happens after Kustomization but before deployment

## Common Workflows

### Making Changes to the Cluster
All changes follow GitOps workflow:
1. Edit YAML files in the repository
2. Run `task validate:all` to ensure changes are valid
3. Commit and push to Git
4. Run `task reconcile` to force Flux to pull changes immediately (or wait for 30m interval)
5. Monitor with `flux get kustomizations -A` and `kubectl get pods -A`

### Upgrading Talos or Kubernetes
For Talos version upgrades:
1. Update `talosVersion` in `kubernetes/bootstrap/talos/talconfig.yaml`
2. Run `task talos:generate-config` to generate new configs
3. Apply to each node: `task talos:upgrade-node IP=10.20.0.14` (repeat for all nodes)
4. Verify: `talosctl version` and `kubectl get nodes`

For Kubernetes version upgrades:
1. Update `kubernetesVersion` in `kubernetes/bootstrap/talos/talconfig.yaml`
2. Run `task talos:upgrade-k8s`
3. Monitor upgrade progress: `kubectl get nodes` and watch version change

### Troubleshooting a Failing Application
1. Check Flux Kustomization status: `flux get kustomizations -A | grep <app-name>`
2. Check HelmRelease status: `flux get helmreleases -n <namespace> <app-name>`
3. View pod logs: `kubectl logs -n <namespace> <pod-name>`
4. Describe resources: `kubectl describe -n <namespace> pod/<pod-name>`
5. Force reconciliation: `flux reconcile kustomization <app-name> -n flux-system`

## Development Patterns

### Adding a New Application
1. Create directory: `kubernetes/apps/<namespace>/<app-name>/app/`
2. Create `ks.yaml` with correct Flux Kustomization schema
3. Create `app/kustomization.yaml` with app schema
4. Create `app/helmrelease.yaml` for Helm-based apps (or other resources)
5. Run `task validate:all` to check compliance
6. Update namespace `kustomization.yaml` to reference the app (if needed)

### Modifying Talos Configuration
1. Edit `kubernetes/bootstrap/talos/talconfig.yaml`
2. Run `task talos:generate-config` to generate machine configs
3. Apply to nodes: `task talos:apply-node IP=<node-ip>`
4. Monitor reconciliation with `talosctl`

### Managing Secrets
1. Create SOPS-encrypted files with `.sops.yaml` extension
2. Store in `kubernetes/` and add to `.gitignore`
3. Reference in ExternalSecret resources or directly in Flux vars
4. Use `sops` command to encrypt/decrypt

### Backing Up and Restoring Applications
VolSync limitations and requirements:
1. Kustomization, HelmRelease, PVC, and ReplicationSource must share the same name
2. ReplicationSource and ReplicationDestination use Restic repositories
3. Each application only has one PVC being replicated

Restore workflow:
1. Suspends the Flux Kustomization and HelmRelease
2. Scales application to 0 replicas
3. Creates temporary ReplicationDestination to restore data
4. Resumes Flux resources and reconciles
5. Application starts with restored data

## Common Validation Patterns

Run before committing:
```bash
task validate:all             # Full validation suite
task maintain:consistency     # Fix and validate
```

The repository enforces consistency through:
- Pre-commit hooks (Git-based validation)
- Schema validation (IDE support via language server)
- Script validation (consistency-check.sh)
- Flux reconciliation (deployment verification)

## Key External Dependencies
- **Talos Linux** - Immutable OS for Kubernetes nodes
- **Flux CD** - GitOps continuous deployment operator
- **SOPS + age** - Encrypted secret management
- **Cilium** - eBPF-based container networking
- **External Secrets Operator** - Syncs secrets to Kubernetes
- **Rook Ceph** - Distributed storage
- **NVIDIA GPU Operator** - GPU support (if applicable)

## Troubleshooting

### Validation Failures
```bash
task validate:consistency     # Shows detailed errors
task fix:formatting           # Auto-fixes YAML formatting
task fix:schemas              # Auto-fixes schema declarations
```

### Flux Not Reconciling
```bash
kubectl describe kustomization cluster-apps -n flux-system
flux logs -f --namespace flux-system
```

### Talos Issues
```bash
talosctl version
talosctl get machineconfig   # Check current node config
talosctl health              # Check cluster health
```

### Secret Decryption
```bash
sops kubernetes/flux/vars/cluster-secrets.sops.yaml  # Decrypt to view
# Verify age.key is accessible to Flux
kubectl get secret sops-age -n flux-system
```
