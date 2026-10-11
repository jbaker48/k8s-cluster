#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/health-gate.yaml"
RBAC_WORKFLOW="$ROOT/.github/workflows/test-health-gate-rbac.yaml"
FIXTURE_DIR="$ROOT/.github/health-gate/fixtures"
TMP_DIR=$(mktemp -d)
trap 'if [ -d "$TMP_DIR/local-parent" ]; then git -C "$ROOT" worktree remove --force "$TMP_DIR/local-parent" >/dev/null 2>&1 || true; fi; rm -rf "$TMP_DIR"' EXIT

for tool in jq python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'required tool missing: %s\n' "$tool" >&2
    exit 2
  }
done

PRODUCER_VERSIONS=$(python3 -B - "$ROOT/scripts/health-gate-attest.py" <<'PYTHON'
import ast
import pathlib
import sys

tree = ast.parse(pathlib.Path(sys.argv[1]).read_text())
for node in tree.body:
    if isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == "VERSIONS"
        for target in node.targets
    ):
        versions = ast.literal_eval(node.value)
        if set(versions) != {"flux", "kustomize", "yq"}:
            raise SystemExit("producer VERSIONS must pin flux, kustomize, and yq")
        for name in ("flux", "kustomize", "yq"):
            print(f"{name}={versions[name]}")
        break
else:
    raise SystemExit("producer VERSIONS assignment not found")
PYTHON
)
PRODUCER_FLUX_VERSION=$(printf '%s\n' "$PRODUCER_VERSIONS" | sed -n 's/^flux=//p')
PRODUCER_KUSTOMIZE_VERSION=$(printf '%s\n' "$PRODUCER_VERSIONS" | sed -n 's/^kustomize=//p')
PRODUCER_YQ_VERSION=$(printf '%s\n' "$PRODUCER_VERSIONS" | sed -n 's/^yq=//p')

version_from_output() {
  awk 'NR == 1 { print $NF; exit }'
}

current_tool_version() {
  local tool=$1
  local raw
  case "$tool" in
    flux) raw=$(flux --version 2>/dev/null) || return 1 ;;
    kustomize) raw=$(kustomize version 2>/dev/null) || return 1 ;;
    yq) raw=$(yq --version 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$raw" | version_from_output
}

if ! command -v mise >/dev/null 2>&1; then
  got=$(current_tool_version flux || printf 'unavailable')
  printf 'pinned render tools unavailable: flux want %s got %s\n' \
    "$PRODUCER_FLUX_VERSION" "$got" >&2
  exit 2
fi

RENDER_TOOL_REFS=(
  "aqua:fluxcd/flux2@$PRODUCER_FLUX_VERSION"
  "aqua:kubernetes-sigs/kustomize@$PRODUCER_KUSTOMIZE_VERSION"
  "aqua:mikefarah/yq@$PRODUCER_YQ_VERSION"
)
for tool in flux kustomize yq; do
  case "$tool" in
    flux) want=$PRODUCER_FLUX_VERSION; spec=${RENDER_TOOL_REFS[0]} ;;
    kustomize) want=$PRODUCER_KUSTOMIZE_VERSION; spec=${RENDER_TOOL_REFS[1]} ;;
    yq) want=$PRODUCER_YQ_VERSION; spec=${RENDER_TOOL_REFS[2]} ;;
  esac
  version_arg=--version
  [ "$tool" != kustomize ] || version_arg=version
  if raw=$(mise exec -q -C "$TMP_DIR" "$spec" -- \
      "$tool" "$version_arg" 2>/dev/null); then
    got=$(printf '%s\n' "$raw" | version_from_output)
  else
    got=$(current_tool_version "$tool" || printf 'unavailable')
  fi
  if [ "$got" != "$want" ]; then
    printf 'pinned render tools unavailable: %s want %s got %s\n' \
      "$tool" "$want" "$got" >&2
    exit 2
  fi
done

if ! PINNED_PATH=$(mise exec -q -C "$TMP_DIR" \
    "${RENDER_TOOL_REFS[@]}" -- printenv PATH 2>/dev/null) || [ -z "$PINNED_PATH" ]; then
  printf 'pinned render tools unavailable: flux want %s got unavailable (mise PATH setup failed)\n' \
    "$PRODUCER_FLUX_VERSION" >&2
  exit 2
fi
PATH="$PINNED_PATH"
export PATH

extract_step() {
  local step_id=$1
  local destination=$2
  local count
  count=$(yq -r ".jobs[\"health-gate\"].steps | map(select(.id == \"$step_id\")) | length" "$WORKFLOW")
  if [ "$count" != 1 ]; then
    printf 'expected one workflow step with id %s, found %s\n' "$step_id" "$count" >&2
    return 1
  fi
  yq -r ".jobs[\"health-gate\"].steps[] | select(.id == \"$step_id\") | .run" "$WORKFLOW" > "$destination"
  if [ ! -s "$destination" ]; then
    printf 'workflow step %s has no extractable shell\n' "$step_id" >&2
    return 1
  fi
}

extract_rbac_step() {
  local step_id=$1
  local destination=$2
  local count
  count=$(yq -r ".jobs.verify-rbac.steps | map(select(.id == \"$step_id\")) | length" "$RBAC_WORKFLOW")
  if [ "$count" != 1 ]; then
    printf 'expected one RBAC workflow step with id %s, found %s\n' "$step_id" "$count" >&2
    return 1
  fi
  yq -r ".jobs.verify-rbac.steps[] | select(.id == \"$step_id\") | .run" "$RBAC_WORKFLOW" > "$destination"
  if [ ! -s "$destination" ]; then
    printf 'RBAC workflow step %s has no extractable shell\n' "$step_id" >&2
    return 1
  fi
}

extract_step bootstrap "$TMP_DIR/bootstrap.sh"
workflow_pin() {
  local variable=$1
  awk -v key="$variable" '
    $0 ~ "^[[:space:]]*" key "=[[:space:]]*\"" {
      line = $0
      sub(/^[^\"]*\"/, "", line)
      sub(/\".*$/, "", line)
      value = line
      count++
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$TMP_DIR/bootstrap.sh"
}
for tool in flux kustomize yq; do
  case "$tool" in
    flux) variable=FLUX_VERSION; producer_version=$PRODUCER_FLUX_VERSION ;;
    kustomize) variable=KUSTOMIZE_VERSION; producer_version=$PRODUCER_KUSTOMIZE_VERSION ;;
    yq) variable=YQ_VERSION; producer_version=$PRODUCER_YQ_VERSION ;;
  esac
  if ! workflow_version=$(workflow_pin "$variable"); then
    printf 'expected one %s pin in workflow bootstrap step\n' "$variable" >&2
    exit 2
  fi
  if [ "$workflow_version" != "$producer_version" ]; then
    printf 'workflow/producer render version mismatch: %s workflow=%s producer=%s\n' \
      "$tool" "$workflow_version" "$producer_version" >&2
    exit 2
  fi
done
printf 'render tool pins match workflow and producer: flux=%s kustomize=%s yq=%s\n' \
  "$PRODUCER_FLUX_VERSION" "$PRODUCER_KUSTOMIZE_VERSION" "$PRODUCER_YQ_VERSION"

extract_step poll "$TMP_DIR/poll.sh"
awk '
  $0 == "JQ_CLASSIFY=$(cat <<'\''JQ_CLASSIFY_EOF'\''" { extracting = 1; next }
  $0 == "JQ_CLASSIFY_EOF" && extracting { extracting = 0; exit }
  extracting { print }
' "$TMP_DIR/poll.sh" > "$TMP_DIR/classifier.jq"
if [ ! -s "$TMP_DIR/classifier.jq" ]; then
  printf 'poll step JQ_CLASSIFY extraction was empty\n' >&2
  exit 2
fi
jq -n -f "$TMP_DIR/classifier.jq" >/dev/null
extract_step notify-inconclusive "$TMP_DIR/notify-inconclusive.sh"
extract_step backstop "$TMP_DIR/backstop.sh"

run_local_render_fixture() {
  local fixture=$1
  local proof_file=$2
  local target_sha
  local parent_sha
  target_sha=$(git -C "$ROOT" rev-parse HEAD)
  parent_sha=$(git -C "$ROOT" rev-parse "$target_sha^")
  git -C "$ROOT" worktree add --detach "$TMP_DIR/local-parent" "$parent_sha" >/dev/null 2>&1
python3 -B - "$TMP_DIR/local-snapshot.json" "$target_sha" <<'PYTHON'
import json
import pathlib
import sys
names = ("kustomizations", "helmreleases", "gitrepositories", "ocirepositories", "helmrepositories", "helmcharts")
empty = {name: {"apiVersion": "v1", "kind": "List", "items": []} for name in names}
release = {
    "apiVersion": "helm.toolkit.fluxcd.io/v2",
    "kind": "HelmRelease",
    "metadata": {
        "generation": 1,
        "labels": {
            "kustomize.toolkit.fluxcd.io/name": "dragonfly",
            "kustomize.toolkit.fluxcd.io/namespace": "flux-system",
        },
        "name": "dragonfly-operator",
        "namespace": "database",
        "resourceVersion": "fixture-rv",
        "uid": "fixture-uid",
    },
    "spec": {"chartRef": {"kind": "OCIRepository", "name": "dragonfly"}},
    "status": {},
}
snapshot = json.loads(json.dumps(empty))
snapshot["helmreleases"]["items"] = [release]
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "before": snapshot, "after": snapshot, "main_before": sys.argv[2],
    "main_after": sys.argv[2], "superseded": False,
}, separators=(",", ":")))
PYTHON
  python3 -B "$ROOT/scripts/health-gate-attest.py" \
    --target-sha "$target_sha" \
    --parent-sha "$parent_sha" \
    --snapshots "$TMP_DIR/local-snapshot.json" \
    --repo-root "$ROOT" \
    --parent-root "$TMP_DIR/local-parent" > "$proof_file"
  jq -e '
    any(.diagnostics[]?;
      .kind == "Kustomization" and .namespace == "flux-system"
      and .name == "dragonfly" and .code == "remote-build-dependency")
    and ([.helm_releases[]?
          | select(.owner.namespace == "flux-system" and .owner.name == "dragonfly")] as $owned
        | ($owned | length) == 1
          and $owned[0].name == "dragonfly-operator"
          and $owned[0].supported == false
          and $owned[0].reason_code == "remote-build-dependency")
  ' "$proof_file" >/dev/null || {
    printf 'local Flux render did not isolate dragonfly remote dependency: %s\n' "${fixture##*/}" >&2
    return 1
  }
}

