# Rebuilding a Single Node

How to rebuild, replace, or recover **one** node without taking down the cluster.

For a full cluster rebuild, see [rebuild_cluster.md](./rebuild_cluster.md).

## Table of Contents

1. [Stop: check etcd quorum first](#stop-check-etcd-quorum-first)
2. [Choose the right procedure](#choose-the-right-procedure)
3. [What you lose when a node is wiped](#what-you-lose-when-a-node-is-wiped)
4. [Procedure A: Reapply machine config](#procedure-a-reapply-machine-config)
5. [Procedure B: Full node wipe and rejoin](#procedure-b-full-node-wipe-and-rejoin)
6. [Post-rebuild recovery](#post-rebuild-recovery)
7. [Verification checklist](#verification-checklist)

---

## Stop: check etcd quorum first

**All three nodes are control-plane members.** etcd needs 2 of 3 to keep a
quorum. If one node is already down or NotReady, taking a second one offline
makes the Kubernetes API read-only, and the node you wiped cannot rejoin,
because rejoining requires a working quorum.

Check before touching anything:

```bash
# All three members should be listed, and none should be a learner
talosctl -n 10.20.0.14 etcd members

# Confirm every node is Ready
kubectl get nodes
```

Rules that follow from this:

- Rebuild **one node at a time**, and only when the other two are `Ready`.
- Never `talos:reset` or wipe `EPHEMERAL` on a node while another node is down.
  This destroys that node's etcd member.
- If a node is already unhealthy, repair or remove it from etcd membership
  *before* starting work on a different node.

If you have already lost quorum, do not wipe anything else. Bring the
powered-off or failed node back first — a clean boot rejoins etcd on its own.

---

## Choose the right procedure

| Situation | Procedure | Data on node |
|-----------|-----------|--------------|
| Machine config drifted (taints, labels, kubelet args, extensions) | [A: reapply config](#procedure-a-reapply-machine-config) | Preserved |
| Talos or Kubernetes version upgrade | `task talos:upgrade-node IP=<ip>` | Preserved |
| Disk replaced, or node is unrecoverable | [B: full wipe and rejoin](#procedure-b-full-node-wipe-and-rejoin) | **Lost** |

Prefer Procedure A whenever the disk is intact. Most "the node is wrong"
problems are config drift, not a broken node.

> A common case: the live machine config differs from the generated one in
> `clusterconfig/`, so a setting keeps coming back after each kubelet restart.
> Regenerating the config is not enough — it has to be *applied* to the node.

---

## What you lose when a node is wiped

Ceph (`ceph-block`, `ceph-filesystem`) is replicated across nodes and survives
losing one node. **`openebs-hostpath` is node-local and does not.** Its data
lives under `/var/mnt/extra/openebs/local/` on that node's `EPHEMERAL`
partition, and a wipe destroys it permanently.

List exactly what will be lost before you wipe:

```bash
# Every openebs-hostpath volume pinned to the node
kubectl get pv -o json | jq -r '
  .items[]
  | select(.spec.storageClassName == "openebs-hostpath")
  | select(.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0] == "talos03")
  | "\(.spec.claimRef.namespace)/\(.spec.claimRef.name)"'
```

Typically this covers:

- **CloudNativePG instances** (`postgres17-N`) — one PGDATA copy per node.
  Recoverable from a surviving instance or from the barman backups in MinIO.
- **VolSync caches** (`volsync-src-*`, `volsync-dst-*`) — scratch space,
  recreated automatically. Safe to lose.

Before wiping a node that holds a database instance, confirm a healthy copy
exists elsewhere:

```bash
kubectl get cluster -n database postgres17
kubectl get pods -n database -o wide | grep postgres
```

---

## Procedure A: Reapply machine config

Use when the disk is fine and only the configuration is wrong.

```bash
# 1. Regenerate configs from talconfig.yaml
task talos:generate-config

# 2. Preview the change before applying it
talosctl apply-config -n <node-ip> \
  --file kubernetes/bootstrap/talos/clusterconfig/home-kubernetes-<node>.yaml \
  --mode=no-reboot --dry-run

# 3. Apply
task talos:apply-node IP=<node-ip> MODE=no-reboot
```

**Always read the dry-run diff.** The generated config carries every change in
`talconfig.yaml`, not just the one you intended — including the `install.image`
version. `--mode=no-reboot` stages a new installer image without installing it,
so the node keeps running its current Talos version until you deliberately
upgrade, but you should still know it is in there.

Use `MODE=auto` only when you accept a reboot, and only with quorum intact.

Verify:

```bash
talosctl -n <node-ip> get machineconfig -o yaml | grep -A3 nodeTaints
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints'
```

---

## Procedure B: Full node wipe and rejoin

Use when the disk was replaced or the node cannot be recovered.

### 1. Confirm quorum and drain

```bash
talosctl -n 10.20.0.14 etcd members   # other two nodes must be healthy
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force
```

Pods bound to that node's `openebs-hostpath` volumes will not drain — they have
nowhere to go. That is expected; handle them in
[post-rebuild recovery](#post-rebuild-recovery).

### 2. Remove the old etcd member

A wiped node rejoins as a new member. Leaving the stale one behind keeps the
cluster at 3 members with one permanently down.

```bash
talosctl -n <node-ip> reset --graceful=false --reboot \
  --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL
```

If the node is already dead and cannot be reset gracefully, remove its member
from a surviving node:

```bash
talosctl -n 10.20.0.14 etcd remove-member <hostname>
```

### 3. Reinstall and apply config

Boot the node from the Talos installer, then:

```bash
task talos:generate-config
task talos:apply-node IP=<node-ip> MODE=auto
```

### 4. Wait for it to rejoin

```bash
kubectl get nodes -w
talosctl -n 10.20.0.14 etcd members    # should list 3 healthy members again
kubectl uncordon <node>
```

A rebuilt node registers a **new** Node object, so its `AGE` resets to minutes.
That is the quickest way to tell a rebuild from a reboot.

---

## Post-rebuild recovery

### CloudNativePG: replace the lost instance

If the node held a postgres instance, CNPG will be stuck: it still references a
PVC whose directory no longer exists, and it will refuse to promote the intact
instances while that one is in the way. Symptoms:

```bash
kubectl get cluster -n database postgres17
# STATUS: Waiting for the instances to become active

kubectl get cluster -n database postgres17 \
  -o jsonpath='healthy={.status.healthyPVC}{"\n"}dangling={.status.danglingPVC}{"\n"}'
# The lost instance appears as "healthy"; the intact ones as "dangling"
```

Confirm the data really is gone before deleting anything — the pod's events
will show `path ... does not exist` on mount. Then remove the dead instance so
CNPG can proceed:

```bash
kubectl delete pod -n database postgres17-<N>
kubectl delete pvc -n database postgres17-<N>
```

CNPG promotes a surviving instance and clones a fresh replica. Watch it:

```bash
kubectl get cluster -n database postgres17 -w
```

If a stale pod lingers referencing the deleted PVC (`persistentvolumeclaim ...
not found`), delete the pod again so CNPG provisions a new instance.

Because `openebs-hostpath` uses `WaitForFirstConsumer`, the replacement PVC
binds wherever the new pod schedules, so the replica lands on the rebuilt node
if there is room.

### Verify images pulled onto the rebuilt node

Spegel mirrors images peer-to-peer between nodes. A node with a failing disk can
serve a **truncated layer**, and because containerd keys snapshots by layer
digest it will reuse the bad snapshot instead of re-downloading — so a re-pull
looks instant and stays broken.

Symptoms are `exec format error` or immediate `SIGSEGV` (exit code 139) from a
freshly pulled image that runs fine on another node.

```bash
# Compare a suspect binary against a known-good node
kubectl debug node/<good-node> -it --image=alpine -- sha256sum /path/to/binary
```

To bypass Spegel and pull straight from the upstream registry, use `ctr`, which
uses its own resolver and ignores containerd's mirror config:

```bash
ctr -n k8s.io images pull <image>
```

A genuine transfer takes seconds to minutes; a 100 ms "pull" of a large image
means containerd reused what it already had.

### VolSync caches

Cache PVCs on the lost node are recreated automatically. If a ReplicationSource
is stuck, unlock the restic repo:

```bash
task volsync:unlock
```

### Ceph

Ceph rebalances on its own once the node returns. Confirm it recovers:

```bash
task rook:status
task rook:health
```

Expect `HEALTH_OK` with all OSDs `up`/`in` and PGs `active+clean`. Rebalancing
after a node returns can take 10–15 minutes.

---

## Verification checklist

```bash
# All nodes Ready, no unexpected taints
kubectl get nodes -o wide
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints'

# etcd back to three healthy members
talosctl -n 10.20.0.14 etcd members

# Storage healthy
task rook:status

# Database healthy, one instance per node
kubectl get cluster -n database postgres17
kubectl get pods -n database -o wide | grep postgres

# Nothing stuck
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# GitOps reconciled
flux get kustomizations -A | grep -v True
```

### If pods stay Pending after the rebuild

A returning node is empty, so the scheduler will pack new work onto it, but
existing pods do not move on their own — they are only rebalanced by the
descheduler or when deleted. Meanwhile pods pinned to local PVs cannot move at
all.

```bash
# Compare requests against allocatable to find the real constraint
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'
```

Two things are worth checking before assuming the cluster is out of capacity:

- **Stale taints.** A `NoSchedule` taint left over from a decommissioned
  workload will silently exclude a node that has plenty of room.
- **Requests, not usage.** Pods are scheduled on *requests*. A node can sit at
  40% real memory use and still be unschedulable. Compare with
  `kubectl top nodes`; if the two diverge sharply, the requests are the problem,
  not the hardware.
