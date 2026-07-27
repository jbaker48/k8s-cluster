<!-- GSD:project-start source:PROJECT.md -->

## Project

**SRE Agent: Staged Renovate/PR Auto-Merge**

An AI-assisted auto-merge pipeline for this cluster's GitOps repo. Every open PR (Renovate dependency bumps plus human-authored PRs) is reviewed by an AI risk-triage step modeled directly on `bjw-s-labs/home-ops`'s production `.forgejo/workflows/pr-reviewer.yaml` pattern: `misospace/pr-reviewer-action` calling the existing in-cluster `litellm` proxy, with `home-operations/konflate` wired in as an MCP tool server for rendered-diff/blast-radius evidence. An "approve" verdict triggers a real auto-merge — not just an advisory comment. A deterministic post-merge health-gate watches cluster health after merge and auto-reverts if something breaks. Cluster-critical infra (Talos, Kubernetes, Cilium) is always excluded from AI-driven auto-merge via deterministic path-glob matching (not agent judgment), regardless of verdict.

**Core Value:** Low-risk PRs (the overwhelming majority of Renovate noise) merge themselves safely; anything that could take down the cluster still requires a human — and if the AI or the human is wrong anyway, the health-gate reverts it automatically.

### Constraints

- **Reuse before building**: Confirmed via spike 001 and this session's reference check — `misospace/pr-reviewer-action` + `home-operations/konflate` replace any custom-built review/diff tooling. Do not build bespoke equivalents.
- **Model pinning**: Spike 001 used a pinned model (`claude-sonnet-4-6`) rather than an adaptive-router alias, for reproducible results. Production model choice is a decision for planning, not re-litigated here.
- **Network reachability**: `litellm` is only reachable via `envoy-internal`; GitHub-hosted runners cannot reach it directly — requires the new ARC runner scale set.

<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->

## Technology Stack

## Languages

- YAML - Kubernetes manifests, Helm values, configuration files
- Bash - Automation scripts for validation, fixes, and cluster management
- Python 3.14.2 - Configuration tools and utilities (via uv package manager)

## Runtime

- **Kubernetes 1.35.3** - Container orchestration platform
- **Talos Linux v1.12.6** - Immutable, minimal Linux OS for Kubernetes nodes
- **Linux (Darwin/macOS for development)** - Development environment
- `uv` - Python package manager (latest version via aqua)
- Lockfile: `requirements.txt` present in `.private/1738147431/`

## Frameworks & Core Technologies

- Kubernetes 1.35.3
- Talos Linux v1.12.6 - Immutable OS and bootstrap framework
- Flux CD 2.17.2 - GitOps continuous deployment operator
- Helm 3.x - Kubernetes package manager
- Kustomize - Template-free customization of Kubernetes manifests
- Cilium 1.18.6 - eBPF-based container networking (CNI)
- Envoy Gateway - API gateway for HTTP routing
- K8s-Gateway - DNS management for Kubernetes
- Ingress-Nginx 1.20.0 - Ingress controller
- SOPS (Mozilla) - Encrypted secret management with age encryption
- Age - Modern encryption tool for secret storage
- Doppler - External secret provider (via External Secrets Operator)
- Rook Ceph - Distributed storage platform
- OpenEBS - Open source container-attached storage
- VolSync - Volume snapshot and backup orchestration
- Restic - Backup engine (used by VolSync)
- Prometheus - Metrics collection and alerting
- Grafana - Visualization and dashboarding
- Loki - Log aggregation
- Promtail - Log shipper to Loki
- Blackbox Exporter - Black box monitoring
- Robusta - Alert automation and automation
- CloudNative-PG - PostgreSQL operator for Kubernetes
- InfluxDB - Time-series database
- Dragonfly - Redis-compatible in-memory data store
- Cert-Manager - Kubernetes certificate management
- Jetstack - Cert-Manager Helm repository provider
- yamllint - YAML syntax and style validation
- kubeconform - Kubernetes manifest validation against schemas
- Kustomize build validation

## Key Dependencies