if [ "${1:-}" = "--shellcheck" ]; then
  if [ "$#" -ne 1 ]; then
    printf 'usage: %s [--shellcheck]\n' "${BASH_SOURCE[0]}" >&2
    exit 2
  fi
  for step_id in bootstrap auth window render poll notify-inconclusive revert circuit-breaker revert-pr revert-provenance backstop; do
    extract_step "$step_id" "$TMP_DIR/$step_id.raw.sh"
    sed -E 's/\$\{\{[^}]*\}\}/fixture/g' "$TMP_DIR/$step_id.raw.sh" > "$TMP_DIR/$step_id.sh"
    shellcheck -s bash "$TMP_DIR/$step_id.sh"
  done
  for step_id in verify-flux-source-reads deny-secret-configmap-reads deny-source-flux-mutations; do
    extract_rbac_step "$step_id" "$TMP_DIR/rbac-$step_id.sh"
    shellcheck -s bash "$TMP_DIR/rbac-$step_id.sh"
  done
elif [ "$#" -ne 0 ]; then
  printf 'usage: %s [--shellcheck]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

RBAC_STUB_DIR="$TMP_DIR/rbac-stubs"
mkdir -p "$RBAC_STUB_DIR"
cat > "$RBAC_STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  get)
    case "$RBAC_STUB_MODE" in
      allow|grant)
        exit 0
        ;;
      deny)
        exit 1
        ;;
      command-error)
        printf 'stubbed kubectl get error\n' >&2
        exit 1
        ;;
      *)
        exit 97
        ;;
    esac
    ;;
  auth)
    [ "${2:-}" = can-i ] || exit 96
    case "$RBAC_STUB_MODE" in
      allow|grant)
        printf 'yes\n'
        exit 0
        ;;
      deny)
        printf 'no\n'
        exit 1
        ;;
      command-error)
        printf 'stubbed kubectl auth error\n' >&2
        exit 2
        ;;
      *)
        exit 97
        ;;
    esac
    ;;
  *)
    exit 96
    ;;
esac
STUB
chmod 700 "$RBAC_STUB_DIR/kubectl"

run_rbac_scenario() {
  local step_id=$1
  local mode=$2
  local expected_status=$3
  local status
  local stderr_file="$TMP_DIR/rbac-$step_id-$mode.stderr"
  if PATH="$RBAC_STUB_DIR:$PATH" RBAC_STUB_MODE="$mode" \
    bash -euo pipefail "$TMP_DIR/rbac-$step_id.sh" \
    > "$TMP_DIR/rbac-$step_id-$mode.stdout" 2> "$stderr_file"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne "$expected_status" ]; then
    printf 'RBAC shell scenario status mismatch: step=%s mode=%s actual=%s expected=%s\n' \
      "$step_id" "$mode" "$status" "$expected_status" >&2
    cat "$stderr_file" >&2
    return 1
  fi
}

for step_id in verify-flux-source-reads deny-secret-configmap-reads deny-source-flux-mutations; do
  extract_rbac_step "$step_id" "$TMP_DIR/rbac-$step_id.sh"
done
run_rbac_scenario verify-flux-source-reads allow 0
run_rbac_scenario verify-flux-source-reads deny 1
run_rbac_scenario verify-flux-source-reads command-error 1
for step_id in deny-secret-configmap-reads deny-source-flux-mutations; do
  run_rbac_scenario "$step_id" deny 0
  run_rbac_scenario "$step_id" grant 1
  run_rbac_scenario "$step_id" command-error 1
done
printf 'passed extracted health-gate RBAC shell scenarios with allowed, denied, grant, and command-error stubs\n'

for step_id in app-token revert circuit-breaker revert-pr revert-provenance; do
  if [ "$step_id" = app-token ]; then
    count=$(yq -r ".jobs[\"health-gate\"].steps | map(select(.id == \"$step_id\")) | length" "$WORKFLOW")
    [ "$count" = 1 ] || {
      printf 'missing production action boundary step: %s\n' "$step_id" >&2
      exit 2
    }
  else
    extract_step "$step_id" "$TMP_DIR/$step_id-boundary.sh"
  fi
done
if rg -n 'gh[[:space:]]+pr[[:space:]]+merge|--method[=[:space:]]+PUT.*\/merge|git[[:space:]]+rebase|--force-with-lease' \
  "$TMP_DIR"/revert-boundary.sh "$TMP_DIR"/circuit-breaker-boundary.sh "$TMP_DIR"/revert-pr-boundary.sh; then
  printf 'unsafe merge or retry operation found in a revert boundary\n' >&2
  exit 1
fi
grep -Fq 'rollback_authorized=false' "$TMP_DIR/poll.sh" || {
  printf 'poll step no longer hard-fails rollback authorization closed\n' >&2
  exit 1
}
grep -Fq 'stalled_or_failed=[]' "$TMP_DIR/poll.sh" || {
  printf 'poll step no longer hard-fails stalled_or_failed closed\n' >&2
  exit 1
}

required=(
  wrong-revert-owner-attempt-old-child
  wrong-revert-unchanged-preexisting-failure
  wrong-revert-mixed-newer-root
  premature-healthy-ks-attempted-not-applied
  premature-healthy-oci-source-ahead-of-hr
  main-advanced-before-flux
  main-advanced-after-sample
  main-aba-observed
  source-missing-stale-or-wrong-artifact
  ready-generation-stale
  ready-and-reconciling
  owner-missing-duplicate-or-inventory-absent
  valuesfrom-changed-same-generation
  rollback-history-old-config
  empty
  all-suspended
  root-missing
  inventory-child-missing
  suspended-owner-active-child
  stable-supported-target
  terminal-target-attempt-no-baseline
  first-poll-failed-recent-timestamp
  rbac-denied
  api-error
  hung-kubectl-read
  malformed-json
  status-not-list
  jq-error
  source-or-hr-rv-changed
  uid-recreated
  secret-substitution
  unknown-default
  helmchart-same-version-new-bytes
  main-moves-before-revert-publication-or-merge
  cas-unavailable-with-terminal-reconciliation-failure
  cas-unavailable-with-otherwise-complete-evidence
  changed-helmrelease-target-namespace-only
  changed-oci-source-timeout-only
  unchanged-helmrelease-target-namespace
  unchanged-oci-source-timeout
  wall-deadline-preserves-last-real-diagnostics
  wall-deadline-loop-preserves-last-invalid-classification
  wall-deadline-read-preserves-last-invalid-classification
  poll-false-superseded-overrides-base-true
  pre-deadline-classifier-timeout-retries
  wall-deadline-preservation-jq-error
  remote-build-dependency-owner
  render-preflight
  newest-history-failed
  newest-history-wrong-chart
  newest-history-wrong-digest
  inventory-orphan
  kustomization-inventory-orphan
  kustomization-owner-inventory-missing
  kustomization-owner-labels-missing
  kustomization-owner-inventory-wrong-parent
  kustomization-owner-inventory-multiple-parents
  kustomization-owner-suspended-parent
  kustomization-owner-self-inventory
  kustomization-live-metadata-mismatch
  candidate-wrong-sole-inventory-holder
  unknown-reconciling-condition
  notify-real-root-shape
  notify-missing-child-root-failure
  notify-inactive-vs-unresolved-chain
  notify-oci-source-failure
  notify-helmrepository-helmchart-failure
  notify-unreferenced-source-failure
)

