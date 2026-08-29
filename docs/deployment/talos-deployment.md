# Talos Kubernetes Deployment

This guide covers deploying a Kubernetes cluster using Talos Linux.

## Prerequisites

- 3+ nodes with Talos Linux installed
- [mise](https://mise.jdx.dev/) for tool management
- Domain with Cloudflare DNS (optional)

## Initial Setup

### 1. Install Dependencies

```bash
# Trust this repo's .mise.toml, then install every pinned tool
mise trust
mise install
```

`.mise.toml` declares the complete toolchain, so nothing else needs installing
by hand. Confirm the tools resolve through mise rather than a system package
manager:

```bash
mise doctor
mise which talhelper
```

### 2. Configure Cluster

Edit the Talos topology and versions directly — there is no generator step:

```bash
# Nodes, network, disks, patches, extensions
vim kubernetes/bootstrap/talos/talconfig.yaml

# Talos and Kubernetes versions (these take precedence)
vim kubernetes/bootstrap/talos/talenv.yaml

# Render machine configs into clusterconfig/
task talos:generate-config
```

You also need `age.key` in the repository root before bootstrapping, since
`talhelper` encrypts the generated secrets with SOPS.

### 3. Bootstrap Cluster

```bash
# Bootstrap Talos nodes
task bootstrap:talos

# Install essential applications (CNI, CSI, etc.)
task bootstrap:apps

# Bootstrap Flux GitOps
task bootstrap:flux
```

## Configuration Files

### Talos Configuration
- `kubernetes/bootstrap/talos/talconfig.yaml` - Main cluster configuration
- `kubernetes/bootstrap/talos/patches/` - Node-specific patches

### Bootstrap Applications
- `kubernetes/bootstrap/helmfile.yaml` - Essential cluster components
- Includes: Cilium CNI, Rook Ceph CSI, cert-manager, etc.

### Flux Configuration
- `kubernetes/flux/config/` - Flux system configuration
- `kubernetes/flux/vars/` - Cluster variables and secrets

## Node Management

### Add New Node

1. Install Talos Linux on the new node
2. Update `talconfig.yaml` with new node details
3. Regenerate and apply configuration:
   ```bash
   task bootstrap:talos
   ```

### Remove Node

1. Drain the node:
   ```bash
   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
   ```
2. Remove from cluster:
   ```bash
   kubectl delete node <node-name>
   ```
3. Update `talconfig.yaml` and regenerate config

## Troubleshooting

### Check Node Status
```bash
# Check Talos nodes
talosctl -n <node-ip> health

# Check Kubernetes nodes
kubectl get nodes -o wide
```

### Access Node Console
```bash
# Connect to node
talosctl -n <node-ip> dashboard

# View logs
talosctl -n <node-ip> logs
```

### Reset Node
```bash
# Reset a single node
talosctl -n <node-ip> reset --graceful=false --reboot
```

## Security

- All secrets encrypted with SOPS and age
- Talos runs in secure mode by default
- No SSH access to nodes (use talosctl)
- Immutable OS with verified boot

## Next Steps

After cluster bootstrap:
1. Verify all nodes are Ready: `kubectl get nodes`
2. Check Flux status: `flux get kustomizations -A`
3. Monitor application deployment in your namespace directories