- `talhelper` (budimanjojo/talhelper) - Talos configuration generator
- `cloudflared` (Cloudflare) - Cloudflare Tunnel client
- `age` (FiloSottile) - Modern encryption tool
- `flux2` (fluxcd) - Flux CLI for GitOps operations
- `sops` (getsops) - Secret operations encryption tool
- `task` (go-task) - Task runner for automation
- `helm` - Kubernetes package manager
- `helmfile` - Helm values bundler
- `jq` - JSON query processor
- `kubectl` (kubernetes) - Kubernetes CLI
- `kustomize` - Kubernetes manifest customizer
- `yq` - YAML query processor
- `talos` (siderolabs) - Talos Linux CLI
- `kubeconform` (yannh) - Kubernetes manifest validator
- `cloudflare==3.1.1` - Cloudflare API client (for DNS management)
- `dnspython==2.7.0` - DNS toolkit
- `email-validator==2.2.0` - Email validation
- `makejinja==2.7.2` - Jinja2 templating tool
- `netaddr==1.3.0` - Network address manipulation
- `ntplib==0.4.0` - NTP client library
- bitnami (OCI), bjw-s (OCI), cilium, cloudnative-pg, coredns, external-dns, external-secrets
- fairwinds, fluxcd-community (OCI), grafana, hajimari, influxdata, ingress-nginx
- jetstack, k8s-gateway, kyverno, metrics-server, node-feature-discovery, openebs
- prometheus-community (OCI), rook-ceph, spegel (OCI), stakater (OCI), vmware-tanzu, weave-gitops (OCI)

## Configuration Files

- `.mise.toml` - Tool versions and environment setup (Python 3.14.2, all aqua tools)
- `.taskfiles/` - Task definitions for bootstrap, Talos operations, VolSync management
- `.sops.yaml` - SOPS age encryption configuration with public keys
- `kubernetes/bootstrap/talos/talconfig.yaml` - Talos cluster configuration (Kubernetes v1.35.3, Talos v1.12.6)
- `kubernetes/bootstrap/talos/talenv.yaml` - Talos environment variable overrides
- `kubernetes/bootstrap/helmfile.yaml` - Bootstrap Helm releases (Cilium, CoreDNS, Prometheus CRDs, Flux)
- `kubernetes/flux/config/cluster.yaml` - Flux GitRepository and root Kustomization
- `kubernetes/flux/repositories/` - 30+ Helm, OCI, and Git repository definitions
- `.env` files - Not present (environment via `.mise.toml`)
- `age.key` - SOPS encryption key (generated, never committed)
- `kubeconfig` - Kubernetes cluster access (generated, never committed)
- `kubernetes/flux/vars/cluster-settings.yaml` - Global configuration variables (timezone, CIDRs, service IPs)
- `kubernetes/flux/vars/cluster-secrets.sops.yaml` - Encrypted secrets (SOPS-encrypted)
- `.pre-commit-config.yaml` - Git hooks for validation before commits
- `.github/renovate.json5` - Automated dependency updates (Docker images, Helm charts, GitHub actions)
- `Taskfile.yaml` - Main task runner configuration for validation and maintenance

## Platform Requirements

- Python 3.14.2+
- macOS/Linux shell environment
- Git for repository access
- Age encryption key for SOPS decryption
- Docker/container runtime (optional, for local testing)
- Talos Linux 1.12.6 (3x control plane nodes, 1x worker node minimum)
- 2+ CPU cores per node
- 4+ GB RAM per node
- Network connectivity to GitHub (for GitOps)
- Network connectivity to Cloudflare (for DNS)
- Network connectivity to Doppler (for secrets)

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

## Naming Patterns

