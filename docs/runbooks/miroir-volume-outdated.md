# Runbook: Miroir volume has no UpToDate replica

Alert: `MiroirVolumeNotUpToDate`

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
- Before planned switch or UniFi maintenance, cordon nothing, but expect a possible
  recovery afterwards. Run `kubectl get miroirvolumes` after any network blip.
- The `MiroirVolumeNotUpToDate` alert must reach you (Alertmanager), not just a dashboard.

## Recovery

1. Identify the affected volumes (`Creating`, `0/2`):

   ```bash
   kubectl get miroirvolumes
   ```

2. Preferred: scale the app to 0, delete the PVC, and let Flux recreate it. VolSync's
   `dataSourceRef` fills the new volume from the last hourly snapshot. Expect to lose up
   to one hour of data.
3. Alternative, with no data loss: force-promote the newest leg, following the Miroir
   troubleshooting docs or the recovery steps in the issue. Use this only when the last
   hour of data matters (for example Home Assistant).
4. Re-check this runbook when miroir#636 is closed, and delete it if it is no longer needed.
