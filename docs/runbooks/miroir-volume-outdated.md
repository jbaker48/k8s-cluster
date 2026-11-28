# Runbook: Miroir volume has no UpToDate replica

Alerts:

- `MiroirVolumeNoUpToDateReplica` (critical, 5m): the primary alert for this runbook. The
  volume has no UpToDate replica at all (`max by (volume) (miroir_volume_up_to_date) == 0`).
- `MiroirVolumeNotUpToDate` (warning, 15m): the earlier per-leg signal
  (`miroir_volume_up_to_date == 0`). It also fires when one leg's resync is stuck while the
  other leg is healthy. A single NotUpToDate leg with `1/2` ready is a resync problem, not
  this runbook, so do not delete the PVC.

## Symptom

- `kubectl get miroirvolumes` shows a volume stuck at `Creating` with `0/2` replicas.
- Pods using the volume fail to start with `no reachable UpToDate replica`.

## Cause

`miroir-replicated` is the default StorageClass (2 replicas). If every replication
link drops at once (a switch reboot or a UniFi firmware update), idle volumes can end
up with both copies Outdated and nothing to resync from. This is the known risk
tracked in [home-operations/miroir#636](https://github.com/home-operations/miroir/issues/636),
upstream [LINBIT/drbd#171](https://github.com/LINBIT/drbd/issues/171). It was accepted
because, on worn MX500 SSDs, the second copy is the main protection against disk failure.

## Mitigations in place

- Hourly VolSync for every replicated app, which caps data loss when step 2 is used.
- No pre-maintenance action is needed; run `kubectl get miroirvolumes` afterwards.
- The `MiroirVolumeNoUpToDateReplica` alert must reach you (Alertmanager), not just a dashboard.

## Recovery

1. Identify the affected volumes (`Creating`, `0/2`):

   ```bash
   kubectl get miroirvolumes
   ```

2. Preferred: scale the app to 0, delete the PVC, and let Flux recreate it. VolSync's
   `dataSourceRef` fills the new volume from the last hourly snapshot. Expect to lose up
   to one hour of data. Same sequence as `task volsync:restore`:

   ```bash
   flux -n flux-system suspend kustomization <app>
   flux -n <ns> suspend helmrelease <app>
   kubectl -n <ns> scale deployment/<app> --replicas 0   # or statefulset/<app>
   kubectl -n <ns> delete pvc <app>
   flux -n flux-system resume kustomization <app>
   flux -n <ns> resume helmrelease <app>
   flux reconcile kustomization <app> -n flux-system     # recreates the PVC; VolSync fills it
   flux -n <ns> reconcile helmrelease <app> --force      # restores replicas
   ```

   The scale-to-0 is manual, so the HelmRelease reconcile (not a manual scale-up) brings the
   app back. Wait for the pod to become ready.
3. Alternative, with no data loss: force-promote one diskful leg. Upstream's
   [troubleshooting page](https://github.com/home-operations/miroir/blob/main/docs/src/content/docs/troubleshooting.md)
   lists this failure but says nothing recovers it automatically and gives no commands. The
   only suggestion is in [miroir#636](https://github.com/home-operations/miroir/issues/636):
   `drbdadm primary --force` on one diskful leg, then `drbdadm secondary`, reasoned to be safe
   because both legs went Outdated from the same UUID while in sync. That comment says it was
   untested; a later reproduction found the other leg left UpToDate one generation behind,
   stuck in `WFBitMapS` until a reconnect. Treat it as experimental and use it only when the
   last hour of data matters (for example Home Assistant).
4. Re-check this runbook when miroir#636 is closed, and delete it if it is no longer needed.