fixture_count=0
for fixture in "$FIXTURE_DIR"/*.json; do
  [ -f "$fixture" ] || continue
  fixture_count=$((fixture_count + 1))
done
if [ "$fixture_count" -eq 0 ]; then
  printf 'no classifier fixtures found\n' >&2
  exit 2
fi

for name in "${required[@]}"; do
  if [ ! -f "$FIXTURE_DIR/$name.json" ]; then
    printf 'required fixture missing: %s\n' "$name" >&2
    exit 2
  fi
done

passed=0
notification_fixture_count=0
notification_positive=0
notification_negative=0
notification_steps=0
materialize_fixture() {
  local fixture=$1
  local destination=$2
  local base_name
  base_name=$(jq -r '.base_fixture // empty' "$fixture")
  if [ -z "$base_name" ]; then
    cp -f "$fixture" "$destination"
    return
  fi
  jq -n \
    --slurpfile base "$FIXTURE_DIR/$base_name.json" \
    --slurpfile variant "$fixture" '
      ($base[0] * $variant[0]) as $merged
      | $merged
      | .proof = ($base[0].proof
          | reduce ($variant[0].proof_mutations // [])[] as $mutation
              (. ; setpath($mutation.path[1:]; $mutation.value)))
      | del(.base_fixture, .proof_mutations)
    ' > "$destination"
}

for fixture in "$FIXTURE_DIR"/*.json; do
  [ -f "$fixture" ] || continue
  if jq -e 'has("poll_producer_failure")' "$fixture" >/dev/null; then
    continue
  fi
  name=$(jq -r '.name // empty' "$fixture")
  [ -n "$name" ] || {
    printf 'fixture has no name: %s\n' "${fixture##*/}" >&2
    exit 2
  }
  proof_file="$TMP_DIR/$name.proof.json"
  effective_fixture="$TMP_DIR/$name.fixture.json"
  materialize_fixture "$fixture" "$effective_fixture"
  if jq -e '.notification_fixture == true' "$fixture" >/dev/null; then
    notification_fixture_count=$((notification_fixture_count + 1))
    previous_file="$TMP_DIR/$name.notification-previous.json"
    jq -c '.previous // {}' "$fixture" > "$previous_file"
    step_count=$(jq -r '.steps | length' "$fixture")
    for ((step_index = 0; step_index < step_count; step_index++)); do
      scope_file="$TMP_DIR/$name.notification-scope.json"
      snapshots_file="$TMP_DIR/$name.notification-snapshots.json"
      result_file="$TMP_DIR/$name.notification-result.json"
      jq -c ".steps[$step_index].scope" "$fixture" > "$scope_file"
      args=(--target-sha "$(jq -r '.target_sha' "$fixture")"
        --scope "$scope_file" --previous "$previous_file"
        --observed-at "$(jq -r ".steps[$step_index].observed_at // \"2026-10-12T00:00:00Z\"" "$fixture")")
      if jq -e ".steps[$step_index].snapshots != null" "$fixture" >/dev/null; then
        jq -c ".steps[$step_index].snapshots" "$fixture" > "$snapshots_file"
        args+=(--snapshots "$snapshots_file")
      fi
      if [ "$(jq -r ".steps[$step_index].observation_error // false" "$fixture")" = true ]; then
        args+=(--observation-error)
      fi
      python3 -B "$ROOT/scripts/health-gate-flux-status.py" "${args[@]}" > "$result_file"
      expected_file="$TMP_DIR/$name.notification-expected.json"
      jq -c ".steps[$step_index].expected" "$fixture" > "$expected_file"
      if ! jq -e --slurpfile expected "$expected_file" '
        .flux_unhealthy == $expected[0].flux_unhealthy
        and .flux_notification_evidence == $expected[0].evidence
        and .flux_notification_scope == $expected[0].scope
        and .evidence_time == $expected[0].evidence_time
        and .diagnostics == $expected[0].diagnostics
        and ([.flux_unhealthy_objects[]
              | {kind,namespace,name,uid,generation,condition,status,reason,
                 ks_target_revision,owner_identity,observation_time,target_sha}]
             == $expected[0].objects)
        and ((if .flux_unhealthy then "Warning" else "Normal" end)
             == $expected[0].event_type)
        and all(.flux_unhealthy_objects[]; has("message") | not)
      ' "$result_file" >/dev/null; then
        printf 'notification helper fixture failed: %s step=%s actual=%s expected=%s\n' \
          "$name" "$step_index" "$(jq -c . "$result_file")" "$(jq -c . "$expected_file")" >&2
        exit 1
      fi
      if [ "$(jq -r '.flux_unhealthy' "$result_file")" = true ]; then
        notification_positive=$((notification_positive + 1))
      else
        notification_negative=$((notification_negative + 1))
      fi
      notification_steps=$((notification_steps + 1))
      cp -f "$result_file" "$previous_file"
    done
    passed=$((passed + 1))
    continue
  fi
  if jq -e 'has("preflight_cases")' "$fixture" >/dev/null; then
    target_sha=$(jq -r '.target_sha' "$fixture")
    parent_sha=$(jq -r '.parent_sha' "$fixture")
    python3 -B "$ROOT/scripts/health-gate-attest.py" \
      --target-sha "$target_sha" \
      --parent-sha "$parent_sha" \
      --preflight-fixture "$fixture" > "$proof_file"
    jq -e \
      --argjson expected "$(jq -c '.preflight_expected' "$fixture")" \
      --argjson production_expected "$(jq -c '.production_build_expected // []' "$fixture")" '
      ([.cases[] | {name, reason_code}] | sort_by(.name)) == ($expected | sort_by(.name))
      and ([.production_build_cases[]?
            | {name, reason_code, flux_invoked, flux_substitution_invoked, documents_retained}]
           | sort_by(.name)) == ($production_expected | sort_by(.name))
    ' "$proof_file" >/dev/null || {
      printf 'render preflight fixture failed: %s\n' "$name" >&2
      exit 1
    }
    passed=$((passed + 1))
    continue
  elif jq -e '.local_render_fixture == true' "$fixture" >/dev/null; then
    run_local_render_fixture "$fixture" "$proof_file"
  elif jq -e 'has("producer_input")' "$effective_fixture" >/dev/null; then
    jq -c '
      .producer_input as $input
      | reduce (.producer_mutations // [])[] as $mutation
          ($input; setpath($mutation.path; $mutation.value))
    ' "$effective_fixture" > "$TMP_DIR/$name.producer-input.json"
    target_sha=$(jq -r '.target_sha' "$effective_fixture")
    parent_sha=$(jq -r '.parent_sha' "$effective_fixture")
    python3 -B "$ROOT/scripts/health-gate-attest.py" \
      --target-sha "$target_sha" \
      --parent-sha "$parent_sha" \
      --fixture-input "$TMP_DIR/$name.producer-input.json" > "$proof_file"
    jq -e --argjson expected "$(jq -c '.producer_expected' "$effective_fixture")" '
      .counts.helmreleases_total == $expected.helmreleases_total
      and .counts.helmreleases_supported == $expected.helmreleases_supported
      and .counts.helmreleases_unsupported == $expected.helmreleases_unsupported
      and ((.counts.reason_codes // {} | to_entries | sort_by(.key))
           == (($expected.reason_codes // {}) | to_entries | sort_by(.key)))
      and (([.diagnostics[]?.code] | unique | sort)
           == (($expected.diagnostic_codes // []) | unique | sort))
      and ([.legacy_chart_diagnostics[]?] as $legacy
           | all(($expected.legacy_chart_diagnostics // [])[];
                 . as $wanted
                 | any($legacy[];
                       .namespace == $wanted.namespace
                       and .name == $wanted.name
                       and .helm_chart.reference_match == $wanted.reference_match
                       and .helm_chart.status_reference_match == $wanted.status_reference_match
                       and .artifact_binding == $wanted.artifact_binding
                       and ((.reason_codes | unique | sort)
                            == ($wanted.reason_codes | unique | sort)))))
      and ([.candidate_failures[]?] | length) == ($expected.candidate_count // 0)
      and (($expected.changed_inputs != true)
           or all(.candidate_failures[]?;
                  .checks.target_changed_effective_inputs == true))
      and (($expected.changed_inputs != false)
           or all(.helm_releases[]?; .changed_inputs == false))
      and all(.candidate_failures[]?; .authorized == false)
      and all(.candidate_failures[]?; .checks.healthy_premerge_baseline_same_hr_uid == false)
      and all(.candidate_failures[]?; .checks.server_enforced_base_sha_merge_cas == false)
    ' "$proof_file" >/dev/null || {
      printf 'producer fixture failed: %s\n' "$name" >&2
      exit 1
    }
  else
    jq -c '.proof' "$effective_fixture" > "$proof_file"
  fi
  actual=$(jq -c -f "$TMP_DIR/classifier.jq" "$proof_file")
  jq -en --argjson actual "$actual" --argjson expected "$(jq -c '.expected' "$effective_fixture")" '
    $actual.all_ready == $expected.all_ready
    and $actual.sample_valid == $expected.sample_valid
    and $actual.superseded == $expected.superseded
    and ($actual.stalled_or_failed == [])
    and (([$actual.diagnostics[]?.code] | unique | sort)
         == (($expected.diagnostic_codes // []) | unique | sort))
  ' >/dev/null || {
    printf 'classifier fixture failed: %s actual=%s expected=%s\n' \
      "$name" \
      "$(printf '%s' "$actual" | jq -c '{all_ready,sample_valid,superseded,stalled_or_failed,diagnostic_codes:[.diagnostics[]?.code] | unique}')" \
      "$(jq -c '.expected' "$effective_fixture")" >&2
    exit 1
  }
  passed=$((passed + 1))
done

if [ "$passed" -eq 0 ]; then
  printf 'zero classifier fixtures were executed\n' >&2
  exit 2
fi
printf 'passed %s health-gate fixtures\n' "$passed"
printf 'passed %s notification fixtures across %s observations (positive=%s negative=%s)\n' \
  "$notification_fixture_count" "$notification_steps" \
  "$notification_positive" "$notification_negative"

REAL_PYTHON3=$(command -v python3)
REAL_JQ=$(command -v jq)
REAL_SLEEP=$(command -v sleep)
STUB_DIR="$TMP_DIR/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/fixture-tool" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
tool=${0##*/}
trace() { printf '%s\n' "$1" >> "$POLL_TRACE"; }
read_count() {
  local value=0
  if [ -f "$POLL_STATE/$1" ]; then read -r value < "$POLL_STATE/$1"; fi
  value=$((value + 1))
  printf '%s\n' "$value" > "$POLL_STATE/$1"
  printf '%s\n' "$value"
}
next_response() {
  local queue=$1
  local counter=$2
  local n response
  n=$(read_count "$counter")
  response=$(sed -n "${n}p" "$queue")
  if [ -z "$response" ]; then
    trace "missing-response:$counter:$n"
    return 97
  fi
  printf '%s\n' "$response"
}
case "$tool" in
  gh)
    [ "${1:-}" = api ] || { trace gh-unexpected; exit 96; }
    response=$(next_response "$POLL_MAIN_RESPONSES" gh-count)
    case "$response" in
      error) trace gh-main-error; exit 1 ;;
      hang)
        trace gh-main-hang
        exec "$REAL_SLEEP" 30
        ;;
      advanced)
        trace gh-main-advanced
        printf '%s\n' 2222222222222222222222222222222222222222
        ;;
      target)
        trace gh-main-target
        printf '%s\n' "$GITHUB_SHA"
        ;;
      *) trace gh-main-invalid-response; exit 97 ;;
    esac
    ;;
  kubectl)
    if [ "${1:-}" = get ]; then
      resource=${2%%.*}
      response=$(next_response "$POLL_KUBECTL_RESPONSES" kubectl-count)
      case "$response" in
        error) trace "kubectl-get-error:$resource"; exit 1 ;;
        hang)
          trace "kubectl-get-hang:$resource"
          exec "$REAL_SLEEP" 30
          ;;
        malformed) trace "kubectl-get-malformed:$resource"; printf '{invalid-json'; exit 0 ;;
        list) trace "kubectl-get:$resource"; printf '{"apiVersion":"v1","kind":"List","items":[]}\n'; exit 0 ;;
        raw)
          count=$(<"$POLL_STATE/kubectl-count")
          if [ "$(( (count - 1) % 12 ))" -lt 6 ]; then phase=before; else phase=after; fi
          trace "kubectl-get:$resource"
          "$REAL_JQ" -c --arg phase "$phase" --arg resource "$resource" \
            '.[$phase][$resource]' "$POLL_RAW_SNAPSHOT"
          exit 0
          ;;
        *) trace "kubectl-get-invalid-response:$resource"; exit 97 ;;
      esac
    fi
    if [ "${1:-}" = create ] && [ "${2:-}" = -f ] && [ "${3:-}" = - ]; then
      trace kubectl-create-event
      cat > "$POLL_EVENT"
      exit 0
    fi
    trace kubectl-unexpected
    exit 96
    ;;
  git)
    case "${1:-}" in
      rev-parse)
        trace git-rev-parse
        printf '%s\n' "$POLL_PARENT_SHA"
        ;;
      worktree)
        if [ "${2:-}" = add ]; then
          trace git-worktree-add
          mkdir -p "${4:-}"
        else
          trace git-worktree-remove
        fi
        ;;
      diff)
        trace git-diff
        if [ -n "${POLL_CHANGED_PATHS:-}" ] && [ -f "$POLL_CHANGED_PATHS" ]; then
          cat "$POLL_CHANGED_PATHS"
        else
          printf '%s\n' kubernetes/apps/demo/app/helmrelease.yaml
        fi
        ;;
      *) trace git-unexpected; exit 96 ;;
    esac
    ;;
  date)
    if [ "${1:-}" = -u ]; then
      trace clock-utc
      printf '%s\n' "${POLL_OBSERVED_AT:-2026-10-11T00:00:00Z}"
    else
      response=$(next_response "$POLL_CLOCK_RESPONSES" date-count)
      trace "clock:$response"
      printf '%s\n' "$response"
    fi
    ;;
  sleep)
    trace sleep
    if [ "$POLL_SCENARIO" = wall-timeout ] \
      || [ "$POLL_SCENARIO" = wall-deadline-preservation-jq-error ]; then
      exec "$REAL_SLEEP" 10
    fi
    ;;
  python3)
    if [ "${1:-}" = -B ]; then
      shift
    fi
    if [ "${1:-}" = scripts/health-gate-attest.py ]; then
      response=$(next_response "$POLL_PRODUCER_RESPONSES" producer-count)
      case "$response" in
        error) trace producer-error; exit 2 ;;
        proof) trace producer-attest; cat "$POLL_PROOF" ;;
        *) trace producer-invalid-response; exit 97 ;;
      esac
    else
      exec "$REAL_PYTHON3" "$@"
    fi
    ;;
  jq)
    classifier=false
    preservation=false
    expect_json_var=false
    for arg in "$@"; do
      if [ "$expect_json_var" = true ]; then
        case "$arg" in
          superseded) classifier=true ;;
          observed_superseded) preservation=true ;;
        esac
        expect_json_var=false
      elif [ "$arg" = --argjson ]; then
        expect_json_var=true
      fi
    done
    if [ "$preservation" = true ] \
      && [ "$POLL_SCENARIO" = wall-deadline-preservation-jq-error ]; then
      trace jq-preservation-error
      exit 4
    fi
    if [ "$classifier" = true ]; then
      response=$(next_response "$POLL_JQ_RESPONSES" jq-error-count)
      case "$response" in
        error) trace jq-classifier-error; exit 4 ;;
        pass) trace jq-classifier-pass ;;
        hang)
          trace jq-classifier-hang
          exec "$REAL_SLEEP" 30
          ;;
        *) trace jq-invalid-response; exit 97 ;;
      esac
    fi
    exec "$REAL_JQ" "$@"
    ;;
  *) trace "unexpected-tool:$tool"; exit 96 ;;
