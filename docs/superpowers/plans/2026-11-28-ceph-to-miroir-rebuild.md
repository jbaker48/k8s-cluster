# Rebuild on Miroir Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tear the cluster down and rebuild it on Talos v1.14.7 with Miroir replacing Rook-Ceph. All app data is restored automatically from VolSync and CNPG backups.

**Architecture:** The plan has three phases.

- **Phase A, the live cluster (`main`, merged normally):** get every backup current and add the three apps that have none.
- **Phase B, branch `feat/miroir-rebuild` (not merged until teardown):** all repo changes for Talos 1.14, Miroir, re-pointing storage, Postgres and removing Ceph.
- **Phase C, operational cutover:** a pre-flight gate script blocks teardown until backups are proven fresh. Then reset, wipe, bootstrap, and let Flux and VolSync restore.

**Tech Stack:** Talos v1.14.7 (talhelper), Kubernetes v1.35.6, Flux, Miroir chart 0.12.x (`oci://ghcr.io/home-operations/charts/miroir`), VolSync (restic → MinIO at `10.20.0.3:9000`), CNPG (barman → `s3://postgresql/`).

**Spec:** `docs/superpowers/specs/2026-11-28-ceph-to-miroir-rebuild-design.md`

## Global Constraints

- Talos **v1.14.7**, Kubernetes **v1.35.6**, set identically in `talenv.yaml` and `talconfig.yaml`.
- Talos schematic adds `siderolabs/drbd`. Kernel modules: `drbd` with `usermode_helper=disabled`, plus `drbd_transport_tcp`. Kubelet: `shutdownGracePeriod: 120s`, `shutdownGracePeriodCriticalPods: 60s`.
- StorageClasses:
  - `miroir-replicated`: `replicas: "2"`, **default**, quorum policy left at the chart default (`freeze`, which adds a tie-breaker automatically on 3 nodes)
  - `miroir-local`: `replicas: "1"`
  - both `WaitForFirstConsumer` and `allowVolumeExpansion: true`
- VolumeSnapshotClass `miroir-snap`.
- Miroir pools: one `default` `lvmthin` pool per node, on a SATA SSD addressed by `/dev/disk/by-id`. **Never** the Patriot P320 NVMe system disks.
- CNPG: recover from `postgres17-v3`, write backups as `postgres17-v4`.
- **Every YAML file** starts with `---` and its schema header (see CLAUDE.md). `task validate:all` must pass on every commit.
- No `kubectl apply` for desired state. The only imperative actions are Phase A cleanup and Phase C cutover, done by hand.

## Disk map (read from the nodes 2026-11-28)

| Node | Miroir `default` pool device | Notes |
|---|---|---|
| talos01 | `/dev/disk/by-id/ata-CT500MX500SSD1_2432E8BE7312` | CT500MX500SSD1 (user-chosen 2026-11-28). The NT-512 `ata-NT-512_9110601100331` is wiped and left unused. |
| talos02 | `/dev/disk/by-id/ata-Timetec_SD08_TS250325A512G0088` | 15% wear |
| talos03 | `/dev/disk/by-id/ata-CT500MX500SSD1_2403E88F7DD2` | 154% wear (option A accepted) |

## Review Focus

1. **A VolSync source synced long ago but looks fine.** `lastSyncTime` alone hides stuck movers; today 11 sources are stale behind `Synchronizing=True`. The gate must fail on age, not just on a condition. (Pinned in Task 2.)
2. **Restore runs before Miroir is ready.** If an app PVC is created before the StorageClass or snapshot class exists, it stays Pending, or VolSync's populator fails. Every app with a PVC must depend on `miroir-config`. (Pinned in Task 6.)
3. **The wrong install disk.** talos01 has two SATA SSDs, and talos02/03 use `installDisk: /dev/nvme0n1`, which can renumber. Every node must select the P320 by a stable selector. (Pinned in Task 4.)
4. **Leftover Ceph references** break the build or Flux (for example `dependsOn: rook-ceph-cluster` blocks an app forever on a fresh cluster). (Pinned in Task 8.)
5. **Workload isolation on Talos 1.14** breaks host-path users: the Miroir agent, openebs-hostpath and the `/var/mnt/extra` rshared bind. (Pinned in Task 10.)

