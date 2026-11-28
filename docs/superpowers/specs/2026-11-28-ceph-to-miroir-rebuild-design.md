# Rebuild the cluster with Miroir instead of Rook-Ceph

Date: 2026-11-28 · Issue: #1228 · Status: approved 2026-11-28

## Intent

Get off Rook-Ceph cleanly. Do it with a full cluster rebuild rather than an in-place migration, so that no Ceph state, CRDs, finalizers, `/var/lib/rook` data or leftover disk signatures survive. Everything other than storage stays as it is: same nodes, same Talos/Flux/SOPS layout, same apps. VolSync stays as the backup and restore mechanism.

**Why:** Ceph costs about 1.3 CPU cores and 9 GiB of RAM on a 3-node homelab. It also spent 6 days degraded after talos02's system disk was replaced. [Miroir](https://github.com/home-operations/miroir) offers LVM-thin block storage with optional DRBD9 replication, working CSI snapshots and far less overhead.

## Goals

- Rook-Ceph completely gone: the operator, the cluster, CRDs, the `rook-ceph` namespace, StorageClasses, the VolumeSnapshotClass, alert rules, the dashboard route, Taskfile tasks, Renovate rules and exclusion-gate entries.
- Miroir provides all block storage, plus RWX for `gha-cache-server`.
- Every app with state comes back with its data, restored automatically by Flux and VolSync from MinIO on the NAS.
- Home apps come back on their own. The user checks them afterwards; nothing is brought up by hand.

## Non-goals

- No other redesign: Cilium, Envoy, secrets, app set and namespaces stay unchanged. The Talos 1.14 jump is the one exception, and is limited to what it requires (see Design → Talos).
- No replacement for VolSync (for example Kopia-based operators). That would be a separate project.
- No change to Postgres storage. CNPG stays on `openebs-hostpath` with its own replication, and is restored from barman.
- No disk purchases (option A was chosen).

## Anti-goals (failure even if the cluster comes up)

- **Losing data that had no backup.** matter-server is the critical case: losing it means re-pairing every Matter device.
- **Restoring stale data without knowing.** 11 of the 13 VolSync sources last synced around 2026-11-22.
- **Putting Miroir pools on the Patriot P320 system disks** (DRAM-less; one already hung talos02).
- **Accidentally selecting a SATA SSD as the Talos install disk** during reinstall.

## Constraints

- **Nodes:** talos01, talos02 and talos03 are all control-plane and schedulable. Data disks:
  - talos01 `sdb`: Crucial MX500 500GB, 144% wear
  - talos02 `sda`: Timetec SD08 512GB, 15% wear
  - talos03 `sda`: Crucial MX500 500GB, 154% wear