- Flux Kustomizations: `ks.yaml` - Root-level kustomization files in app directories
- App Kustomizations: `kustomization.yaml` - Standard Kustomize manifests
- Helm Releases: `helmrelease.yaml` or `helmrelease-*.yaml` - HelmRelease resource definitions
- External Secrets: `externalsecret.yaml` - ExternalSecret resource definitions
- OCI Repositories: `ocirepository.yaml` - OCIRepository resource definitions
- Network Policies: `*.yaml` - Various network policy files (e.g., `backendtrafficpolicy.yaml`)
- Namespaces: `namespace.yaml` - Kubernetes namespace definitions
- Configuration: `cluster-settings.yaml`, `cluster-secrets.sops.yaml` - Global configuration
- Application names: `kebab-case` (e.g., `home-assistant-v2`, `plex`, `external-secrets`)
- Metadata names: Match application name exactly
- Labels: `app.kubernetes.io/name` and `app.kubernetes.io/instance` using app name
- Global env vars: `SCREAMING_SNAKE_CASE` (e.g., `SOPS_AGE_KEY_FILE`, `KUBECONFIG`)
- Service IP addresses: `SVC_APPNAME_ADDR` (e.g., `SVC_PLEX_ADDR`, `SVC_POSTGRES_ADDR`)
- Substitution variables: `SCREAMING_SNAKE_CASE` in cluster-settings.yaml (e.g., `TIMEZONE`, `CLUSTER_CIDR`)
- Secret variables: `PREFIX_SECRETNAME` (e.g., `HASS_INTERNAL_URL`, `HASS_CODESERVER_SSH_KEY`)
- Shell functions: `kebab-case` or `snake_case` (e.g., `log_error`, `add_common_metadata`)
- Task targets: `kebab-case` with colons for namespacing (e.g., `validate:all`, `bootstrap:talos`)

## Code Style

- YAML indentation: 2 spaces (all YAML files)
- Shell script indentation: 4 spaces
- Line endings: LF only
- Charset: UTF-8
- Trailing whitespace: Not allowed
- Final newline: Required on all files
- See `.editorconfig` for enforced rules
- All YAML files start with `---` document separator
- Schema declarations at top using `yaml-language-server: $schema=<url>`
- YAML anchors (`&`) for reusable values at top of sections
- YAML aliases (`*`) to reference anchors
- Metadata sections before spec sections
- Consistent key ordering: `apiVersion`, `kind`, `metadata`, `spec`
- Documentation comments above sections explaining purpose
- No inline comments after code (use line-above format)
- Comment headers for script sections
- Logging functions in scripts output status messages with emoji prefixes
- All error messages sent to stderr
- Error counter tracking with `ERRORS` variable
- Emoji prefixes for visual status indication

## Schema Declarations

| File Type | Schema URL |
|-----------|-----------|
| Flux Kustomization (ks.yaml) | `https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json` |
| App Kustomization | `https://json.schemastore.org/kustomization` |
| App-template HelmRelease | `https://raw.githubusercontent.com/bjw-s/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json` |
| System HelmRelease | `https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/helmrelease-helm-v2.json` |
| GitHub Workflow | `https://json.schemastore.org/github-workflow.json` |
| Taskfile | `https://taskfile.dev/schema.json` |

- `bjw-s-labs` - Use `bjw-s` instead
- `helmrelease-helm-v2beta2` - Use `helmrelease-helm-v2` instead
- SchemaStore master URLs - Use versioned/current URLs instead

## Import/Variable Organization

- Global variables from `cluster-settings.yaml` referenced as `${VAR_NAME}`
- Secrets from `cluster-secrets.sops.yaml` referenced as `${SECRET_NAME}`
- App-specific substitutions in Kustomization `postBuild.substitute`
- Template variables in ExternalSecret using `{{ .VARIABLE_NAME }}`
- Relative paths in kustomization resources: `./path/to/resource.yaml`
- Shared template references: `../../../../templates/volsync`
- Flux source references by name: `kind: GitRepository, name: home-kubernetes`

## Error Handling

- Always use `set -euo pipefail` at the top
- Exit on first error with meaningful error messages
- Use `preconditions:` in Taskfiles to check prerequisites
- Verify command existence with `which <command>`
- Check file existence with `test -f <file>`
- Use conditional commands with `||` or `if` statements for optional checks
- Health checks defined in Kustomizations via `healthChecks:` section
- Retry intervals specified: `retryInterval: 1m` (standard)
- Timeout specified: `timeout: 10m` (standard for most apps)
- Remediation strategies in HelmRelease: `rollback` or `reinstall`
- Rollback on failure: `upgrade: cleanupOnFail: true, remediation: strategy: rollback`
- Exit code 0 on success, non-zero on failure
- Echo detailed error messages to stderr
- Track error count across multiple checks
- Report error summary before exit

## Required Properties

