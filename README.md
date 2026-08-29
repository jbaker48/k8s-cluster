# Self-Hosted Kubernetes Cluster

A GitOps-managed Kubernetes cluster running on Talos Linux with Flux CD for automated deployments.

## Overview

This repository contains the complete configuration for a self-hosted Kubernetes cluster using:

- **Talos Linux** - Immutable, secure Kubernetes OS
- **Flux CD** - GitOps operator for continuous deployment
- **SOPS** - Secret management with age encryption
- **Task** - Task runner for cluster operations

## Quick Start

### Prerequisites

- [mise](https://mise.jdx.dev/) — the only thing you install by hand. Every
  other tool is declared in `.mise.toml` and installed by `mise install`.
- 3+ nodes with Talos Linux installed
- `age.key` — the SOPS decryption key. **Nothing can be decrypted without it**,
  so it is not in the repository and cannot be regenerated.
- Domain with Cloudflare DNS (optional)

### Setup

```bash
git clone <this-repo> && cd k8s-cluster
mise trust      # allow this repo's .mise.toml
mise install    # install every pinned tool
```

That is the whole toolchain. `mise install` provides `kubectl`, `talosctl`,
`talhelper`, `flux`, `helm`, `helmfile`, `kustomize`, `sops`, `age`, `yq`,
`jq`, `task`, `kubeconform`, `yamllint`, `minijinja-cli`, `stern`,
`pre-commit`, `cloudflared`, `uv` and Python.

Verify the toolchain resolves through mise rather than a system package
manager — a Homebrew binary earlier in `PATH` will shadow the pinned version:

```bash
mise doctor          # should report no problems
mise which kubectl   # should print a path under ~/.local/share/mise
```

`.mise.toml` also exports `KUBECONFIG`, `SOPS_AGE_KEY_FILE` and `TALOSCONFIG`
relative to the repo root, so those work from any directory inside it once
`mise` is active in your shell.

Then bootstrap, in this order:

```bash
task bootstrap:talos    # OS layer, etcd, kubeconfig
task bootstrap:apps     # Cilium, CoreDNS, Spegel, Flux via helmfile
task bootstrap:flux     # hand over to GitOps
```

Run `task --list` to see everything available.

## Applications

The cluster includes organized applications by namespace:

- **AI** - Machine learning workloads
- **Database** - PostgreSQL, Redis
- **Media** - Plex, Jellyfin, *arr stack
- **Network** - Ingress, DNS, VPN
- **Observability** - Monitoring and logging
- **Security** - Authentication and security tools
- **Self-hosted** - Personal productivity apps
- **Storage** - Rook Ceph, OpenEBS
- **Tools** - Development and admin utilities

## Key Features

- **GitOps Workflow** - All changes via Git commits
- **Automated Dependency Updates** - Renovate bot integration
- **Encrypted Secrets** - SOPS with age encryption
- **High Availability** - Multi-node control plane
- **Persistent Storage** - Ceph distributed storage
- **SSL Certificates** - Automated Let's Encrypt certs
- **Backup & Sync** - VolSync for data protection

## Management

```bash
# Force Flux reconciliation
task reconcile

# View cluster resources
kubectl get nodes -o wide
kubectl get pods -A

# Check Flux status
flux get sources git -A
flux get kustomizations -A
```

## Storage

- **Rook Ceph** - Distributed block/object/filesystem storage
- **OpenEBS** - Local persistent volumes
- **VolSync** - Backup and replication

## Networking

- **Cilium** - CNI with eBPF dataplane
- **Ingress NGINX** - HTTP/HTTPS ingress controller
- **External DNS** - Automatic DNS record management
- **Cloudflare Tunnel** - Secure external access

---

Built with ❤️ for self-hosting enthusiasts