esac
TOOL
chmod 700 "$STUB_DIR/fixture-tool"
for tool in gh kubectl git date sleep python3 jq; do
  ln -s fixture-tool "$STUB_DIR/$tool"
done

poll_cases=0
backstop_fixture_dir=
for fixture in "$FIXTURE_DIR"/*.json; do
  [ -f "$fixture" ] || continue
  scenario=$(jq -r '.poll_scenario // empty' "$fixture")
  [ -n "$scenario" ] || continue
  name=$(jq -r '.name' "$fixture")
  poll_cases=$((poll_cases + 1))
  poll_dir="$TMP_DIR/poll-$name"
  mkdir -p "$poll_dir/state" "$poll_dir/runner"
  poll_effective_fixture="$poll_dir/effective.fixture.json"
  materialize_fixture "$fixture" "$poll_effective_fixture"
  if [ "$(jq -r '.backstop_scenario // empty' "$fixture")" != "" ]; then
    backstop_fixture_dir="$poll_dir"
  fi
  poll_proof="$poll_dir/proof.json"
  if jq -e 'has("producer_input")' "$poll_effective_fixture" >/dev/null; then
    jq -c '.producer_input' "$poll_effective_fixture" > "$poll_dir/producer-input.json"
    target_sha=$(jq -r '.target_sha' "$poll_effective_fixture")
    parent_sha=$(jq -r '.parent_sha' "$poll_effective_fixture")
    "$REAL_PYTHON3" -B "$ROOT/scripts/health-gate-attest.py" \
      --target-sha "$target_sha" --parent-sha "$parent_sha" \
      --fixture-input "$poll_dir/producer-input.json" > "$poll_proof"
  else
    jq -c '.proof' "$poll_effective_fixture" > "$poll_proof"
  fi
  target_sha=$(jq -r '.target_sha // .proof.target_sha' "$poll_effective_fixture")
  parent_sha=$(jq -r '.parent_sha // .proof.parent_sha' "$poll_effective_fixture")
  export REAL_PYTHON3 REAL_JQ REAL_SLEEP POLL_SCENARIO="$scenario" POLL_TRACE="$poll_dir/trace"
  export POLL_STATE="$poll_dir/state" POLL_EVENT="$poll_dir/event.yaml" POLL_PROOF="$poll_proof"
  jq -r '.poll_responses.main[]' "$fixture" > "$poll_dir/main.responses"
  jq -r '.poll_responses.kubectl[]' "$fixture" > "$poll_dir/kubectl.responses"
  jq -r '.poll_responses.producer[]' "$fixture" > "$poll_dir/producer.responses"
  jq -r '.poll_responses.classifier[]' "$fixture" > "$poll_dir/classifier.responses"
  jq -r '.poll_responses.clock[]' "$fixture" > "$poll_dir/clock.responses"
  export POLL_MAIN_RESPONSES="$poll_dir/main.responses" POLL_KUBECTL_RESPONSES="$poll_dir/kubectl.responses"
  export POLL_PRODUCER_RESPONSES="$poll_dir/producer.responses" POLL_JQ_RESPONSES="$poll_dir/classifier.responses"
  export POLL_CLOCK_RESPONSES="$poll_dir/clock.responses"
  export POLL_PARENT_SHA="$parent_sha" GITHUB_SHA="$target_sha" GITHUB_REPOSITORY=fixture/repo
  export GITHUB_SERVER_URL=https://github.invalid
  export GITHUB_WORKSPACE="$ROOT" GITHUB_RUN_ID=fixture-run RUNNER_TEMP="$poll_dir/runner"
  export HEALTH_GATE_PARENT_SHA="$parent_sha"
  export HEALTH_GATE_PARENT_ROOT="$poll_dir/runner/parent"
  export HEALTH_GATE_RENDER_CACHE="$poll_dir/runner/render-cache.json"
  export HEALTH_GATE_RENDER_STATUS=ready HEALTH_GATE_JOB_STARTED_AT=100
  mkdir -p "$HEALTH_GATE_PARENT_ROOT"
  printf '{}' > "$HEALTH_GATE_RENDER_CACHE"
  export WINDOW_SECONDS
  WINDOW_SECONDS=$(jq -r '.poll_window_seconds // 60' "$poll_effective_fixture")
  export GITHUB_OUTPUT="$poll_dir/output" GITHUB_STEP_SUMMARY="$poll_dir/summary"
  : > "$POLL_TRACE"
  if ! PATH="$STUB_DIR:$PATH" bash -euo pipefail "$TMP_DIR/poll.sh" > "$poll_dir/stdout" 2> "$poll_dir/stderr"; then
    printf 'poll shell fixture failed: %s\n' "$name" >&2
    tail -n 12 "$poll_dir/stderr" >&2 || true
    cat "$POLL_TRACE" >&2
    exit 1
  fi
  outcome=$(sed -n 's/^outcome=//p' "$GITHUB_OUTPUT")
  all_ready=$(sed -n 's/^all_ready=//p' "$GITHUB_OUTPUT")
  expected_outcome=$(jq -r '.poll_expected.outcome // "inconclusive"' "$poll_effective_fixture")
  if [ "$outcome" != "$expected_outcome" ]; then
    printf 'poll outcome mismatch: %s actual=%s expected=%s\n' "$name" "$outcome" "$expected_outcome" >&2
    exit 1
  fi
  if [ "$all_ready" = true ] && [ "$scenario" != healthy ]; then
    printf 'non-positive shell fixture became healthy: %s\n' "$name" >&2
    exit 1
  fi
  if [ "$scenario" = healthy ] && [ "$all_ready" != true ]; then
    printf 'positive shell fixture did not become healthy: %s\n' "$name" >&2
    exit 1
  fi
  result=$(awk '/^diagnostics<<HEALTHGATEEOF$/ { inside=1; next } inside && /^HEALTHGATEEOF$/ { exit } inside { print }' "$GITHUB_OUTPUT")
  if ! printf '%s' "$result" | jq -e \
    --argjson expected "$(jq -c '.expected' "$poll_effective_fixture")" \
    --argjson poll_superseded "$(jq -c 'if (.poll_expected | has("superseded")) then .poll_expected.superseded else .expected.superseded end' "$poll_effective_fixture")" \
    --argjson poll_codes "$(jq -c '.poll_expected.diagnostic_codes // .expected.diagnostic_codes // []' "$poll_effective_fixture")" '
    .all_ready == $expected.all_ready
    and .sample_valid == $expected.sample_valid
    and .superseded == $poll_superseded
    and (.stalled_or_failed == [])
    and (([.diagnostics[]?.code] | unique | sort)
         == ($poll_codes | unique | sort))
  ' >/dev/null; then
    printf 'poll classifier result mismatch: %s actual=%s expected=%s\n' \
      "$name" \
      "$(printf '%s' "$result" | jq -c '{all_ready,sample_valid,superseded,stalled_or_failed,diagnostic_codes:[.diagnostics[]?.code] | unique}')" \
         "$(jq -c '.expected' "$poll_effective_fixture")" >&2
    cat "$POLL_TRACE" >&2
    exit 1
  fi
  if [ -f "$POLL_EVENT" ]; then
    printf 'unexpected Event before the extracted notification step: %s\n' "$name" >&2
    exit 1
  fi
  if [ "$outcome" = inconclusive ]; then
    latest_output() { awk -F= -v key="$1" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' "$GITHUB_OUTPUT"; }
    if ! PATH="$STUB_DIR:$PATH" RESULT="$result" GITHUB_SHA="$GITHUB_SHA" \
      FLUX_UNHEALTHY="$(latest_output flux_unhealthy)" \
      FLUX_UNHEALTHY_OBJECTS="$(latest_output flux_unhealthy_objects)" \
      FLUX_NOTIFICATION_EVIDENCE="$(latest_output flux_notification_evidence)" \
      FLUX_NOTIFICATION_SCOPE="$(latest_output flux_notification_scope)" \
      FLUX_EVIDENCE_TIME="$(latest_output flux_evidence_time)" \
      bash -euo pipefail "$TMP_DIR/notify-inconclusive.sh" \
      > "$poll_dir/notify.stdout" 2> "$poll_dir/notify.stderr"; then
      printf 'extracted inconclusive notification failed: %s\n' "$name" >&2
      tail -n 40 "$poll_dir/notify.stderr" >&2 || true
      exit 1
    fi
    if [ ! -s "$POLL_EVENT" ] || ! "$REAL_JQ" -e \
      '.reason == "HealthGateInconclusive" and .type == "Normal"' \
      "$POLL_EVENT" >/dev/null; then
      printf 'inconclusive notification was not emitted by extracted shell: %s\n' "$name" >&2
      exit 1
    fi
    while IFS= read -r code; do
      [ -n "$code" ] || continue
      "$REAL_JQ" -r '.message' "$POLL_EVENT" | grep -Fq "$code" || {
        printf 'inconclusive Event omitted expected reason %s: %s\n' "$code" "$name" >&2
        exit 1
      }
    done < <(jq -r '(.poll_expected.diagnostic_codes // .expected.diagnostic_codes // [])[]?' "$poll_effective_fixture")
  fi
  trace_json=$("$REAL_PYTHON3" - "$POLL_TRACE" "$POLL_EVENT" <<'PYTHON'
import json
import pathlib
import sys
events = pathlib.Path(sys.argv[1]).read_text().splitlines()
resources = ("kustomizations", "helmreleases", "gitrepositories", "ocirepositories", "helmrepositories", "helmcharts")
complete = [f"kubectl-get:{name}" for name in resources]
normalized = []
position = 0
scope_diff_seen = False
event_created = pathlib.Path(sys.argv[2]).is_file() and pathlib.Path(sys.argv[2]).stat().st_size > 0
event_timestamp = max((index for index, event in enumerate(events) if event == "clock-utc"), default=-1) if event_created else -1
while position < len(events):
    if events[position] == "clock-utc" and position != event_timestamp:
        position += 1
        continue
    if events[position] == "git-diff" and not scope_diff_seen:
        scope_diff_seen = True
        position += 1
    elif events[position:position + len(complete)] == complete:
        normalized.append("kubectl-snapshot")
        position += len(complete)
    else:
        normalized.append(events[position])
        position += 1
print(json.dumps(normalized, separators=(",", ":")))
PYTHON
  )
  if ! jq -e --argjson actual "$trace_json" '.poll_expected.command_trace == $actual' "$poll_effective_fixture" >/dev/null; then
    printf 'poll command trace mismatch: %s actual=%s expected=%s\n' \
      "$name" "$trace_json" "$(jq -c '.poll_expected.command_trace' "$poll_effective_fixture")" >&2
    exit 1
  fi
  "$REAL_PYTHON3" - "$POLL_STATE" "$poll_dir" <<'PYTHON'
import pathlib
import sys
state, directory = map(pathlib.Path, sys.argv[1:])
for counter, queue in (
    ("gh-count", "main.responses"),
    ("kubectl-count", "kubectl.responses"),
    ("producer-count", "producer.responses"),
    ("jq-error-count", "classifier.responses"),
    ("date-count", "clock.responses"),
):
    expected = len((directory / queue).read_text().splitlines())
    counter_path = state / counter
    actual = int(counter_path.read_text()) if counter_path.exists() else 0
    if actual != expected:
        raise SystemExit(f"response sequence consumption mismatch for {counter}: {actual} != {expected}")
PYTHON
  if rg -n 'kubectl-(apply|delete|patch|scale|rollout|exec)|gh-pr-merge|git-rebase' "$POLL_TRACE"; then
    printf 'unexpected mutation or merge command in shell trace: %s\n' "$name" >&2
    exit 1
  fi
done
if [ "$poll_cases" -eq 0 ]; then
  printf 'zero extracted poll shell scenarios were executed\n' >&2
  exit 2
fi

notification_poll_fixture="$FIXTURE_DIR/notify-ks-ready-false-target.json"
notification_poll_dir="$TMP_DIR/notification-poll"
mkdir -p "$notification_poll_dir/state" "$notification_poll_dir/runner/parent"
notification_raw_snapshot="$notification_poll_dir/raw-snapshot.json"
notification_paths="$notification_poll_dir/changed-paths"
jq -c '.steps[0].snapshots' "$notification_poll_fixture" > "$notification_raw_snapshot"
jq -r '.steps[0].scope.changed_paths[]' "$notification_poll_fixture" > "$notification_paths"
for _ in {1..12}; do printf '%s\n' raw; done > "$notification_poll_dir/kubectl.responses"
printf '%s\n' target target > "$notification_poll_dir/main.responses"
printf '%s\n' 100 100 160 > "$notification_poll_dir/clock.responses"
: > "$notification_poll_dir/producer.responses"
: > "$notification_poll_dir/classifier.responses"
export REAL_PYTHON3 REAL_JQ REAL_SLEEP POLL_SCENARIO=notification-render-failed
export POLL_TRACE="$notification_poll_dir/trace" POLL_STATE="$notification_poll_dir/state"
export POLL_EVENT="$notification_poll_dir/event.json" POLL_RAW_SNAPSHOT="$notification_raw_snapshot"
export POLL_CHANGED_PATHS="$notification_paths"
export POLL_MAIN_RESPONSES="$notification_poll_dir/main.responses"
export POLL_KUBECTL_RESPONSES="$notification_poll_dir/kubectl.responses"
export POLL_PRODUCER_RESPONSES="$notification_poll_dir/producer.responses"
export POLL_JQ_RESPONSES="$notification_poll_dir/classifier.responses"
export POLL_CLOCK_RESPONSES="$notification_poll_dir/clock.responses"
POLL_PARENT_SHA=$(printf 'b%.0s' {1..40})
GITHUB_SHA=$(jq -r '.target_sha' "$notification_poll_fixture")
export GITHUB_REPOSITORY=fixture/repo GITHUB_SERVER_URL=https://github.invalid GITHUB_RUN_ID=fixture-run
export GITHUB_WORKSPACE="$ROOT" RUNNER_TEMP="$notification_poll_dir/runner"
export HEALTH_GATE_PARENT_SHA="$POLL_PARENT_SHA"
export HEALTH_GATE_PARENT_ROOT="$notification_poll_dir/runner/parent"
export HEALTH_GATE_RENDER_CACHE="$notification_poll_dir/runner/render-cache.json"
export HEALTH_GATE_RENDER_STATUS=failed HEALTH_GATE_JOB_STARTED_AT=100 WINDOW_SECONDS=60
POLL_OBSERVED_AT=$(jq -r '.steps[0].observed_at' "$notification_poll_fixture")
export POLL_PARENT_SHA GITHUB_SHA POLL_OBSERVED_AT
export GITHUB_OUTPUT="$notification_poll_dir/output" GITHUB_STEP_SUMMARY="$notification_poll_dir/summary"
: > "$GITHUB_OUTPUT"
: > "$GITHUB_STEP_SUMMARY"
: > "$POLL_TRACE"
: > "$POLL_EVENT"
if ! PATH="$STUB_DIR:$PATH" bash -euo pipefail "$TMP_DIR/poll.sh" \
  > "$notification_poll_dir/stdout" 2> "$notification_poll_dir/stderr"; then
  printf 'raw notification poll fixture failed with desired-state render disabled\n' >&2
  tail -n 12 "$notification_poll_dir/stderr" >&2 || true
  cat "$POLL_TRACE" >&2
  exit 1
fi
notification_output() {
  local key=$1
  awk -F= -v key="$key" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' "$GITHUB_OUTPUT"
}
notification_expected=$(jq -c '.steps[0].expected' "$notification_poll_fixture")
notification_poll_diagnostics=$(awk '/^diagnostics<<HEALTHGATEEOF$/ { inside=1; next } inside && /^HEALTHGATEEOF$/ { exit } inside { print }' "$GITHUB_OUTPUT")
if [ "$(notification_output flux_unhealthy)" != true ] \
  || [ "$(notification_output flux_notification_evidence)" != valid ] \
  || [ "$(notification_output flux_notification_scope)" != "apps:demo/app" ] \
  || [ "$(notification_output outcome)" != inconclusive ] \
  || [ "$(notification_output rollback_authorized)" != false ] \
  || [ "$(notification_output stalled_or_failed)" != '[]' ] \
  || ! printf '%s' "$notification_poll_diagnostics" | "$REAL_JQ" -e \
    'any(.diagnostics[]?; .code == "render-cache-unavailable")' >/dev/null \
  || [ "$(<"$POLL_STATE/kubectl-count")" != 12 ] \
  || [ "$(<"$POLL_STATE/gh-count")" != 2 ]; then
  printf 'raw poll outputs, render-failure diagnostics or bounded read counts mismatched: outputs=%s\n' \
    "$(cat "$GITHUB_OUTPUT")" >&2
  cat "$notification_poll_dir/stdout" "$notification_poll_dir/stderr" >&2
  cat "$POLL_TRACE" >&2
  exit 1
fi
# shellcheck disable=SC2016
if ! printf '%s' "$(notification_output flux_unhealthy_objects)" | "$REAL_JQ" -e \
  --argjson expected "$(jq -c '.objects' <<< "$notification_expected")" '
  [.[] | {kind,namespace,name,uid,generation,condition,status,reason,
          ks_target_revision,owner_identity,observation_time,target_sha}] == $expected
' >/dev/null; then
  printf 'raw poll object output did not match the fixture\n' >&2
  exit 1
fi
if ! grep -Fq \
  'Flux notification: paging; scope=apps:demo/app; evidence=valid; objects=1; target='"$GITHUB_SHA" \
  "$GITHUB_STEP_SUMMARY"; then
  printf 'raw poll summary omitted the paging policy line\n' >&2
  cat "$GITHUB_STEP_SUMMARY" >&2
  exit 1
fi
PATH="$STUB_DIR:$PATH" GITHUB_SHA="$GITHUB_SHA" GITHUB_SERVER_URL="$GITHUB_SERVER_URL" \
  GITHUB_REPOSITORY="$GITHUB_REPOSITORY" GITHUB_RUN_ID="$GITHUB_RUN_ID" \
  RESULT='{"diagnostics":[]}' FLUX_UNHEALTHY="$(notification_output flux_unhealthy)" \
  FLUX_UNHEALTHY_OBJECTS="$(notification_output flux_unhealthy_objects)" \
  FLUX_NOTIFICATION_EVIDENCE="$(notification_output flux_notification_evidence)" \
  FLUX_NOTIFICATION_SCOPE="$(notification_output flux_notification_scope)" \
  FLUX_EVIDENCE_TIME="$(notification_output flux_evidence_time)" \
  bash -euo pipefail "$TMP_DIR/notify-inconclusive.sh" \
  > "$notification_poll_dir/notify.stdout" 2> "$notification_poll_dir/notify.stderr"
# shellcheck disable=SC2016
if ! "$REAL_JQ" -e --arg target "$GITHUB_SHA" \
  --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
  --arg time "$(notification_output flux_evidence_time)" '
  .reason == "HealthGateInconclusive" and .type == "Warning"
  and .involvedObject.kind == "Kustomization"
  and .involvedObject.name == "cluster-apps"
  and (.message | contains($target) and contains($url)
       and contains("apps:demo/app") and contains($time)
       and contains("app-owner") and contains("Ready=False")
       and contains("No rollback authorized"))
' "$POLL_EVENT" >/dev/null; then
  printf 'raw notification Event did not contain the qualified current failure evidence\n' >&2
  cat "$POLL_EVENT" >&2
  exit 1
fi
printf 'passed raw extracted poll shell with render disabled: kubectl reads=12, main reads=2, Event=Warning\n'

producer_failure_fixture="$FIXTURE_DIR/notify-producer-failure-poll.json"
producer_source="$FIXTURE_DIR/$(jq -r '.poll_producer_failure.source_fixture' "$producer_failure_fixture")"
producer_proof_source="$FIXTURE_DIR/$(jq -r '.poll_producer_failure.health_proof_fixture' "$producer_failure_fixture")"
producer_failure_cases=$(jq -r '.poll_producer_failure.cases | length' "$producer_failure_fixture")
for ((producer_case_index = 0; producer_case_index < producer_failure_cases; producer_case_index++)); do
  producer_case=$(jq -c ".poll_producer_failure.cases[$producer_case_index]" "$producer_failure_fixture")
  producer_case_name=$(jq -r '.name' <<< "$producer_case")
  producer_case_dir="$TMP_DIR/$producer_case_name"
  mkdir -p "$producer_case_dir/state" "$producer_case_dir/runner/parent"
  jq -c '.steps[0].snapshots' "$producer_source" > "$producer_case_dir/raw-snapshot.json"
  jq -r '.steps[0].scope.changed_paths[]' "$producer_source" > "$producer_case_dir/changed-paths"
  jq -r '.main_responses[]' <<< "$producer_case" > "$producer_case_dir/main.responses"
  jq -r '.producer_responses[]' <<< "$producer_case" > "$producer_case_dir/producer.responses"
  jq -r '.clock_responses[]' <<< "$producer_case" > "$producer_case_dir/clock.responses"
  jq -r '.classifier_responses[]?' <<< "$producer_case" > "$producer_case_dir/classifier.responses"
  producer_case_cluster_reads=$(jq -r '.cluster_reads' <<< "$producer_case")
  for ((read_index = 0; read_index < producer_case_cluster_reads; read_index++)); do
    printf '%s\n' raw
  done > "$producer_case_dir/kubectl.responses"
  jq -c '.proof' "$producer_proof_source" > "$producer_case_dir/proof.json"
  export REAL_PYTHON3 REAL_JQ REAL_SLEEP POLL_SCENARIO=producer-error
  export POLL_TRACE="$producer_case_dir/trace" POLL_STATE="$producer_case_dir/state"
  export POLL_EVENT="$producer_case_dir/event.json" POLL_PROOF="$producer_case_dir/proof.json"
  export POLL_RAW_SNAPSHOT="$producer_case_dir/raw-snapshot.json"
  export POLL_CHANGED_PATHS="$producer_case_dir/changed-paths"
  export POLL_MAIN_RESPONSES="$producer_case_dir/main.responses"
  export POLL_KUBECTL_RESPONSES="$producer_case_dir/kubectl.responses"
  export POLL_PRODUCER_RESPONSES="$producer_case_dir/producer.responses"
  export POLL_JQ_RESPONSES="$producer_case_dir/classifier.responses"
  export POLL_CLOCK_RESPONSES="$producer_case_dir/clock.responses"
  POLL_PARENT_SHA=$(jq -r '.proof.parent_sha' "$producer_proof_source")
  GITHUB_SHA=$(jq -r '.target_sha' "$producer_source")
  export POLL_PARENT_SHA GITHUB_SHA GITHUB_REPOSITORY=fixture/repo
  export GITHUB_SERVER_URL=https://github.invalid GITHUB_RUN_ID=fixture-run
  export GITHUB_WORKSPACE="$ROOT" RUNNER_TEMP="$producer_case_dir/runner"
  export HEALTH_GATE_PARENT_SHA="$POLL_PARENT_SHA"
  export HEALTH_GATE_PARENT_ROOT="$producer_case_dir/runner/parent"
  export HEALTH_GATE_RENDER_CACHE="$producer_case_dir/runner/render-cache.json"
  export HEALTH_GATE_RENDER_STATUS=ready HEALTH_GATE_JOB_STARTED_AT=100 WINDOW_SECONDS=60
  printf '{}\n' > "$HEALTH_GATE_RENDER_CACHE"
  POLL_OBSERVED_AT=$(jq -r '.steps[0].observed_at' "$producer_source")
  export POLL_OBSERVED_AT
  export GITHUB_OUTPUT="$producer_case_dir/output" GITHUB_STEP_SUMMARY="$producer_case_dir/summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  : > "$POLL_TRACE"
  if ! PATH="$STUB_DIR:$PATH" bash -euo pipefail "$TMP_DIR/poll.sh" \
    > "$producer_case_dir/stdout" 2> "$producer_case_dir/stderr"; then
    printf 'producer-failure poll fixture failed: %s\n' "$producer_case_name" >&2
    tail -n 12 "$producer_case_dir/stderr" >&2 || true
    cat "$POLL_TRACE" >&2
    exit 1
  fi
  producer_expected=$(jq -c '.expected' <<< "$producer_case")
  producer_expected_unhealthy=$(jq -r '.flux_unhealthy' <<< "$producer_expected")
  producer_expected_evidence=$(jq -r '.flux_notification_evidence' <<< "$producer_expected")
  producer_expected_scope=$(jq -r '.flux_notification_scope' <<< "$producer_expected")
  producer_expected_event=$(jq -r '.event_type' <<< "$producer_expected")
  if [ "$(notification_output flux_unhealthy)" != "$producer_expected_unhealthy" ] \
    || [ "$(notification_output flux_notification_evidence)" != "$producer_expected_evidence" ] \
    || [ "$(notification_output flux_notification_scope)" != "$producer_expected_scope" ] \
    || [ "$(notification_output outcome)" != inconclusive ] \
    || [ "$(notification_output rollback_authorized)" != false ] \
    || [ "$(notification_output stalled_or_failed)" != '[]' ] \
    || [ "$(<"$POLL_STATE/kubectl-count")" != "$(jq -r '.cluster_reads' <<< "$producer_case")" ] \
    || [ "$(<"$POLL_STATE/gh-count")" != "$(jq -r '.main_reads' <<< "$producer_case")" ]; then
    printf 'producer-failure outputs or bounded read counts mismatched: %s outputs=%s\n' \
      "$producer_case_name" "$(cat "$GITHUB_OUTPUT")" >&2
    cat "$POLL_TRACE" >&2
    exit 1
  fi
  if [ "$producer_expected_unhealthy" = true ]; then
    producer_expected_objects=$(jq -c '.steps[0].expected.objects' "$producer_source")
    producer_expected_time=$(jq -r '.steps[0].expected.evidence_time' "$producer_source")
    if [ "$(notification_output flux_evidence_time)" != "$producer_expected_time" ]; then
      printf 'producer failure changed the previously confirmed evidence time: %s\n' \
        "$producer_case_name" >&2
      cat "$GITHUB_OUTPUT" >&2
      exit 1
    fi
    # shellcheck disable=SC2016
    if ! printf '%s' "$(notification_output flux_unhealthy_objects)" | "$REAL_JQ" -e \
        --argjson expected "$producer_expected_objects" '
        [.[] | {kind,namespace,name,uid,generation,condition,status,reason,
                ks_target_revision,owner_identity,observation_time,target_sha}] == $expected
      ' >/dev/null; then
      printf 'producer failure did not retain the previously confirmed evidence: %s\n' \
        "$producer_case_name" >&2
      cat "$GITHUB_OUTPUT" >&2
      exit 1
    fi
    producer_page_status=paging
    producer_object_count=1
  else
    if [ "$(notification_output flux_evidence_time)" != '' ] \
      || [ "$(notification_output flux_unhealthy_objects)" != '[]' ]; then
      printf 'producer failure manufactured Flux evidence without a prior observation: %s\n' \
        "$producer_case_name" >&2
      cat "$GITHUB_OUTPUT" >&2
      exit 1
    fi
    producer_page_status=non-paging
    producer_object_count=0
  fi
  producer_summary="Flux notification: $producer_page_status; scope=$producer_expected_scope; evidence=$producer_expected_evidence; objects=$producer_object_count; target=$GITHUB_SHA"
  if ! grep -Fq "$producer_summary" "$GITHUB_STEP_SUMMARY"; then
    printf 'producer-failure summary omitted retained notification state: %s\n' \
      "$producer_case_name" >&2
    cat "$GITHUB_STEP_SUMMARY" >&2
    exit 1
  fi
  poll_result=$(awk '/^diagnostics<<HEALTHGATEEOF$/ { inside=1; next } inside && /^HEALTHGATEEOF$/ { exit } inside { print }' "$GITHUB_OUTPUT")
  if ! PATH="$STUB_DIR:$PATH" RESULT="$poll_result" GITHUB_SHA="$GITHUB_SHA" \
    FLUX_UNHEALTHY="$(notification_output flux_unhealthy)" \
    FLUX_UNHEALTHY_OBJECTS="$(notification_output flux_unhealthy_objects)" \
    FLUX_NOTIFICATION_EVIDENCE="$(notification_output flux_notification_evidence)" \
    FLUX_NOTIFICATION_SCOPE="$(notification_output flux_notification_scope)" \
    FLUX_EVIDENCE_TIME="$(notification_output flux_evidence_time)" \
    bash -euo pipefail "$TMP_DIR/notify-inconclusive.sh" \
    > "$producer_case_dir/notify.stdout" 2> "$producer_case_dir/notify.stderr"; then
    printf 'producer-failure notification shell failed: %s\n' "$producer_case_name" >&2
    cat "$producer_case_dir/notify.stderr" >&2
    exit 1
  fi
  # shellcheck disable=SC2016
  if ! "$REAL_JQ" -e --arg event_type "$producer_expected_event" \
    --arg scope "$producer_expected_scope" --arg evidence "$producer_expected_evidence" '
      .reason == "HealthGateInconclusive" and .type == $event_type
      and (if $event_type == "Warning" then
             (.message | contains($scope) and contains($evidence)
              and contains("Ready=False") and contains("No rollback authorized"))
           else
             (.message | contains("no qualifying current Flux failure")
              and contains("notification evidence=unavailable"))
           end)
    ' "$POLL_EVENT" >/dev/null; then
    printf 'producer-failure Event type or message mismatched: %s\n' "$producer_case_name" >&2
    cat "$POLL_EVENT" >&2
    exit 1
  fi
  "$REAL_PYTHON3" - "$POLL_TRACE" <<'PYTHON'
import pathlib
import sys
events = pathlib.Path(sys.argv[1]).read_text().splitlines()
failures = [index for index, event in enumerate(events) if event == "producer-error"]
if len(failures) != 1:
    raise SystemExit(f"expected one producer failure, observed {len(failures)}")
tail = events[failures[-1] + 1:]
if any(event.startswith("gh-main-") or event.startswith("kubectl-get:")
       or event.startswith("kubectl-get-error:") for event in tail):
    raise SystemExit(f"reads continued after producer failure: {tail}")
PYTHON
done
printf 'passed %s producer-failure poll cases: prior Warning retained; no prior evidence Normal; no post-failure cluster/main reads\n' \
  "$producer_failure_cases"

if [ -z "$backstop_fixture_dir" ]; then
  printf 'no extracted post-auth failure backstop fixture was executed\n' >&2
  exit 2
fi
if [ "$(jq -r '.backstop_scenario' "$FIXTURE_DIR/api-error.json")" \
  != "failure-after-auth-before-inconclusive-notification" ]; then
  printf 'backstop fixture scenario is not the required post-auth failure\n' >&2
  exit 2
fi
POLL_TRACE="$backstop_fixture_dir/backstop.trace"
POLL_EVENT="$backstop_fixture_dir/backstop-event.yaml"
GITHUB_STEP_SUMMARY="$backstop_fixture_dir/backstop-summary"
KUBECONFIG="$RUNNER_TEMP/health-gate-kubeconfig.yaml"
export POLL_TRACE POLL_EVENT GITHUB_STEP_SUMMARY KUBECONFIG
: > "$POLL_TRACE"
: > "$POLL_EVENT"
if ! PATH="$STUB_DIR:$PATH" POLL_OUTCOME=none \
  bash -euo pipefail "$TMP_DIR/backstop.sh" \
  > "$backstop_fixture_dir/backstop.stdout" \
  2> "$backstop_fixture_dir/backstop.stderr"; then
  printf 'extracted post-auth backstop fixture failed\n' >&2
  cat "$backstop_fixture_dir/backstop.stderr" >&2
  exit 1
fi
if ! grep -Fq '::error title=Health gate did not reach a verdict::' \
  "$backstop_fixture_dir/backstop.stdout" \
  || ! "$REAL_JQ" -e '
       .reason == "HealthGateInconclusive" and .type == "Normal"
       and .metadata.name == "health-gate-inconclusive-backstop-fixture-run"
       and .involvedObject.name == "cluster-apps"
       and .involvedObject.namespace == "flux-system"
       and (.message | contains("No qualifying current Flux failure")
            and contains("notification evidence=unavailable"))
     ' "$POLL_EVENT" >/dev/null; then
  printf 'post-auth backstop did not emit its annotation and HealthGateInconclusive Event\n' >&2
  exit 1
fi
if ! grep -Fxq 'kubectl-create-event' "$POLL_TRACE"; then
  printf 'post-auth backstop did not attempt Kubernetes Event creation\n' >&2
  exit 1
fi
backstop_policy_fixture="$FIXTURE_DIR/notify-backstop-before-verdict.json"
backstop_objects=$(jq -c '.steps[1].expected.objects' "$backstop_policy_fixture")
: > "$POLL_EVENT"
: > "$POLL_TRACE"
if ! PATH="$STUB_DIR:$PATH" POLL_OUTCOME=inconclusive FLUX_UNHEALTHY=true \
  FLUX_UNHEALTHY_OBJECTS="$backstop_objects" \
  FLUX_NOTIFICATION_EVIDENCE=valid FLUX_NOTIFICATION_SCOPE=apps:demo/app \
  FLUX_EVIDENCE_TIME="$(jq -r '.steps[1].observed_at' "$backstop_policy_fixture")" \
  bash -euo pipefail "$TMP_DIR/backstop.sh" \
  > "$backstop_fixture_dir/backstop-warning.stdout" \
  2> "$backstop_fixture_dir/backstop-warning.stderr"; then
  printf 'extracted evidence-backed backstop fixture failed\n' >&2
  cat "$backstop_fixture_dir/backstop-warning.stderr" >&2
  exit 1
fi
# shellcheck disable=SC2016
if ! "$REAL_JQ" -e --arg sha "$GITHUB_SHA" '
  .reason == "HealthGateInconclusive" and .type == "Warning"
  and (.message | contains($sha) and contains("apps:demo/app")
       and contains("app-owner") and contains("Ready=False")
       and contains("No rollback authorized"))
' "$POLL_EVENT" >/dev/null \
  || ! grep -Fq 'Flux failure evidence at' \
    "$backstop_fixture_dir/backstop-warning.stdout" \
  || grep -Fq 'kubectl-get:' "$POLL_TRACE"; then
  printf 'evidence-backed backstop Event was not Warning or performed an extra read\n' >&2
  cat "$POLL_EVENT" >&2
  cat "$POLL_TRACE" >&2
  exit 1
fi
printf 'passed %s extracted workflow poll shell scenarios with command stubs\n' "$poll_cases"