- `targetNamespace:` - Namespace where resources deploy
- `retryInterval:` - How often Flux retries (standard: `1m`)
- `commonMetadata:` - Labels applied to all resources
- `interval:` - Flux reconciliation interval (standard: `30m`)
- `timeout:` - Operation timeout (standard: `10m`)
- `sourceRef:` - Reference to Git source
- `prune:` - Set to `true` to clean up removed resources
- `chartRef:` - Chart source (OCIRepository or HelmRepository)
- `interval:` - Reconciliation interval (standard: `1h`)
- `install: remediation: retries:` - Number of install retries (standard: `3`)
- `upgrade: cleanupOnFail: true, remediation: strategy: rollback, retries: 3`
- `secretStoreRef:` - Reference to secret store (usually `doppler-secrets`)
- `target:` - Target secret name and template
- `data:` or `dataFrom:` - Secret references

## Application Structure

## Comments

- Add header comment for each script section explaining what it does
- Document non-obvious validation checks
- Explain regex patterns in sed/grep commands
- Comment out deprecated but potentially useful code (with dates)
- Shell scripts: Use `desc:` in Taskfile for command documentation
- YAML resources: Use `metadata:` labels and annotations for documentation
- Script headers include: shebang, brief description, error handling
- Function headers document: purpose, parameters, error handling

#!/bin/bash

## Linting & Validation

- `yamllint` - YAML syntax validation (available as task)
- `kustomize build` - Kustomize manifest validation
- `flux diff` - Flux manifest validation
- Custom `validate-consistency.sh` - Repository-specific checks
- Trailing whitespace check
- End-of-file fixer
- YAML validation (`check-yaml --unsafe`)
- Large file detection
- Merge conflict detection
- Repository consistency check (custom script)
- yamllint is available but not enforced in pre-commit (commented out)
- Use `task validate:yaml` to run yamllint manually

## Consistency Checks

<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

## System Overview

```text

```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| **Cluster GitOps Root** | Establishes Git repository as source of truth, configures SOPS decryption, defines cluster-wide substitutions | `kubernetes/flux/config/cluster.yaml` |
| **Apps Orchestrator** | Recursively applies all namespace and app Kustomizations, manages SOPS decryption and variable substitution for all applications | `kubernetes/flux/apps.yaml` |
| **Namespace Aggregators** | Reference all applications in namespace, define namespace-level labels and resources | `kubernetes/apps/*/kustomization.yaml` (17 files) |
| **App Flux Kustomizations** | Define application deployment metadata, health checks, dependencies, app-specific variables | `kubernetes/apps/*/*/ks.yaml` (50+ files) |
| **App Resources** | Define actual Kubernetes resources: HelmRelease, ExternalSecret, ConfigMap, PVC, policies | `kubernetes/apps/*/*/app/` directories |
| **Helm Repositories** | External chart sources (Bitnami, Jetstack, Cilium, bjw-s, etc.) for HelmRelease deployments | `kubernetes/flux/repositories/helm/`, `kubernetes/flux/repositories/oci/`, `kubernetes/flux/repositories/git/` |
| **Cluster Variables** | Global cluster configuration, network addresses, IPs for internal services | `kubernetes/flux/vars/cluster-settings.yaml`, `kubernetes/flux/vars/cluster-secrets.sops.yaml` |
| **Talos Configuration** | Cluster topology, node details, network configuration, bootstrap secrets | `kubernetes/bootstrap/talos/talconfig.yaml` |
| **System Bootstrap** | Essential system components (Cilium CNI, CoreDNS, Prometheus CRDs, Flux) installed before GitOps | `kubernetes/bootstrap/helmfile.yaml` |

## Pattern Overview

- **Single source of truth:** All cluster state defined in Git, Flux CD reconciles continuously
- **Hierarchical Kustomization:** Root Kustomization cascades to namespace Kustomizations, then to individual app Kustomizations
- **Variable substitution:** Global cluster variables and encrypted secrets substituted at runtime across all manifests
- **SOPS encryption:** Sensitive values encrypted with age key, transparent decryption during deployment
- **Bootstrap sequence:** Talos provides OS-level foundation → helmfile installs critical system apps → Flux takes over full cluster management

## Layers