---

## Phase A: live cluster (branch per task, merge to `main`)

### Task 1: Get VolSync syncing again

Root cause, found 2026-11-28:
- Mover cache PVCs (`volsync-src-*-cache`, `volsync-dst-*-cache`, openebs-hostpath) are pinned to talos02. Their host directories disappeared when talos02's system disk was replaced, so the mover pods sit in `ContainerCreating` with `path "/var/mnt/extra/openebs/local/pvc-…" does not exist`.
- Plex's restic repository holds a stale lock from 2026-11-21.

**Files:** none (imperative cleanup)

- [ ] **Step 1: List mover cache PVCs whose PV is pinned to talos02**

Run: `kubectl get pv -o json | jq -r '.items[] | select(.spec.storageClassName=="openebs-hostpath") | select(.spec.claimRef.name|test("^volsync-")) | select(.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]=="talos02") | "\(.spec.claimRef.namespace) \(.spec.claimRef.name)"'`
Expected: a list of cache PVCs. Check that **none** is a CNPG `postgres17-*` PVC.

- [ ] **Step 2: Delete the stuck mover Jobs, then those cache PVCs**

Run, for each listed namespace/name: `kubectl -n <ns> delete job volsync-src-<app> --ignore-not-found` and `kubectl -n <ns> delete pvc <name>`. VolSync recreates the caches on the next sync.

- [ ] **Step 3: Clear stale restic locks**

Run: `task volsync:unlock`
Expected: completes without error.

- [ ] **Step 4: Trigger a sync for every source and verify**

Run: `for r in $(kubectl get replicationsource -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}'); do task volsync:snapshot NS=${r%/*} APP=${r#*/}; done`
Then: `kubectl get replicationsource -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,LAST:.status.lastSyncTime,RESULT:.status.latestMoverStatus.result`
Expected: all 13 have `LAST` within the last hour and `RESULT=Successful`.

### Task 2: Pre-flight gate script

**Files:**
- Create: `scripts/rebuild-preflight.sh`
- Modify: `Taskfile.yaml`: add task `rebuild:preflight` running the script

**Interfaces:**
- Produces: `scripts/rebuild-preflight.sh [--max-age-minutes N]`, default 90. Exits 0 only if every check passes. Prints one `✅`/`❌` line per check and a summary, following the repo's script style (`set -euo pipefail`, an `ERRORS` counter, errors to stderr).

Checks:
1. Every ReplicationSource has `.status.lastSyncTime` within N minutes **and** `.status.latestMoverStatus.result == "Successful"`.
2. ReplicationSources exist for every name in a required list: the current 13 plus `matter-server`, `mosquitto` and `frigate`.
3. The newest `backup.postgresql.cnpg.io` in `database` is `completed`, with `.status.stoppedAt` within N minutes.
4. No VolSync mover pod is in a non-Running, non-Succeeded state for more than 10 minutes.

- [ ] **Step 1: Run against the cluster before Task 3 merges, to prove it fails**

Run: `task rebuild:preflight`
Expected: exit ≠ 0, with `❌` for the missing `matter-server`, `mosquitto` and `frigate` sources (check 2). If Task 1's syncs are older than 90 minutes, check 1 fails too.

- [ ] **Step 2: Run with a tiny window to prove the age check works**

Run: `scripts/rebuild-preflight.sh --max-age-minutes 1`
Expected: exit ≠ 0, with `❌` for age on every source.

- [ ] **Step 3: `task validate:all`, then commit**

```bash
git add scripts/rebuild-preflight.sh Taskfile.yaml
git commit -m "feat(scripts): add rebuild pre-flight backup gate"
```

### Task 3: Back up matter-server, mosquitto and frigate

These apps' PVCs already exist and **PVC specs are immutable**, so on the live cluster they get only the backup half of the template (ExternalSecret, ReplicationSource, ReplicationDestination). Their PVCs switch to the template claim in Task 6.

