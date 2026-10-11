#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/health-gate.yaml"
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
  for step_id in bootstrap auth window poll notify-inconclusive revert circuit-breaker revert-pr revert-provenance backstop; do
    extract_step "$step_id" "$TMP_DIR/$step_id.raw.sh"
    sed -E 's/\$\{\{[^}]*\}\}/fixture/g' "$TMP_DIR/$step_id.raw.sh" > "$TMP_DIR/$step_id.sh"
    shellcheck -s bash "$TMP_DIR/$step_id.sh"
  done
elif [ "$#" -ne 0 ]; then
  printf 'usage: %s [--shellcheck]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

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
  malformed-json
  status-not-list
  jq-error
  source-or-hr-rv-changed
  uid-recreated
  secret-substitution
  unknown-default
  helmchart-same-version-new-bytes
  main-moves-before-revert-publication-or-merge
  cas-unavailable-with-otherwise-complete-evidence
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
  name=$(jq -r '.name // empty' "$fixture")
  [ -n "$name" ] || {
    printf 'fixture has no name: %s\n' "${fixture##*/}" >&2
    exit 2
  }
  proof_file="$TMP_DIR/$name.proof.json"
  effective_fixture="$TMP_DIR/$name.fixture.json"
  materialize_fixture "$fixture" "$effective_fixture"
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
      and (.counts.reason_codes as $actual_reasons
           | all(($expected.reason_codes // {}) | to_entries[];
                 . as $entry | $actual_reasons[$entry.key] == $entry.value))
      and ([.diagnostics[]?.code] as $codes
           | all($expected.diagnostic_codes[]?; . as $code | $codes | index($code) != null))
      and ([.legacy_chart_diagnostics[]?] as $legacy
           | all(($expected.legacy_chart_diagnostics // [])[];
                 . as $wanted
                 | any($legacy[];
                       .namespace == $wanted.namespace
                       and .name == $wanted.name
                       and .helm_chart.reference_match == $wanted.reference_match
                       and .helm_chart.status_reference_match == $wanted.status_reference_match
                       and .artifact_binding == $wanted.artifact_binding
                       and ((.reason_codes | sort) == ($wanted.reason_codes | sort)))))
      and ([.candidate_failures[]?] | length) == ($expected.candidate_count // 0)
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
    and ([$actual.diagnostics[]?.code] as $codes
         | all($expected.diagnostic_codes[]?; . as $code | $codes | index($code) != null))
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

REAL_PYTHON3=$(command -v python3)
REAL_JQ=$(command -v jq)
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
        malformed) trace "kubectl-get-malformed:$resource"; printf '{invalid-json'; exit 0 ;;
        list) trace "kubectl-get:$resource"; printf '{"apiVersion":"v1","kind":"List","items":[]}\n'; exit 0 ;;
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
        printf '%s\n' kubernetes/apps/demo/app/helmrelease.yaml
        ;;
      *) trace git-unexpected; exit 96 ;;
    esac
    ;;
  date)
    if [ "${1:-}" = -u ]; then
      trace clock-utc
      printf '%s\n' 2026-10-11T00:00:00Z
    else
      response=$(next_response "$POLL_CLOCK_RESPONSES" date-count)
      trace "clock:$response"
      printf '%s\n' "$response"
    fi
    ;;
  sleep)
    trace sleep
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
    for arg in "$@"; do [ "$arg" = superseded ] && classifier=true; done
    if [ "$classifier" = true ]; then
      response=$(next_response "$POLL_JQ_RESPONSES" jq-error-count)
      case "$response" in
        error) trace jq-classifier-error; exit 4 ;;
        pass) trace jq-classifier-pass ;;
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
for fixture in "$FIXTURE_DIR"/*.json; do
  [ -f "$fixture" ] || continue
  scenario=$(jq -r '.poll_scenario // empty' "$fixture")
  [ -n "$scenario" ] || continue
  name=$(jq -r '.name' "$fixture")
  poll_cases=$((poll_cases + 1))
  poll_dir="$TMP_DIR/poll-$name"
  mkdir -p "$poll_dir/state" "$poll_dir/runner"
  poll_proof="$poll_dir/proof.json"
  if jq -e 'has("producer_input")' "$fixture" >/dev/null; then
    jq -c '.producer_input' "$fixture" > "$poll_dir/producer-input.json"
    target_sha=$(jq -r '.target_sha' "$fixture")
    parent_sha=$(jq -r '.parent_sha' "$fixture")
    "$REAL_PYTHON3" -B "$ROOT/scripts/health-gate-attest.py" \
      --target-sha "$target_sha" --parent-sha "$parent_sha" \
      --fixture-input "$poll_dir/producer-input.json" > "$poll_proof"
  else
    jq -c '.proof' "$fixture" > "$poll_proof"
  fi
  target_sha=$(jq -r '.target_sha // .proof.target_sha' "$fixture")
  parent_sha=$(jq -r '.parent_sha // .proof.parent_sha' "$fixture")
  export REAL_PYTHON3 REAL_JQ POLL_SCENARIO="$scenario" POLL_TRACE="$poll_dir/trace"
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
  export GITHUB_WORKSPACE="$ROOT" GITHUB_RUN_ID=fixture-run RUNNER_TEMP="$poll_dir/runner"
  export WINDOW_SECONDS=1 GITHUB_OUTPUT="$poll_dir/output" GITHUB_STEP_SUMMARY="$poll_dir/summary"
  : > "$POLL_TRACE"
  if ! PATH="$STUB_DIR:$PATH" bash -euo pipefail "$TMP_DIR/poll.sh" > "$poll_dir/stdout" 2> "$poll_dir/stderr"; then
    printf 'poll shell fixture failed: %s\n' "$name" >&2
    tail -n 12 "$poll_dir/stderr" >&2 || true
    cat "$POLL_TRACE" >&2
    exit 1
  fi
  outcome=$(sed -n 's/^outcome=//p' "$GITHUB_OUTPUT")
  all_ready=$(sed -n 's/^all_ready=//p' "$GITHUB_OUTPUT")
  expected_outcome=$(jq -r '.poll_expected.outcome // "inconclusive"' "$fixture")
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
  if ! printf '%s' "$result" | jq -e --argjson expected "$(jq -c '.expected' "$fixture")" '
    .all_ready == $expected.all_ready
    and .sample_valid == $expected.sample_valid
    and .superseded == $expected.superseded
    and (.stalled_or_failed == [])
    and ([.diagnostics[]?.code] as $codes
         | all($expected.diagnostic_codes[]?; . as $code | $codes | index($code) != null))
  ' >/dev/null; then
    printf 'poll classifier result mismatch: %s actual=%s expected=%s\n' \
      "$name" \
      "$(printf '%s' "$result" | jq -c '{all_ready,sample_valid,superseded,stalled_or_failed,diagnostic_codes:[.diagnostics[]?.code] | unique}')" \
      "$(jq -c '.expected' "$fixture")" >&2
    cat "$POLL_TRACE" >&2
    exit 1
  fi
  if [ -f "$POLL_EVENT" ]; then
    printf 'unexpected Event before the extracted notification step: %s\n' "$name" >&2
    exit 1
  fi
  if [ "$outcome" = inconclusive ]; then
    PATH="$STUB_DIR:$PATH" RESULT="$result" GITHUB_SHA="$GITHUB_SHA" \
      bash -euo pipefail "$TMP_DIR/notify-inconclusive.sh" > "$poll_dir/notify.stdout" 2> "$poll_dir/notify.stderr"
    if [ ! -s "$POLL_EVENT" ] || ! grep -Fq 'reason: HealthGateInconclusive' "$POLL_EVENT"; then
      printf 'inconclusive notification was not emitted by extracted shell: %s\n' "$name" >&2
      exit 1
    fi
    while IFS= read -r code; do
      [ -n "$code" ] || continue
      grep -Fq "$code" "$POLL_EVENT" || {
        printf 'inconclusive Event omitted expected reason %s: %s\n' "$code" "$name" >&2
        exit 1
      }
    done < <(jq -r '.expected.diagnostic_codes[]?' "$fixture")
  fi
  trace_json=$("$REAL_PYTHON3" - "$POLL_TRACE" <<'PYTHON'
import json
import pathlib
import sys
events = pathlib.Path(sys.argv[1]).read_text().splitlines()
resources = ("kustomizations", "helmreleases", "gitrepositories", "ocirepositories", "helmrepositories", "helmcharts")
complete = [f"kubectl-get:{name}" for name in resources]
normalized = []
position = 0
while position < len(events):
    if events[position:position + len(complete)] == complete:
        normalized.append("kubectl-snapshot")
        position += len(complete)
    else:
        normalized.append(events[position])
        position += 1
print(json.dumps(normalized, separators=(",", ":")))
PYTHON
  )
  if ! jq -e --argjson actual "$trace_json" '.poll_expected.command_trace == $actual' "$fixture" >/dev/null; then
    printf 'poll command trace mismatch: %s actual=%s expected=%s\n' \
      "$name" "$trace_json" "$(jq -c '.poll_expected.command_trace' "$fixture")" >&2
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
printf 'passed %s extracted workflow poll shell scenarios with command stubs\n' "$poll_cases"