- Purpose: Immutable OS foundation for Kubernetes nodes
- Location: `kubernetes/bootstrap/talos/`
- Contains: Node topology, network configuration, machine secrets, patches
- Depends on: None (base layer)
- Used by: Kubernetes control plane and workloads
- Purpose: Install critical system components before GitOps takeover
- Location: `kubernetes/bootstrap/helmfile.yaml`
- Contains: Cilium CNI, CoreDNS, Prometheus CRDs, Spegel image cache, Flux CD itself
- Depends on: Talos Linux cluster ready
- Used by: Flux CD (which then manages everything else)
- Purpose: Reconcile Git repository state into Kubernetes cluster
- Location: `kubernetes/flux/config/cluster.yaml`, `kubernetes/flux/apps.yaml`
- Contains: Git repository definition, SOPS decryption secrets, cluster Kustomization, apps Kustomization
- Depends on: helmfile (for initial Flux installation)
- Used by: All applications
- Purpose: Group applications by function/domain
- Location: `kubernetes/apps/<namespace>/`
- Contains: Namespace resource, namespace-level kustomization, app references
- Depends on: Flux Core
- Used by: Individual applications in the namespace
- Purpose: Deploy and manage individual applications
- Location: `kubernetes/apps/<namespace>/<app-name>/`
- Contains: App Flux Kustomization (ks.yaml), app resources directory with HelmRelease, ExternalSecret, ConfigMap, PVC
- Depends on: Namespace Layer, external Helm charts, SOPS encryption
- Used by: End users accessing cluster services
- Purpose: Centralize configuration, avoid hardcoding values
- Location: `kubernetes/flux/vars/`, templates referenced in postBuild blocks
- Contains: cluster-settings.yaml (IP addresses, CIDR ranges, service addresses), cluster-secrets.sops.yaml (encrypted credentials)
- Depends on: SOPS age encryption key
- Used by: All applications via postBuild substitution
- Purpose: Reusable Kustomize components and templates
- Location: `kubernetes/components/common/`, `kubernetes/templates/volsync/`
- Contains: App-template OCI repository definition, VolSync backup templates
- Depends on: Kustomize resources feature
- Used by: Applications needing shared patterns (e.g., all apps with backups use VolSync template)

## Data Flow

### Primary Request Path (GitOps Reconciliation)

- Git repository is authoritative source
- Flux enforces Git state every 30 minutes (interval: 30m)
- SOPS age.key enables decryption of .sops.yaml encrypted files
- Kustomize patches (in apps.yaml) automatically apply SOPS/substitution config to all child Kustomizations
- No manual kubectl apply; all changes via Git commit → Flux reconciliation

### Application Dependency Resolution

```yaml

```

### VolSync Backup & Restore Flow

## Key Abstractions

- Purpose: Declarative way to apply Kustomize-built resources into Kubernetes
- Examples: `kubernetes/flux/config/cluster.yaml` (root), `kubernetes/flux/apps.yaml` (apps orchestrator), `kubernetes/apps/home/ks.yaml` (app declaration)
- Pattern: Each Kustomization resource targets a path, applies patches, performs substitution, declares dependencies and health checks
- Purpose: Declarative way to manage Helm chart installations as Kubernetes resources
- Examples: `kubernetes/apps/home/home-assistant-v2/app/helmrelease.yaml`, `kubernetes/apps/media/plex/app/helmrelease.yaml`
- Pattern: Specifies chart source (OCI, Helm repo), values overrides, install/upgrade strategy, health checks, dependencies
- Purpose: Sync secrets from external sources into Kubernetes Secrets
- Examples: `kubernetes/apps/home/home-assistant-v2/app/externalsecret.yaml`
- Pattern: References SecretStore, specifies which secrets to fetch, creates local Secret resource
- Purpose: Group applications by domain/function, centralize namespace configuration
- Examples: `kubernetes/apps/home/namespace.yaml`, `kubernetes/apps/home/kustomization.yaml`
- Pattern: Namespace YAML defines namespace resource, kustomization.yaml lists all apps in namespace as resources

## Entry Points