Frigate's `ks.yaml` already sets `VOLSYNC_CAPACITY` and `VOLSYNC_SCHEDULE` but never includes the template, which is why it has no backup.

**Files:**
- Create: `kubernetes/templates/volsync/source/kustomization.yaml` (resources: `../minio.yaml`; see the step below on load restrictions)
- Modify: `kubernetes/apps/home/matter-server/app/kustomization.yaml`, `kubernetes/apps/home/mosquitto/app/kustomization.yaml`, `kubernetes/apps/home/frigate/app/kustomization.yaml`: add `../../../../templates/volsync/source`
- Modify: `kubernetes/apps/home/matter-server/ks.yaml`, `kubernetes/apps/home/mosquitto/ks.yaml`: add `postBuild.substitute` with `APP`, `VOLSYNC_CAPACITY` (matter-server `1Gi`, mosquitto `5Gi`) and `VOLSYNC_SCHEDULE` (`"30 * * * *"`, `"35 * * * *"`), and `dependsOn: volsync`

**Interfaces:**
- Produces: `kubernetes/templates/volsync/source`, the backup-only template. Task 6 keeps using `kubernetes/templates/volsync` (claim plus source) for the full template.

- [ ] **Step 1: Check whether kustomize lets `source/` reference `../minio.yaml`**

Run: `kustomize build kubernetes/templates/volsync/source`
Expected: either it builds, or it fails with "is not in or below". On failure, **move** `minio.yaml` into `source/` and change `kubernetes/templates/volsync/kustomization.yaml` to list `./claim.yaml` and `./source`. Don't copy the file.

- [ ] **Step 2: Build each app**

Run: `for a in matter-server mosquitto frigate; do kustomize build kubernetes/apps/home/$a/app | grep -E "^kind: (ReplicationSource|ReplicationDestination|ExternalSecret)"; done`
Expected: each app prints ReplicationSource, ReplicationDestination and at least one ExternalSecret, and **no** second PersistentVolumeClaim named after the app.

- [ ] **Step 3: Confirm the existing 13 apps still build the same**

Run: `kustomize build kubernetes/apps/home/zigbee2mqtt/app | grep -c "^kind:"` before and after the change.
Expected: the same count.

- [ ] **Step 4: `task validate:all`, commit, merge to `main`, `task reconcile`**

- [ ] **Step 5: Verify the first backups**

Run: `task volsync:snapshot NS=home APP=<app>` for each of the three, then `task rebuild:preflight`.
Expected: the preflight passes (exit 0).

---

## Phase B: branch `feat/miroir-rebuild` (do not merge until Task 9)

Rebase this branch onto `main` after Phase A merges.

### Task 4: Talos v1.14.7 config

**Files:**
- Modify: `kubernetes/bootstrap/talos/talenv.yaml`
  - `talosVersion: v1.14.7`, `kubernetesVersion: v1.35.6`
  - Renovate comment for `talosVersion`: change it from `ghcr.io/siderolabs/installer` to a datasource that Talos 1.14 still publishes (`github-releases` `siderolabs/talos`)
- Modify: `kubernetes/bootstrap/talos/talconfig.yaml`
  - same versions and Renovate comment change
  - `siderolabs/drbd` added to `schematic.customization.systemExtensions.officialExtensions`
  - DRBD modules: use a `KernelModuleConfig` document if talhelper emits Talos 1.14 multi-doc; otherwise extend the existing `machine.kernel.modules` patch, which already loads `ax88179_178a`
  - kubelet graceful shutdown added to the existing kubelet `extraConfig` patch
  - talos02 and talos03: replace `installDisk: "/dev/nvme0n1"` with `installDiskSelector: { model: "Patriot M.2 P320 512GB" }`
  - talos01: keep the `busPath` selector, and rewrite the comment: "SATA SSDs (MX500 = Miroir pool, NT-512 unused) must never be selected as the install disk."
- Modify: `.taskfiles/talos/Taskfile.yaml`: `MODE` must not offer `reboot`, which Talos 1.14 removed. Keep the default `auto`.
- Modify: `.mise.toml`: only if Step 1 shows talhelper needs a newer pin.

