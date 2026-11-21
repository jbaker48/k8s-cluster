#!/usr/bin/env bash
# Host-neutral workflow lane wrapper. All model output is written to a lane
# artifact; stdout contains only that artifact path and one summary line.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
LANE_OUT_ROOT=${LANE_OUT:-.lane-out}
if [[ "$LANE_OUT_ROOT" != /* ]]; then
  LANE_OUT_ROOT="$(pwd)/$LANE_OUT_ROOT"
fi

usage() {
  cat <<'EOF'
Usage:
  scripts/lane.sh luna <worktree> <packet-file>
  scripts/lane.sh sol <packet-file>
  scripts/lane.sh astra <packet-file>
  scripts/lane.sh review <worktree> <base> <head> <issue-id>
  scripts/lane.sh astra-review <worktree> <base> <head> <issue-id> [notes-file]
  scripts/lane.sh opus-review <worktree> <base> <head> <issue-id> [notes-file]
  scripts/lane.sh opus <packet-file>
  scripts/lane.sh research <packet-file>

Environment:
  LANE_OUT=<dir>       Output root (default: .lane-out)
  ASTRA_EFFORT=xhigh   Use xhigh for an adjudication packet (default: high)
  SOL_MODEL=<id>       Sol model (default: gpt-6.1-sol)
  OPUS_MODEL=<id>      Claude model for the opus lanes (default: opus)
  LUNA_SANDBOX=<mode>  Luna sandbox: danger-full-access (default, owner choice
                       2026-09-25) or workspace-write
EOF
}

die() {
  echo "lane.sh: $*" >&2
  exit 2
}

require_file() {
  [[ -f "$1" ]] || die "not a regular file: $1"
}

require_dir() {
  [[ -d "$1" ]] || die "not a directory: $1"
}

role_contract() {
  local role_file=$1
  require_file "$role_file"
  python3 - "$role_file" <<'PY'
import json
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    data = tomllib.load(stream)
instructions = data.get("developer_instructions")
if not isinstance(instructions, str) or not instructions.strip():
    raise SystemExit("agent TOML has no non-empty developer_instructions")
# JSON string escaping is valid TOML basic-string escaping and keeps the whole
# developer contract in one argv item for `codex exec -c`.
print(json.dumps(instructions))
PY
}

issue_from_file() {
  local input_file=$1
  python3 - "$input_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
match = re.search(r"k8s-[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*", text)
print(match.group(0) if match else "lane")
PY
}

safe_ref() {
  [[ "$1" != -* && "$1" != *$'\n'* && "$1" != *$'\r'* ]] || die "unsafe git ref"
}

summary_line() {
  local output=$1
  python3 - "$output" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    value = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    value = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""

if isinstance(value, dict):
    if value.get("verdict"):
        text = f"{value['verdict']}: {value.get('summary', '')}"
    else:
        text = value.get("result") or value.get("summary") or value.get("message") or str(value)
else:
    text = str(value)
text = re.sub(r"\s+", " ", text).strip()
print(text[:240] or "(empty model output)")
PY
}

run_codex() {
  local lane=$1
  local worktree=$2
  local packet=$3
  local model=$4
  local effort=$5
  local sandbox=$6
  local role_file=$7
  local schema=${8:-}
  local issue output log prompt contract
  local -a schema_args=()

  require_dir "$worktree"
  require_file "$packet"
  worktree=$(cd -- "$worktree" && pwd)
  prompt=$(<"$packet")
  [[ -n "$prompt" ]] || die "packet is empty: $packet"
  issue=$(issue_from_file "$packet")
  output_dir="$LANE_OUT_ROOT/$issue"
  mkdir -p "$output_dir"
  output="$output_dir/$lane.txt"
  log="$output.log"
  contract=$(role_contract "$role_file")
  if [[ -n "$schema" ]]; then
    require_file "$schema"
    schema_args=(--output-schema "$schema")
  fi

  if ! codex exec \
      -m "$model" \
      -c "model_reasoning_effort=$effort" \
      -c 'notify=[]' \
      -c "developer_instructions=$contract" \
      -s "$sandbox" \
      -C "$worktree" \
      "${schema_args[@]}" \
      -o "$output" \
      "$prompt" </dev/null >"$log" 2>&1; then
    echo "lane.sh: $lane failed; see $log" >&2
    exit 1
  fi
  printf '%s\n' "$output"
  summary_line "$output"
}

run_claude() {
  local lane=$1
  local worktree=$2
  local issue=$3
  local prompt=$4
  local model=$5
  local agent=$6
  local schema=${7:-}
  local output_dir output raw_output log tools_arg
  local -a claude_args=()

  require_dir "$worktree"
  [[ "$issue" =~ ^k8s-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid issue id: $issue"
  output_dir="$LANE_OUT_ROOT/$issue"
  mkdir -p "$output_dir"
  output="$output_dir/$lane.json"
  raw_output="$output.raw"
  log="$output.log"
  # No Edit/Write tool is present. Bash is limited to read-oriented command
  # patterns (kubectl is get/describe/logs/top only) so a research/review lane cannot mutate the worktree.
  tools_arg='Read,Grep,Glob,Bash(git diff *),Bash(git show *),Bash(git status *),Bash(git log *),Bash(git rev-parse *),Bash(rg *),Bash(ls *),Bash(pwd),Bash(yamllint *),Bash(kustomize build *),Bash(kubeconform *),Bash(flux get *),Bash(flux diff *),Bash(kubectl get *),Bash(kubectl describe *),Bash(kubectl logs *),Bash(kubectl top *),Bash(bd show *),Bash(bd list *),WebFetch,WebSearch,mcp__flux-k8__get_kubernetes_resources,mcp__flux-k8__get_kubernetes_logs,mcp__flux-k8__get_kubernetes_metrics,mcp__flux-k8__get_flux_instance,mcp__context7__*'
  claude_args=(
    --agent "$agent"
    --model "$model"
    --allowedTools "$tools_arg"
    --output-format json
  )
  if [[ -n "$schema" ]]; then
    # The copied Codex schema is draft-2020-12. Claude's --json-schema
    # validator accepts the same schema body but rejects its $schema URI, so
    # strip only that metadata key at transport time and retain the source
    # artifact verbatim in scripts/verdict.schema.json.
    claude_args+=(--json-schema "$(python3 - "$schema" <<'PY'
import json
import sys
from pathlib import Path

schema=json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
schema.pop("$schema", None)
print(json.dumps(schema, separators=(",", ":")))
PY
)")
  fi

  if ! (cd -- "$worktree" && claude -p \
      "${claude_args[@]}" \
      "$prompt" >"$raw_output" 2>"$log"); then
    echo "lane.sh: $lane failed; see $log" >&2
    exit 1
  fi
  if [[ -n "$schema" ]]; then
    # `--output-format json` returns a Claude envelope whose `result` can be
    # fenced markdown even when --json-schema is supplied. Publish the actual
    # verdict object so callers can validate the lane artifact directly.
    python3 - "$raw_output" "$output" <<'PY'
import json
import re
import sys
from pathlib import Path

raw = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
result = raw.get("result") if isinstance(raw, dict) else raw
if isinstance(result, dict):
    verdict = result
elif isinstance(result, str):
    candidate = result.strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*\})\s*```", candidate, re.DOTALL)
    if fenced:
        candidate = fenced.group(1)
    verdict = json.loads(candidate)
else:
    raise SystemExit("Claude review result is not a JSON object")
if not isinstance(verdict, dict):
    raise SystemExit("Claude review result is not a JSON object")
Path(sys.argv[2]).write_text(json.dumps(verdict, indent=2) + "\n", encoding="utf-8")
PY
  else
    mv -f "$raw_output" "$output"
  fi
  printf '%s\n' "$output"
  summary_line "$output"
}

# Builds an issue + exact-diff packet and runs one reviewer on it. The diff is
# embedded in the prompt so the reviewer does not spend model calls fetching it.
diff_review() {
  local engine=$1 lane=$2 model=$3 effort=$4 role_file=$5 notes=$6
  shift 6
  local worktree=$1 base=$2 head=$3 issue=$4 issue_text diff prompt notes_text=""
  require_dir "$worktree"
  safe_ref "$base"
  safe_ref "$head"
  [[ "$issue" =~ ^k8s-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid issue id: $issue"
  git -C "$worktree" rev-parse --verify "$base^{commit}" >/dev/null || die "base is not a commit: $base"
  git -C "$worktree" rev-parse --verify "$head^{commit}" >/dev/null || die "head is not a commit: $head"
  issue_text=$(bd -C "$worktree" show "$issue" --readonly 2>/dev/null || true)
  [[ -n "$issue_text" ]] || die "could not read issue: $issue"
  diff=$(git -C "$worktree" diff --no-ext-diff "$base...$head" --)
  [[ -n "$diff" ]] || die "empty diff for $base...$head"
  if [[ -n "$notes" ]]; then
    require_file "$notes"
    notes_text=$(printf '\n--- PRIOR REVIEW FINDINGS AND RESOLUTION ---\n%s\n' "$(<"$notes")")
  fi
  prompt=$(printf 'Review issue %s. Return only the verdict JSON required by your reviewer contract.\nThe exact diff is below; do not re-fetch it. Open code outside the hunks only to confirm or refute a specific suspected failure, and say why.\n\n--- ISSUE ---\n%s\n%s\n--- EXACT DIFF ---\n%s\n' \
    "$issue" "$issue_text" "$notes_text" "$diff")
  if [[ "$engine" == claude ]]; then
    run_claude "$lane" "$worktree" "$issue" "$prompt" "$model" reviewer "$SCRIPT_DIR/verdict.schema.json"
    return
  fi
  local packet
  packet=$(mktemp)
  printf '%s\n' "$prompt" >"$packet"
  run_codex "$lane" "$worktree" "$packet" "$model" "$effort" read-only \
    "$role_file" "$SCRIPT_DIR/verdict.schema.json"
  rm -f "$packet"
}

review() {
  [[ $# -eq 4 ]] || die "review needs <worktree> <base> <head> <issue-id>"
  diff_review codex review gpt-6-luna max "$REPO_ROOT/.codex/agents/reviewer.toml" "" "$@"
}

astra_review() {
  [[ $# -eq 4 || $# -eq 5 ]] || die "astra-review needs <worktree> <base> <head> <issue-id> [notes-file]"
  local effort=${ASTRA_EFFORT:-high}
  [[ "$effort" == high || "$effort" == xhigh ]] || die "ASTRA_EFFORT must be high or xhigh"
  diff_review codex astra-review gpt-6-astra "$effort" \
    "$REPO_ROOT/.codex/agents/astra.toml" "${5:-}" "$1" "$2" "$3" "$4"
}

opus_review() {
  [[ $# -eq 4 || $# -eq 5 ]] || die "opus-review needs <worktree> <base> <head> <issue-id> [notes-file]"
  diff_review claude opus-review "${OPUS_MODEL:-opus}" "" "" "${5:-}" "$1" "$2" "$3" "$4"
}

# Opus design/diagnosis packet: read-only Claude run in the opus-architect
# agent contract; the packet file is the prompt. Free-form output, no schema.
opus() {
  [[ $# -eq 1 ]] || die "opus needs <packet-file>"
  require_file "$1"
  local packet=$1 issue prompt
  issue=$(issue_from_file "$packet")
  [[ "$issue" =~ ^k8s-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || issue="k8s-lane"
  prompt=$(<"$packet")
  [[ -n "$prompt" ]] || die "packet is empty: $packet"
  run_claude opus "$REPO_ROOT" "$issue" "$prompt" "${OPUS_MODEL:-opus}" opus-architect
}

research() {
  [[ $# -eq 1 ]] || die "research needs <packet-file>"
  run_codex research "$REPO_ROOT" "$1" gpt-6-luna max read-only "$REPO_ROOT/.codex/agents/scout.toml"
}

main() {
  if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
    usage
    exit 0
  fi
  local subcommand=$1
  shift
  case "$subcommand" in
    luna)
      [[ $# -eq 2 ]] || die "luna needs <worktree> <packet-file>"
      # Luna runs unsandboxed: workspace-write blocks the network (gh, kubectl,
      # flux) and the main repo's .git, which a worktree commit writes to. Merge,
      # workflow dispatch and mutating kubectl are held back by the Luna contract
      # alone, so keep the contract strict.
      sandbox=${LUNA_SANDBOX:-danger-full-access}
      [[ "$sandbox" == danger-full-access || "$sandbox" == workspace-write ]] \
        || die "LUNA_SANDBOX must be danger-full-access or workspace-write"
      run_codex luna "$1" "$2" gpt-6-luna max "$sandbox" "$REPO_ROOT/.codex/agents/luna-impl.toml"
      ;;
    sol)
      [[ $# -eq 1 ]] || die "sol needs <packet-file>"
      require_file "$1"
      run_codex sol "$REPO_ROOT" "$1" "${SOL_MODEL:-gpt-6.1-sol}" high read-only "$REPO_ROOT/.codex/agents/sol-diagnose.toml"
      ;;
    astra)
      [[ $# -eq 1 ]] || die "astra needs <packet-file>"
      require_file "$1"
      effort=${ASTRA_EFFORT:-high}
      [[ "$effort" == high || "$effort" == xhigh ]] || die "ASTRA_EFFORT must be high or xhigh"
      run_codex astra "$REPO_ROOT" "$1" gpt-6-astra "$effort" read-only "$REPO_ROOT/.codex/agents/astra.toml"
      ;;
    review)
      review "$@"
      ;;
    astra-review)
      astra_review "$@"
      ;;
    opus-review)
      opus_review "$@"
      ;;
    opus)
      opus "$@"
      ;;
    research)
      research "$@"
      ;;
    --help|-h)
      usage
      ;;
    *)
      die "unknown subcommand: $subcommand (use --help)"
      ;;
  esac
}

main "$@"