- Location: `kubernetes/flux/config/cluster.yaml`
- Triggers: Flux controller polling Git repository (reconciliation every 30m)
- Responsibilities: Establishes Git as source of truth, enables SOPS decryption, loads cluster variables, delegates to apps.yaml
- Location: `kubernetes/flux/apps.yaml`
- Triggers: cluster.yaml references this via sourceRef
- Responsibilities: Recursively applies all namespaces/apps from `kubernetes/apps/`, applies SOPS/substitution patches to all children
- Location: `kubernetes/bootstrap/talos/talconfig.yaml`
- Triggers: `task bootstrap:talos` (manual, one-time cluster setup)
- Responsibilities: Generates machine configurations, establishes 3-node control plane, configures networking (VLAN, static IPs), bootstraps etcd
- Location: `kubernetes/bootstrap/helmfile.yaml`
- Triggers: `task bootstrap:apps` (manual, after Talos bootstrap)
- Responsibilities: Installs critical system apps (Cilium, CoreDNS, Prometheus CRDs, Flux) via Helm before GitOps takeover

## Architectural Constraints

- **Threading:** Kubernetes control plane is multi-threaded (etcd, api-server, scheduler run on each of 3 nodes). Flux controller is single-threaded per resource type (one concurrent reconciliation per Kustomization/HelmRelease). Applications run as container workloads with no special threading constraints.
- **Global state:** Cluster-wide variables in ConfigMap/Secret (`cluster-settings`, `cluster-secrets`). SOPS age.key file required in filesystem for decryption. Kubeconfig file required to access cluster. Talos machine config stored in clusterconfig/ directory.
- **Circular imports:** No circular Kustomization dependencies enforced by Flux (would cause infinite loops). Apps cannot depend on each other transitively in a cycle. Bootstrap sequence is strictly linear (Talos → helmfile → Flux → apps).
- **Gitops isolation:** Individual namespace Kustomizations are independent; apps within a namespace can reference apps in other namespaces via explicit `dependsOn` declarations. No automatic cross-namespace discovery.
- **Mutability:** Talos nodes are immutable OS (configurable only via MachineConfig). Kubernetes resources are mutable, Flux continuously enforces Git state (prune: true removes orphaned resources). SOPS-encrypted files are decrypted and passed as plaintext ConfigMaps/Secrets at runtime.
- **Network:** Cilium CNI provides service connectivity. Envoy Gateway / Ingress Nginx handle external ingress. K8s-gateway provides internal DNS. Multus enables secondary networks (VLANs). All network config in talconfig.yaml nodes section.

## Anti-Patterns

### Hardcoded Configuration Values

### Manual kubectl apply Instead of GitOps

### Missing Schema Declarations on YAML Files

- Flux Kustomization (ks.yaml): `https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json`
- App Kustomization: `https://json.schemastore.org/kustomization`
- HelmRelease: `https://raw.githubusercontent.com/bjw-s/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json` or `https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/helmrelease-helm-v2.json`
- Helmfile: `https://json.schemastore.org/helmfile`

### Not Using dependsOn for Cross-App Dependencies

```yaml

```

### Missing healthChecks in ks.yaml

```yaml

```

## Error Handling

- **Flux reconciliation failures:** Logged in Kustomization/HelmRelease status conditions. View with `flux get kustomizations -A`. Manual intervention: fix YAML, commit to Git, `task reconcile` to retry.
- **Pod startup failures:** Check logs with `kubectl logs -n <namespace> <pod>`. Describe Pod with `kubectl describe pod` to see events. Check image pull, resource requests, liveness/readiness probes.
- **Application connectivity failures:** Check Services with `kubectl get svc`, Ingress with `kubectl get ingress`. Verify network policy allows traffic. Check DNS resolution with `kubectl run -it busybox -- nslookup <svc>`.
- **SOPS decryption failures:** Check sops-age Secret exists with `kubectl get secret -n flux-system sops-age`. Verify age.key file present locally. Check `.sops.yaml` configuration for age key fingerprint.
- **VolSync backup failures:** Check ReplicationSource status with `kubectl describe replicationsource -n <namespace>`. Check Restic backend (MinIO) connectivity and repository lock. Use `task volsync:unlock` to force unlock.

## Cross-Cutting Concerns

- **Kubernetes API:** kubeconfig from Talos bootstrap, client certificates for user access
- **Flux Git access:** GitHub deploy key in `kubernetes/bootstrap/flux/github-deploy-key.sops.yaml`, decrypted at runtime
- **External services:** Credentials stored as Secrets in cluster, often synced from external-secrets vault (if configured)

<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