- [ ] **Step 1: Check talhelper supports 1.14**

Run: `talhelper genconfig --dry-run 2>&1 | head` (or `talhelper validate talconfig kubernetes/bootstrap/talos/talconfig.yaml`) after the version bump.
Expected: no errors. On "unsupported version", upgrade talhelper.

- [ ] **Step 2: Generate configs**

Run: `task talos:generate-config`
Expected: success, with files in `kubernetes/bootstrap/talos/clusterconfig/`.

- [ ] **Step 3: Assert on the generated config**

Run: `for f in kubernetes/bootstrap/talos/clusterconfig/home-kubernetes-talos0*.yaml; do echo $f; grep -c "drbd" $f; grep -E "shutdownGracePeriod(CriticalPods)?:" $f; grep -A2 -E "installDisk(Selector)?:" $f; grep -E "workloadIsolation" $f || echo "workloadIsolation: (not emitted)"; done`
Expected, per node:
- `drbd` appears in both the image or extension and the modules
- both grace periods present (`120s`, `60s`)
- talos02 and talos03 show the `model:` selector
- the workloadIsolation line is recorded for Task 10

- [ ] **Step 4: `task validate:all`, then commit**

```bash
git commit -am "feat(talos): v1.14.7 with DRBD for Miroir"
```

### Task 5: Deploy Miroir

**Files (create):**
- `kubernetes/apps/miroir-system/kustomization.yaml`: resources `./namespace.yaml`, `./miroir/ks.yaml`
- `kubernetes/apps/miroir-system/namespace.yaml`: copy the labels from `kubernetes/apps/rook-ceph/namespace.yaml`; the agent is privileged
- `kubernetes/apps/miroir-system/miroir/ks.yaml`: two Flux Kustomizations, following the `rook-ceph` / `rook-ceph-cluster` pattern
  - `miroir`: path `.../app`, `wait: true`, `prune: false`
  - `miroir-config`: path `.../config`, `dependsOn: [miroir]`, `wait: true`, `prune: false`
  - both: `targetNamespace: miroir-system`, `retryInterval: 1m`, `interval: 30m`
