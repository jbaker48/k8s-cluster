#!/usr/bin/env bash
# Pre-flight gate for the Miroir rebuild.
# Blocks teardown until every backup is proven fresh.
# Usage: rebuild-preflight.sh [--max-age-minutes N]   (default 90)
# Exits 0 only if every check passes. Read-only against the cluster.
set -euo pipefail

MAX_AGE_MINUTES=90
STUCK_MINUTES=10
ERRORS=0

# Required ReplicationSources as namespace/name.
REQUIRED_SOURCES=(
    home/emhass home/evcc home/home-assistant home/home-assistant-v2
    home/zigbee2mqtt media/bazarr media/lidarr media/photoprism media/plex
    media/prowlarr media/radarr media/sonarr network/unifi
    home/matter-server home/mosquitto home/frigate
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-age-minutes)
            MAX_AGE_MINUTES="${2:-}"
            shift 2 || true
            ;;
        *)
            echo "Usage: $0 [--max-age-minutes N]" >&2
            exit 2
            ;;
    esac
done

if ! [[ "${MAX_AGE_MINUTES}" =~ ^[0-9]+$ ]]; then
    echo "❌ --max-age-minutes requires a non-negative integer" >&2
    exit 2
fi

for cmd in kubectl jq; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "❌ ${cmd} not found" >&2; exit 2; }
done

log_ok() { echo "✅ $*"; }
log_error() { echo "❌ $*" >&2; ERRORS=$((ERRORS + 1)); }

echo "🔍 Rebuild pre-flight (max age: ${MAX_AGE_MINUTES}m)"

# Check 1: every ReplicationSource synced successfully within the window.
echo "--- Check 1: ReplicationSource freshness ---"
SOURCES_JSON=$(kubectl get replicationsources.volsync.backube -A -o json)
# Captured first so set -e aborts if jq fails (process substitution would hide it).
CHECK1=$(jq -r --arg max "${MAX_AGE_MINUTES}" '
    .items[] |
    (.metadata.namespace + "/" + .metadata.name) as $k |
    ($max | tonumber) as $max |
    (.status.lastSyncTime // null) as $t |
    (.status.latestMoverStatus.result // "none") as $r |
    if $t == null then [$k, "bad", "no lastSyncTime"]
    else
        ((now - ($t | sub("\\.[0-9]+"; "") | fromdateiso8601)) / 60 | floor) as $age |
        if $age > $max then [$k, "bad", "last sync \($age)m ago (> \($max)m)"]
        elif $r != "Successful" then [$k, "bad", "last mover result: \($r)"]
        else [$k, "ok", "synced \($age)m ago"] end
    end | @tsv' <<<"${SOURCES_JSON}")
while IFS=$'\t' read -r key verdict detail; do
    [[ -z "${key}" ]] && continue
    if [[ "${verdict}" == "ok" ]]; then
        log_ok "${key}: ${detail}"
    else
        log_error "${key}: ${detail}"
    fi
done <<<"${CHECK1}"

# Check 2: every required ReplicationSource exists.
echo "--- Check 2: required ReplicationSources present ---"
EXISTING=$(jq -r '.items[] | .metadata.namespace + "/" + .metadata.name' <<<"${SOURCES_JSON}")
for req in "${REQUIRED_SOURCES[@]}"; do
    if grep -qxF "${req}" <<<"${EXISTING}"; then
        log_ok "${req} exists"
    else
        log_error "${req}: ReplicationSource missing"
    fi
done

# Check 3: newest CNPG backup completed within the window.
echo "--- Check 3: CNPG backup ---"
BACKUPS_JSON=$(kubectl get backup.postgresql.cnpg.io -n database -o json)
CNPG_RESULT=$(jq -r --arg maxs "${MAX_AGE_MINUTES}" '
    ($maxs | tonumber) as $max |
    (.items | sort_by(.metadata.creationTimestamp) | last) as $b |
    if $b == null then "bad\tno backups found"
    elif ($b.status.phase // "none") != "completed" then "bad\t\($b.metadata.name) phase: \($b.status.phase // "none")"
    elif ($b.status.stoppedAt // null) == null then "bad\t\($b.metadata.name) has no stoppedAt"
    else
        ((now - ($b.status.stoppedAt | sub("\\.[0-9]+"; "") | fromdateiso8601)) / 60 | floor) as $age |
        if $age > $max then "bad\t\($b.metadata.name) stopped \($age)m ago (> \($max)m)"
        else "ok\t\($b.metadata.name) completed \($age)m ago" end
    end' <<<"${BACKUPS_JSON}")
if [[ "${CNPG_RESULT%%$'\t'*}" == "ok" ]]; then
    log_ok "cnpg backup: ${CNPG_RESULT#*$'\t'}"
else
    log_error "cnpg backup: ${CNPG_RESULT#*$'\t'}"
fi

# Check 4: no VolSync mover pod stuck (not Running/Succeeded) beyond threshold.
echo "--- Check 4: VolSync mover pods ---"
PODS_JSON=$(kubectl get pods -A -l app.kubernetes.io/created-by=volsync -o json)
STUCK=$(jq -r --argjson m "${STUCK_MINUTES}" '
    .items[] |
    select(.status.phase != "Running" and .status.phase != "Succeeded") |
    ((now - (.metadata.creationTimestamp | fromdateiso8601)) / 60 | floor) as $age |
    select($age > $m) |
    "\(.metadata.namespace)/\(.metadata.name): \(.status.phase) for \($age)m"' <<<"${PODS_JSON}")
if [[ -z "${STUCK}" ]]; then
    log_ok "no stuck VolSync mover pods"
else
    while IFS= read -r line; do
        log_error "mover pod ${line}"
    done <<<"${STUCK}"
fi

echo "--- Summary ---"
if [[ "${ERRORS}" -gt 0 ]]; then
    echo "❌ Pre-flight FAILED with ${ERRORS} error(s); do not tear down" >&2
    exit 1
fi
echo "✅ Pre-flight passed; all backups fresh"