- **Talos:** currently v1.13.9 (`talenv.yaml`). Miroir needs DRBD ≥ 9.3.1. DRBD older than 9.3.4 has the teardown-wedge refcount bug (LINBIT/drbd#137). The rebuild targets Talos v1.14.7 (DRBD 9.3.5).
- **Miroir requirements on Talos:**
  - the `siderolabs/drbd` extension
  - kernel modules `drbd` (with `usermode_helper=disabled`) and `drbd_transport_tcp`
  - kubelet `shutdownGracePeriod: 120s` and `shutdownGracePeriodCriticalPods: 60s`
- **Backups:** VolSync restic repositories live at `s3:http://10.20.0.3:9000/volsync/<app>`. CNPG barman backups go to `s3://postgresql/` with serverName `postgres17-v3`; the last daily backup completed 2026-11-28.
- **Repo rules:** schema headers on every file, `task validate:all` must pass, and every change is made through Git and Flux.

## Approaches considered

| | Approach | Trade-off | Decision |
|---|---|---|---|
| A | Rebuild on the current disks: wipe the MX500s and the Timetec and give them to Miroir | Nothing to buy and starts as soon as backups are fresh, but data lives on two drives past rated wear | **Chosen** |
| B | Rebuild with new SSDs in talos01 and talos03 | No worn disks and no early disk swap, but means waiting for parts and about AUD 150 | Rejected by user |
| — | Rolling rebuild one node at a time | Ceph needs 2 of 3 nodes throughout, so this turns back into an in-place migration | Ruled out |
| — | Miroir pools on the system disks | DRAM-less P320s, one already failed | Ruled out |

## Design

### Talos (`kubernetes/bootstrap/talos/`)

- **Version:** rebuild on **Talos v1.14.7** (decided by the user). It ships Linux 6.18.65 and **DRBD 9.3.5**, so it includes the 9.3.4 refcount fix. Miroir's e2e suite runs on Talos 1.14 (home-operations/miroir#385). Set it in both `talenv.yaml` and `talconfig.yaml`.
- **Kubernetes:** stay on **v1.35.6** for the rebuild (builder's call: one big change at a time; move to 1.36/1.37 later as a normal upgrade). Fix the existing mismatch: `talenv.yaml` says v1.35.3 and `talconfig.yaml` says v1.35.6. `talenv.yaml` wins, so set both to v1.35.6.
- **Talos 1.14 changes to handle:**
  - **Workload isolation (sandboxd):** new 1.14 clusters run kubelet, containerd and pods in a separate PID and mount namespace (`SecurityProfileConfig.workloadIsolation: true`). Check whether talhelper 3.1.17 emits it. Then confirm that the things that use host paths still work: the Miroir agent (`/var/lib/kubelet`, DRBD), openebs-hostpath (`/var/mnt/extra/openebs/local`) and the kubelet `extraMounts` bind for `/var/mnt/extra` (rshared). If any of them breaks, set `workloadIsolation: false` explicitly and record why.
  - **Installer image:** `ghcr.io/siderolabs/installer` is no longer published, so use the Image Factory installer. Update the Renovate datasource comment on `talosVersion` in `talenv.yaml`, which currently points at `ghcr.io/siderolabs/installer`, so version tracking keeps working.
  - **Multi-document config:** `.machine.kernel`, `.machine.sysctls`, `.cluster.network`, `.cluster.coreDNS`, `.cluster.apiServer` and others are deprecated in favour of separate documents. They still work. Use `KernelModuleConfig` for the new DRBD modules if talhelper supports it; otherwise use `.machine.kernel.modules`. Migrating the other deprecated fields is out of scope.
  - **`talosctl apply-config --mode=reboot` was removed.** Check `.taskfiles/talos/Taskfile.yaml` (`talos:apply-node` passes `MODE`) and `.taskfiles/bootstrap/Taskfile.yaml` for it.
  - Read the full v1.14.0 to v1.14.7 release notes for anything else that touches this config (Cilium with kube-proxy disabled, DHCP and discovery changes).
- **talhelper:** confirm the installed talhelper (3.1.17) supports Talos 1.14 and its multi-document output. Upgrade it in `.mise.toml` if needed.
- **Schematic:** add `siderolabs/drbd`.
- **Patch:** add the DRBD kernel modules and the kubelet graceful-shutdown settings listed under Constraints.
- **Install disk:** check each node's `installDiskSelector` still pins the NVMe (talos01 uses a `busPath`; confirm talos02 and talos03 do too). Update the talos01 comment that says the SATA SSD "holds the Ceph OSD".
- **Disk wiping:** the SATA SSDs must have no partitions or signatures before Miroir claims them. Run `talosctl wipe disk <dev>` after the reset and before Miroir is deployed. A reset alone may not touch non-system disks.

### Miroir (new app, for example `kubernetes/apps/miroir-system/miroir/`)

- Follow the usual app layout: `ks.yaml`, `app/` (OCIRepository and HelmRelease for chart `oci://ghcr.io/home-operations/charts/miroir`, latest 0.12.x) and `config/` (depends on `app`).
- **One `MiroirNode` per node,** each with pool `default`, `lvmthin.device: /dev/disk/by-id/<data SSD>`.
- **StorageClasses:**
  - `miroir-replicated`: `replicas: "2"`. **Default StorageClass** (decided by the user, accepting the Miroir #636 risk below).
  - `miroir-local`: `replicas: "1"`.
  - Both use `WaitForFirstConsumer` and `allowVolumeExpansion: true`.
- **VolumeSnapshotClass:** `miroir-snap`.
- **Ordering:** Miroir has to be ready before any app with a PVC. Add `dependsOn` from app Kustomizations, or one dependency from VolSync, whichever matches how `rook-ceph-cluster` is wired today.
- **Monitoring:** enable Miroir's metrics and alerts if the chart provides them, in place of the Ceph PrometheusRule.

### Where each volume goes

| StorageClass | Workloads |
|---|---|
| `miroir-replicated` (default) | home-assistant, home-assistant-v2, zigbee2mqtt, mosquitto, matter-server, evcc, emhass, frigate, unifi, plex, *arr (bazarr, lidarr, prowlarr, radarr, sonarr), photoprism, alertmanager |
| `miroir-local` | prometheus, loki, plex-cache |
| Miroir RWX (per `docs/rwx.md`) | gha-cache-server (start empty) |
| `openebs-hostpath` (unchanged) | CNPG postgres17, VolSync mover caches |

Prometheus, Loki and gha-cache come back empty, which is accepted.

### VolSync

- In `kubernetes/templates/volsync/claim.yaml` and `minio.yaml`:
  - change the default `VOLSYNC_STORAGECLASS` from `ceph-block` to `miroir-replicated`
  - change the default `VOLSYNC_SNAPSHOTCLASS` from `csi-ceph-blockpool` to `miroir-snap`
  - keep `copyMethod: Snapshot`
- **Remove per-app `ceph-*` overrides** in the `ks.yaml` files: radarr, lidarr, plex, sonarr, unifi, frigate, loki.
- **Add VolSync** (the template plus an ExternalSecret) to **matter-server, mosquitto and frigate**. Note: frigate's `ks.yaml` already sets `VOLSYNC_SCHEDULE`, but no frigate ReplicationSource exists in the cluster. Find out why before adding anything.
- **Schedule:** every replicated app keeps an hourly VolSync schedule (most already have one). This caps data loss when the #636 fallback is used. Each gets a successful backup before the rebuild.
- **Existing PVCs:** PVC manifests not created by the template (mosquitto `data-pvc.yaml`, matter-server `pvc.yaml`, frigate `pvc.yaml`, plex `pvc.yaml`, gha-cache `pvc.yaml`) switch to Miroir classes. Where they become VolSync-managed, they use the template claim instead.

### Postgres (CNPG)

- **Recovery source:** change `bootstrap.recovery.source` / `externalClusters` from `postgres17-v2` to **`postgres17-v3`**, the serverName current backups are written to.
- **Backup target:** bump the backup `serverName` to **`postgres17-v4`** so the new cluster doesn't write into the archive it's restoring from.

### Ceph removal (repo)

- **Delete:**
  - `kubernetes/apps/rook-ceph/`
  - `kubernetes/flux/repositories/helm/rook-ceph.yaml` and its entry in that directory's `kustomization.yaml`
  - `.taskfiles/rook-ceph/` and the `rook:` include in `Taskfile.yaml`
  - the `rook-ceph` namespace step in `.taskfiles/bootstrap/Taskfile.yaml`
- **Edit:**
  - the Renovate rules for `rook-ceph` in `.github/renovate.json5`
  - the `rook-ceph` entry in `.github/exclusion-gate.yaml`: replace it with an equivalent entry for Miroir
  - the Ceph references in descheduler, grafana (dashboards), kube-prometheus-stack, the `devin-readonly` RBAC, and the emhass and home-assistant HelmReleases
- **Check:** `grep -ri ceph` over the repo returns nothing intentional.

### Cutover runbook (order matters)

1. **Pre-flight gate:** nothing gets wiped until all of these pass.
   1. Find out why VolSync stopped on 2026-11-22, fix it, and get every ReplicationSource to sync successfully.
   2. Merge the VolSync additions for matter-server, mosquitto and frigate, and confirm their first backups exist.
   3. Suspend writes (scale apps down, or keep them up and accept a few minutes of drift). Run `task volsync:snapshot` for every app and confirm with restic that each snapshot exists and is recent.
   4. Take a manual CNPG backup and confirm it completed.
   5. Export anything else not in Git (for example the Zigbee coordinator backup from zigbee2mqtt's UI) as extra insurance.
2. **Merge the rebuild branch** (all the repo changes above) only once the cluster has been torn down, so the old Flux doesn't try to apply it. Alternatively, suspend Flux first.
3. **Tear down:** `task talos:reset`, then wipe the SATA SSDs.
4. **Rebuild:** run `task bootstrap:talos`, `task bootstrap:apps` and `task bootstrap:flux` in order.
5. **Restore:** Flux brings up Miroir, then apps, and VolSync fills each PVC from MinIO. CNPG recovers from `postgres17-v3`.
6. **Verify:**
   - every PVC is Bound and every MiroirVolume is healthy with 2/2 UpToDate replicas
   - the home apps work (Zigbee devices respond, Matter devices are reachable, HA history is present)
   - the first post-rebuild VolSync and CNPG backups succeed

## Decisions and accepted risks

1. **Talos v1.14.7:** decided by the user. Kubernetes stays on v1.35.6 for the rebuild (builder's call).
2. **`miroir-replicated` is the default despite Miroir issue #636 (open, upstream LINBIT/drbd#171):** if every replication link drops at once (a switch reboot or UniFi firmware update), idle 2-replica volumes can end up with both copies Outdated. The MiroirVolume then shows `Creating 0/2` and pods fail with `no reachable UpToDate replica`. Accepted because, on worn MX500s, the second copy is the main protection against disk failure.

   **Mitigations:**
   - Hourly VolSync for every replicated app.
   - Before planned switch or UniFi maintenance, cordon nothing but expect a possible recovery afterwards. Check `kubectl get miroirvolumes` after any network blip.
   - Make sure the `MiroirVolumeNotUpToDate` alert reaches the user, not just a dashboard.

   **Recovery runbook**, to write as `docs/runbooks/miroir-volume-outdated.md`:
   1. Identify the affected volumes (`Creating`, `0/2`).
   2. Preferred: scale the app to 0, delete the PVC, and let Flux recreate it. VolSync's `dataSourceRef` fills it from the last hourly snapshot.
   3. Alternative, with no data loss: force-promote the newest leg, following the Miroir troubleshooting docs or the issue's recovery steps. Use this only when the last hour of data matters (for example Home Assistant).
   4. Re-check this runbook when #636 is closed, and delete it if it's no longer needed.

## Left to the builder

- Exact Miroir chart values and how to wire the `dependsOn` ordering.
- The disk `by-id` paths (read them with `talosctl get disks`).
- Grafana dashboard swaps (remove the Ceph dashboards, add Miroir's if one exists).
- Whether Miroir RWX or an NFS StorageClass suits gha-cache better in practice.