- `kubernetes/apps/miroir-system/miroir/app/{kustomization,ocirepository,helmrelease}.yaml`
  - OCIRepository: `oci://ghcr.io/home-operations/charts/miroir`, tag `0.12.14`, with the `layerSelector` for helm chart content
  - HelmRelease values:
    - `gateway.enabled: true` (RWX for gha-cache)
    - `monitoring.podMonitor.enabled: true`
    - `monitoring.prometheusRule.enabled: true`
    - `monitoring.dashboards.enabled: true` with `labels: { grafana_dashboard: "1" }` (the label grafana's sidecar watches)
  - Use the system HelmRelease schema, and the standard install/upgrade remediation from CLAUDE.md
- `kubernetes/apps/miroir-system/miroir/config/kustomization.yaml`
- `kubernetes/apps/miroir-system/miroir/config/miroirnode.yaml`: three `MiroirNode` (names `talos01`, `talos02`, `talos03`), each with `pools: [{name: default, lvmthin: {device: <disk map>}}]`
- `kubernetes/apps/miroir-system/miroir/config/storageclass.yaml`: `miroir-replicated` (annotation `storageclass.kubernetes.io/is-default-class: "true"`) and `miroir-local`, per Global Constraints. Parameters `miroir.home-operations.com/replicas` and `csi.storage.k8s.io/fstype: ext4`.
- `kubernetes/apps/miroir-system/miroir/config/volumesnapshotclass.yaml`: `miroir-snap`, driver `miroir.home-operations.com`, `deletionPolicy: Delete`. Annotation `snapshot.storage.kubernetes.io/is-default-class: "true"`.

**Files (modify):**
- `.taskfiles/bootstrap/Taskfile.yaml:53`: replace the `rook-ceph/namespace.yaml` line with `miroir-system/namespace.yaml`

**Interfaces:**
- Produces: Flux Kustomization **`miroir-config`** in `flux-system`, which every app with a PVC depends on (Task 6). StorageClasses `miroir-replicated`, `miroir-local`. Snapshot class `miroir-snap`.

- [x] **Step 0: Confirm the talos01 disk choice.** Decided: MX500 (`ata-CT500MX500SSD1_2432E8BE7312`), 2026-11-28. The NT-512 is wiped and left unused.

- [ ] **Step 1: Build and check the config**

Run: `kustomize build kubernetes/apps/miroir-system/miroir/config | yq -r 'select(.kind=="StorageClass") | .metadata.name + " " + .parameters["miroir.home-operations.com/replicas"] + " " + (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "")'`
Expected:
```
miroir-replicated 2 true
miroir-local 1
```

- [ ] **Step 2: Check the CRD fields against the chart's CRDs**

Run: `helm template miroir oci://ghcr.io/home-operations/charts/miroir --version 0.12.14 --include-crds | yq 'select(.kind=="CustomResourceDefinition" and .metadata.name=="miroirnodes.miroir.home-operations.com") | .spec.versions[0].name'`
Expected: `v1alpha1`. The `miroirnode.yaml` `apiVersion` must match.

- [ ] **Step 3: `task validate:all`, then commit**

### Task 6: Point storage at Miroir

**Files:**
- `kubernetes/templates/volsync/claim.yaml` and `minio.yaml` (or `source/minio.yaml` after Task 3):
  - `ceph-block` → `miroir-replicated` (all three occurrences)
  - `csi-ceph-blockpool` → `miroir-snap` (both)
- **`dependsOn: rook-ceph-cluster` → `miroir-config`** in these `ks.yaml` files: `home/frigate`, `network/unifi`, `observability/loki`, `media/{radarr,lidarr,plex,sonarr}`
- **Delete the `rook-ceph-cluster` HelmRelease `dependsOn` entries** (no replacement; the ks-level dependency covers it): `home/emhass`, `home/frigate`, `home/home-assistant`, `home/home-assistant-v2`, `observability/loki`, `observability/kube-prometheus-stack`, `media/plex`
- **Add `dependsOn: miroir-config`** to every other `ks.yaml` whose app has a PVC or includes `templates/volsync`. Find them with `grep -rl "templates/volsync\|kind: PersistentVolumeClaim\|storageClass" kubernetes/apps/*/*/app | cut -d/ -f3-4 | sort -u`.
- `kubernetes/apps/home/{matter-server,mosquitto,frigate}/app/kustomization.yaml`: change `../../../../templates/volsync/source` to `../../../../templates/volsync`, and remove `pvc.yaml` / `data-pvc.yaml` from resources. Delete `matter-server/app/pvc.yaml`, `mosquitto/app/data-pvc.yaml` and `frigate/app/pvc.yaml`.
- `kubernetes/apps/media/plex/app/pvc.yaml` (`plex-cache`): change to `miroir-local`
- `kubernetes/apps/observability/loki/app/helmrelease.yaml:63`: change to `miroir-local`
- `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml`: line 98 (Prometheus) → `miroir-local`; line 154 (Alertmanager) → `miroir-replicated`. Check which block is which before editing.
- `kubernetes/apps/arc-runners/gha-cache-server/app/pvc.yaml`: change to `miroir-replicated` with `ReadWriteMany` (served by the Miroir gateway), and rewrite the D-07 header comment to say this

**Interfaces:**
- Consumes: `miroir-config`, `miroir-replicated`, `miroir-local`, `miroir-snap` (Task 5).

- [ ] **Step 1: No storage-related Ceph references left in `kubernetes/apps` outside rook-ceph**

Run: `grep -rn -E "ceph-block|ceph-filesystem|csi-ceph|rook-ceph-cluster" kubernetes --exclude-dir=rook-ceph`
Expected: no output.

- [ ] **Step 2: Every PVC-owning app depends on `miroir-config`**

Run: `for d in $(grep -rl "templates/volsync\|kind: PersistentVolumeClaim\|storageClass" kubernetes/apps/*/*/app | cut -d/ -f1-4 | sort -u); do grep -q "name: miroir-config" $d/ks.yaml || echo "MISSING $d"; done`
Expected: no `MISSING` lines. CNPG (openebs-hostpath) and static NFS PVs are allowed exceptions; note them in the commit message if listed.

- [ ] **Step 3: The three home apps now build the template claim with `dataSourceRef`**

Run: `for a in matter-server mosquitto frigate; do kustomize build kubernetes/apps/home/$a/app | yq 'select(.kind=="PersistentVolumeClaim") | .metadata.name + " " + .spec.dataSourceRef.kind + " " + .spec.storageClassName'; done`
Expected: `${VOLSYNC_CLAIM:-${APP}} ReplicationDestination ${VOLSYNC_STORAGECLASS:-miroir-replicated}`, once per app.

- [ ] **Step 4: `task validate:all`, then commit**

### Task 7: Postgres recovery source

**Files:**
- Modify: `kubernetes/apps/database/cloudnative-pg/cluster/cluster17.yaml`
  - `serverName: &currentCluster postgres17-v3` → `postgres17-v4`
  - `source: &previousCluster postgres17-v2` → `postgres17-v3`

- [ ] **Step 1: Verify the archive being restored from exists**

Run: `kubectl -n database get backup.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].status.serverName} {.items[-1].status.phase}'`
Expected: `postgres17-v3 completed`

- [ ] **Step 2: Check the built manifest**

Run: `kustomize build kubernetes/apps/database/cloudnative-pg/cluster | yq 'select(.kind=="Cluster") | [.spec.backup.barmanObjectStore.serverName, .spec.bootstrap.recovery.source, .spec.externalClusters[0].barmanObjectStore.serverName]'`
Expected: `[postgres17-v4, postgres17-v3, postgres17-v3]`

- [ ] **Step 3: Commit**

### Task 8: Remove Ceph, add the Miroir runbook, alerts and exclusion gate

**Files:**
- **Delete:**
  - `kubernetes/apps/rook-ceph/`
  - `kubernetes/flux/repositories/helm/rook-ceph.yaml`, and its line in `kubernetes/flux/repositories/helm/kustomization.yaml`
  - `.taskfiles/rook-ceph/`, and the `rook:` include at `Taskfile.yaml:25`
- **Modify:**
  - `.github/renovate.json5`: delete the Rook-Ceph package rule (around line 87–93). Remove `"!rook-ceph", "!rook-ceph-cluster"` from the group exclusion (line 102), and "Rook-Ceph" from the comment on line 96. Add an equivalent dashboard-approval rule for the Miroir chart (`matchPackageNames: ["miroir"]`, helm/docker OCI datasource).
  - `.github/exclusion-gate.yaml`: replace the `rook-ceph:` entry with `miroir:`. Reason: "Miroir is the cluster's replicated block storage; a bad driver/chart/config change can make every PVC unavailable or lose data cluster-wide." Paths: `kubernetes/apps/miroir-system/**`.
  - `kubernetes/apps/tools/descheduler/app/helmrelease.yaml:68`: `rook-ceph` → `miroir-system`
  - `kubernetes/apps/observability/grafana/app/helmrelease.yaml:131-145`: delete the three Ceph dashboards (Miroir ships its own through Task 5)
  - `kubernetes/apps/kube-system/devin-readonly/app/rbac.yaml:77`: `ceph.rook.io` → `miroir.home-operations.com`
  - `kubernetes/bootstrap/talos/talconfig.yaml`: any remaining Ceph mention
- **Create:** `docs/runbooks/miroir-volume-outdated.md`, with the four steps from the spec's "Recovery runbook". Name the alert `MiroirVolumeNotUpToDate`, the symptom `Creating 0/2` / `no reachable UpToDate replica`, and link miroir#636 and LINBIT/drbd#171.

- [ ] **Step 1: No Ceph anywhere**

Run: `grep -rn -i "ceph\|rook" --exclude-dir=.git --exclude-dir=docs --exclude-dir=.private . | grep -v "^./kubernetes/bootstrap/talos/clusterconfig/"`
Expected: no output.

- [ ] **Step 2: The Flux tree builds**

Run: `task validate:all`
Expected: PASS.

- [ ] **Step 3: Commit, push the branch, open a draft PR titled "Rebuild on Miroir (merge only during cutover, #1228)"**

---

## Phase C: cutover (by hand, the user present)

### Task 9: Teardown and rebuild

- [ ] **Step 1: Gate.** `task rebuild:preflight` (exit 0). Export the Zigbee coordinator backup from the zigbee2mqtt UI to a local file.
- [ ] **Step 2: Final backups.** Scale the home and media apps to 0 with `flux suspend` plus scale-down. Run `task volsync:snapshot` for all 16 sources and trigger a CNPG backup (`kubectl cnpg backup postgres17 -n database`). Then `scripts/rebuild-preflight.sh --max-age-minutes 30` → exit 0.
- [ ] **Step 3: Stop Flux.** `flux suspend kustomization --all -n flux-system`
- [ ] **Step 4: Reset.** `task talos:reset`. Nodes return to maintenance mode.
- [ ] **Step 5: Merge** the draft PR to `main` (rebased, `task validate:all` green).
- [ ] **Step 6: Bootstrap Talos.** `task bootstrap:talos` (talconfig now v1.14.7 with DRBD).
- [ ] **Step 7: Wipe the data disks before Miroir starts.** On each node: `talosctl -n <ip> wipe disk sda` (talos02, talos03) and `talosctl -n 10.20.0.14 wipe disk sda sdb`. Confirm: `talosctl -n <ip> get discoveredvolumes` shows no `bluestore` label.
- [ ] **Step 8: Bootstrap the rest.** `task bootstrap:apps`, then `task bootstrap:flux`.
- [ ] **Step 9: Watch the restore.** `flux get kustomizations -A --status-selector ready=false` until empty. `kubectl get pvc -A | grep -v Bound` until empty.

### Task 10: Verify and close

- [ ] **Step 1: Storage healthy.** Run `kubectl get miroirnodes,miroirvolumes -A`. All volumes should be healthy, replicated ones with 2/2 UpToDate.
- [ ] **Step 2: Workload isolation check (Review Focus 5).** Confirm each of these runs, and that a test PVC on each StorageClass mounts and writes:
  - the Miroir agent pods
  - an openebs-hostpath PVC (CNPG pods Running, data path under `/var/mnt/extra/openebs/local`)
  - the RWX gha-cache PVC

  If any fails because of sandboxd, add `SecurityProfileConfig` with `workloadIsolation: false` in talconfig. Write the reason in a comment, and apply it with `task talos:apply-node` per node.
- [ ] **Step 3: Apps.**
  - Home Assistant loads with its history.
  - A Zigbee device responds.
  - A Matter device is controllable (no re-pairing).
  - MQTT retains topics.
  - Frigate config is present.
  - Plex and the *arr apps show their libraries.
  - Postgres: `kubectl cnpg status postgres17 -n database` shows 3 instances healthy.
- [ ] **Step 4: Alert routing.** Check that the Alertmanager route sends `MiroirVolumeNotUpToDate` to a real receiver: `kubectl -n observability exec alertmanager-kube-prometheus-stack-0 -- amtool config routes test --config.file=/etc/alertmanager/config_out/alertmanager.env.yaml alertname=MiroirVolumeNotUpToDate severity=warning` names a receiver other than `null`/blackhole. If not, add a route in the kube-prometheus-stack values (a Phase B follow-up commit).
- [ ] **Step 5: Backups resume.** Wait one hour, then run `task rebuild:preflight` (exit 0). The first `postgres17-v4` backup completes.
- [ ] **Step 6: Node failure drill.** `kubectl drain talos03 --ignore-daemonsets --delete-emptydir-data`, then reboot it. Replicated apps should move and keep their data; afterwards MiroirVolumes return to 2/2. Uncordon.
- [ ] **Step 7: Close out.** Comment on #1228 with the results, update the memory notes on disk health (Ceph is gone; the MX500 on talos03 holds Miroir data), and close the issue.
